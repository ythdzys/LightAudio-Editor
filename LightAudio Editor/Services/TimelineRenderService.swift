import Foundation
import AVFoundation

final class TimelineRenderService {
    func activeClips(in project: Project) -> [(Track, Clip, MediaAsset)] {
        let soloed = project.timeline.tracks.contains { $0.isSolo }
        var result: [(Track, Clip, MediaAsset)] = []
        for track in project.timeline.tracks {
            if track.isMuted { continue }
            if soloed && !track.isSolo { continue }
            for clip in track.clips {
                if let asset = project.asset(id: clip.sourceAssetID), !asset.isMissing {
                    result.append((track, clip, asset))
                }
            }
        }
        return result
    }

    /// Only proxies referenced by an audible timeline clip can prevent playback or export.
    func unavailableVideoProxyAssets(in project: Project) -> [MediaAsset] {
        let activeAssetIDs = Set(activeClips(in: project).map { $0.2.id })
        return project.assets.filter {
            guard activeAssetIDs.contains($0.id), $0.kind == .videoAudio else { return false }
            guard $0.proxyStatus == .ready, let proxyURL = $0.audioSourceURL else { return true }
            return !FileManager.default.fileExists(atPath: proxyURL.path)
        }
    }
}

/// Decodes the source only for the requested timeline interval and maps it into a float PCM mix buffer.
/// The frame position is calculated from absolute source time, so independent render chunks remain aligned.
final class TimelineAudioSource {
    private let file: AVAudioFile
    private let sourceSampleRate: Double
    private let sourceChannelCount: Int

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        sourceSampleRate = file.processingFormat.sampleRate
        sourceChannelCount = Int(file.processingFormat.channelCount)
    }

    func renderClip(
        clip: Clip,
        track: Track,
        project: Project,
        timelineStart: TimeInterval,
        frameCount: AVAudioFrameCount,
        outputFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        clear(buffer: buffer)
        try mix(
            clip: clip,
            track: track,
            project: project,
            into: buffer,
            timelineStart: timelineStart,
            frameCount: frameCount,
            destinationOffset: 0
        )
        return buffer
    }

    func mix(
        clip: Clip,
        track: Track,
        project: Project,
        into destination: AVAudioPCMBuffer,
        timelineStart: TimeInterval,
        frameCount: AVAudioFrameCount,
        destinationOffset: Int
    ) throws {
        guard frameCount > 0,
              sourceSampleRate > 0,
              destination.format.sampleRate > 0,
              sourceChannelCount > 0,
              let destinationData = destination.floatChannelData else {
            return
        }

        let outputSampleRate = destination.format.sampleRate
        let outputChannels = Int(destination.format.channelCount)
        guard outputChannels > 0, destinationOffset >= 0 else { return }

        let sourceStartTime = clip.sourceStart + (timelineStart - clip.timelineStart)
        let maximumDestinationFrame = min(
            Int(destination.frameLength),
            destinationOffset + Int(frameCount)
        )
        guard destinationOffset < maximumDestinationFrame else { return }

        let sourceEndFrame = min(
            file.length,
            AVAudioFramePosition(ceil(max(0, clip.sourceEnd * sourceSampleRate)))
        )
        let sourceStartFrame = AVAudioFramePosition(floor(max(0, sourceStartTime * sourceSampleRate)))
        guard sourceStartFrame < sourceEndFrame else { return }

        let requestedOutputFrames = AVAudioFrameCount(maximumDestinationFrame - destinationOffset)
        guard let sourceBuffer = try decodedBuffer(
            from: sourceStartFrame,
            through: sourceEndFrame,
            outputSampleRate: outputSampleRate,
            outputFrameCount: requestedOutputFrames
        ), let sourceData = sourceBuffer.floatChannelData, sourceBuffer.frameLength > 0 else {
            return
        }

        let sourceChannels = Int(sourceBuffer.format.channelCount)
        let framesToMix = min(Int(requestedOutputFrames), Int(sourceBuffer.frameLength))
        guard sourceChannels > 0, framesToMix > 0 else { return }

        let trackGain = MixMath.linearGain(forDB: track.volumeDB)

        for outputFrame in 0..<framesToMix {
            let timelineTime = timelineStart + Double(outputFrame) / outputSampleRate
            guard timelineTime < clip.timelineStart + clip.duration else { continue }

            let clipTime = timelineTime - clip.timelineStart
            let gain = Float(
                MixMath.clampClipGainLinear(clip.gain) *
                    AutomationMath.volumeAutomationGain(for: clip, atClipTime: clipTime) *
                    FadeMath.edgeFadeGain(for: clip, timelineTime: timelineTime) *
                    FadeMath.crossfadeGain(for: clip.id, timelineTime: timelineTime, timeline: project.timeline) *
                    trackGain *
                    AutomationMath.trackVolumeAutomationGain(for: track, atTimelineTime: timelineTime)
            )
            let clipPan = MixMath.clampPan(
                clip.pan + AutomationMath.panAutomation(for: clip, atClipTime: clipTime) / 100
            )
            let pan = MixMath.combinedPan(clipPan, track.pan)
            let destinationFrame = destinationOffset + outputFrame

            if outputChannels == 1 {
                var mono: Float = 0
                for channel in 0..<sourceChannels {
                    mono += sourceData[channel][outputFrame]
                }
                destinationData[0][destinationFrame] += (mono / Float(sourceChannels)) * gain
                continue
            }

            if sourceChannels == 1 {
                let mono = sourceData[0][outputFrame]
                let angle = (pan + 1) * Double.pi / 4
                destinationData[0][destinationFrame] += mono * Float(cos(angle)) * gain
                destinationData[1][destinationFrame] += mono * Float(sin(angle)) * gain
                continue
            }

            var left = sourceData[0][outputFrame]
            var right = sourceData[1][outputFrame]
            if sourceChannels > 2 {
                var extras: Float = 0
                for channel in 2..<sourceChannels {
                    extras += sourceData[channel][outputFrame]
                }
                let extraMix = extras / Float(sourceChannels - 2)
                left += extraMix * 0.5
                right += extraMix * 0.5
            }
            if pan > 0 {
                left *= Float(1 - pan)
            } else if pan < 0 {
                right *= Float(1 + pan)
            }
            destinationData[0][destinationFrame] += left * gain
            destinationData[1][destinationFrame] += right * gain
        }
    }

    /// Uses AVFoundation's sample-rate converter instead of per-sample interpolation.
    /// Each call seeks independently so overlapping clips and export chunks remain deterministic.
    private func decodedBuffer(
        from sourceStartFrame: AVAudioFramePosition,
        through sourceEndFrame: AVAudioFramePosition,
        outputSampleRate: Double,
        outputFrameCount: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer? {
        guard outputFrameCount > 0,
              sourceStartFrame < sourceEndFrame,
              outputSampleRate > 0 else {
            return nil
        }

        let sourceFormat = file.processingFormat
        if abs(sourceFormat.sampleRate - outputSampleRate) < 0.0001 {
            let frameCount = AVAudioFrameCount(min(
                Int64(outputFrameCount),
                max(0, sourceEndFrame - sourceStartFrame)
            ))
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
                return nil
            }
            file.framePosition = sourceStartFrame
            try file.read(into: buffer, frameCount: frameCount)
            return buffer
        }

        guard let convertedFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: sourceFormat.channelCount,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: convertedFormat),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: convertedFormat, frameCapacity: outputFrameCount) else {
            throw NSError(
                domain: "LightAudioRender",
                code: 70,
                userInfo: [NSLocalizedDescriptionKey: "Could not create an audio sample-rate converter."]
            )
        }

        let inputCapacity = AVAudioFrameCount(min(16_384, max(1, sourceEndFrame - sourceStartFrame)))
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputCapacity) else {
            return nil
        }

        file.framePosition = sourceStartFrame
        var remainingSourceFrames = max(0, sourceEndFrame - sourceStartFrame)
        var readError: Error?
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            guard remainingSourceFrames > 0 else {
                inputStatus.pointee = .endOfStream
                return nil
            }

            let framesToRead = AVAudioFrameCount(min(Int64(inputCapacity), remainingSourceFrames))
            inputBuffer.frameLength = 0
            do {
                try self.file.read(into: inputBuffer, frameCount: framesToRead)
            } catch {
                readError = error
                inputStatus.pointee = .endOfStream
                return nil
            }

            let framesRead = Int64(inputBuffer.frameLength)
            guard framesRead > 0 else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            remainingSourceFrames -= framesRead
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        if let readError {
            throw readError
        }
        if let conversionError {
            throw conversionError
        }
        guard status != .error else {
            throw NSError(
                domain: "LightAudioRender",
                code: 71,
                userInfo: [NSLocalizedDescriptionKey: "Audio sample-rate conversion failed."]
            )
        }
        return outputBuffer
    }

    private func clear(buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                data[channel][frame] = 0
            }
        }
    }
}
