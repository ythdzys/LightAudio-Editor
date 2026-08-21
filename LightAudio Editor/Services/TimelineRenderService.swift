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
    private enum ChannelRole {
        case left
        case right
        case center
        case lfe
        case leftSurround
        case rightSurround
        case centerSurround
        case unknown
    }

    private struct DownmixCoefficients {
        let left: [Float]
        let right: [Float]
    }

    private final class ConversionState {
        let converter: AVAudioConverter
        let inputBuffer: AVAudioPCMBuffer
        let outputFormat: AVAudioFormat
        let sourceEndFrame: AVAudioFramePosition
        var remainingSourceFrames: AVAudioFramePosition
        var nextSourceTime: TimeInterval

        init(
            converter: AVAudioConverter,
            inputBuffer: AVAudioPCMBuffer,
            outputFormat: AVAudioFormat,
            sourceEndFrame: AVAudioFramePosition,
            remainingSourceFrames: AVAudioFramePosition,
            nextSourceTime: TimeInterval
        ) {
            self.converter = converter
            self.inputBuffer = inputBuffer
            self.outputFormat = outputFormat
            self.sourceEndFrame = sourceEndFrame
            self.remainingSourceFrames = remainingSourceFrames
            self.nextSourceTime = nextSourceTime
        }
    }

    private let file: AVAudioFile
    private let sourceSampleRate: Double
    private let sourceChannelCount: Int
    private let downmixCoefficients: DownmixCoefficients
    private var conversionState: ConversionState?

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        sourceSampleRate = file.processingFormat.sampleRate
        sourceChannelCount = Int(file.processingFormat.channelCount)
        downmixCoefficients = Self.makeDownmixCoefficients(
            channelCount: sourceChannelCount,
            layoutTag: file.processingFormat.channelLayout?.layoutTag
        )
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
            fromSourceTime: sourceStartTime,
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
                let stereo = downmixedStereo(
                    sourceData: sourceData,
                    sourceChannels: sourceChannels,
                    frame: outputFrame
                )
                destinationData[0][destinationFrame] += ((stereo.left + stereo.right) * 0.5) * gain
                continue
            }

            if sourceChannels == 1 {
                let mono = sourceData[0][outputFrame]
                let angle = (pan + 1) * Double.pi / 4
                destinationData[0][destinationFrame] += mono * Float(cos(angle)) * gain
                destinationData[1][destinationFrame] += mono * Float(sin(angle)) * gain
                continue
            }

            var (left, right) = downmixedStereo(
                sourceData: sourceData,
                sourceChannels: sourceChannels,
                frame: outputFrame
            )
            if pan > 0 {
                left *= Float(1 - pan)
            } else if pan < 0 {
                right *= Float(1 + pan)
            }
            destinationData[0][destinationFrame] += left * gain
            destinationData[1][destinationFrame] += right * gain
        }
    }

    /// Each TimelineAudioSource belongs to one clip render stream. Sequential calls retain the
    /// converter's fractional resampling phase; a seek or range jump creates a new stream.
    private func decodedBuffer(
        fromSourceTime sourceStartTime: TimeInterval,
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
            conversionState = nil
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

        guard let convertedFormat = conversionFormat(sampleRate: outputSampleRate, sourceFormat: sourceFormat),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: convertedFormat, frameCapacity: outputFrameCount) else {
            throw NSError(
                domain: "LightAudioRender",
                code: 70,
                userInfo: [NSLocalizedDescriptionKey: "Could not create the requested audio conversion format."]
            )
        }

        let continuityTolerance = max(0.000_001, 0.25 / outputSampleRate)
        let canContinue = conversionState.map {
            abs($0.outputFormat.sampleRate - convertedFormat.sampleRate) < 0.0001 &&
                $0.outputFormat.channelCount == convertedFormat.channelCount &&
                $0.sourceEndFrame == sourceEndFrame &&
                abs($0.nextSourceTime - sourceStartTime) <= continuityTolerance
        } ?? false

        if !canContinue {
            guard let converter = AVAudioConverter(from: sourceFormat, to: convertedFormat) else {
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
            conversionState = ConversionState(
                converter: converter,
                inputBuffer: inputBuffer,
                outputFormat: convertedFormat,
                sourceEndFrame: sourceEndFrame,
                remainingSourceFrames: max(0, sourceEndFrame - sourceStartFrame),
                nextSourceTime: sourceStartTime
            )
        }

        guard let state = conversionState else { return nil }
        var readError: Error?
        var conversionError: NSError?
        let status = state.converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            guard state.remainingSourceFrames > 0 else {
                inputStatus.pointee = .endOfStream
                return nil
            }

            let framesToRead = AVAudioFrameCount(min(Int64(state.inputBuffer.frameCapacity), state.remainingSourceFrames))
            state.inputBuffer.frameLength = 0
            do {
                try self.file.read(into: state.inputBuffer, frameCount: framesToRead)
            } catch {
                readError = error
                inputStatus.pointee = .endOfStream
                return nil
            }

            let framesRead = Int64(state.inputBuffer.frameLength)
            guard framesRead > 0 else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            state.remainingSourceFrames -= framesRead
            inputStatus.pointee = .haveData
            return state.inputBuffer
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
        state.nextSourceTime = sourceStartTime + Double(outputBuffer.frameLength) / outputSampleRate
        return outputBuffer
    }

    private func conversionFormat(sampleRate: Double, sourceFormat: AVAudioFormat) -> AVAudioFormat? {
        if let layout = sourceFormat.channelLayout {
            return AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                interleaved: false,
                channelLayout: layout
            )
        }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: sourceFormat.channelCount,
            interleaved: false
        )
    }

    private func downmixedStereo(
        sourceData: UnsafePointer<UnsafeMutablePointer<Float>>,
        sourceChannels: Int,
        frame: Int
    ) -> (left: Float, right: Float) {
        guard sourceChannels > 1 else {
            let sample = sourceData[0][frame]
            return (sample, sample)
        }

        var left: Float = 0
        var right: Float = 0
        let coefficientCount = min(
            sourceChannels,
            min(downmixCoefficients.left.count, downmixCoefficients.right.count)
        )
        for channel in 0..<coefficientCount {
            let sample = sourceData[channel][frame]
            left += sample * downmixCoefficients.left[channel]
            right += sample * downmixCoefficients.right[channel]
        }
        return (left, right)
    }

    /// Core Audio's common channel layouts use different channel orders. Keeping the channels
    /// intact through decoding and applying an explicit matrix avoids weak center-channel output
    /// and phase cancellation from treating every extra channel as an anonymous average.
    private static func makeDownmixCoefficients(
        channelCount: Int,
        layoutTag: AudioChannelLayoutTag?
    ) -> DownmixCoefficients {
        let roles = channelRoles(channelCount: channelCount, layoutTag: layoutTag)
        var left = Array(repeating: Float(0), count: channelCount)
        var right = Array(repeating: Float(0), count: channelCount)

        for (index, role) in roles.prefix(channelCount).enumerated() {
            switch role {
            case .left:
                left[index] = 1
            case .right:
                right[index] = 1
            case .center:
                left[index] = 0.707_106_77
                right[index] = 0.707_106_77
            case .lfe:
                left[index] = 0.5
                right[index] = 0.5
            case .leftSurround:
                left[index] = 0.707_106_77
            case .rightSurround:
                right[index] = 0.707_106_77
            case .centerSurround:
                left[index] = 0.5
                right[index] = 0.5
            case .unknown:
                if index.isMultiple(of: 2) {
                    left[index] = 0.5
                } else {
                    right[index] = 0.5
                }
            }
        }
        return DownmixCoefficients(left: left, right: right)
    }

    private static func channelRoles(
        channelCount: Int,
        layoutTag: AudioChannelLayoutTag?
    ) -> [ChannelRole] {
        guard channelCount > 0 else { return [] }
        if channelCount == 1 { return [.center] }
        if channelCount == 2 { return [.left, .right] }

        if let layoutTag {
            if layoutTag == kAudioChannelLayoutTag_MPEG_5_1_B {
                return [.left, .right, .leftSurround, .rightSurround, .center, .lfe]
            }
            if layoutTag == kAudioChannelLayoutTag_MPEG_5_1_C {
                return [.left, .center, .right, .leftSurround, .rightSurround, .lfe]
            }
            if layoutTag == kAudioChannelLayoutTag_MPEG_5_1_D ||
                layoutTag == kAudioChannelLayoutTag_AAC_5_1 {
                return [.center, .left, .right, .leftSurround, .rightSurround, .lfe]
            }
        }

        switch channelCount {
        case 3:
            return [.left, .right, .center]
        case 4:
            return [.left, .right, .leftSurround, .rightSurround]
        case 5:
            return [.left, .right, .center, .leftSurround, .rightSurround]
        case 6:
            return [.left, .right, .center, .lfe, .leftSurround, .rightSurround]
        case 7:
            return [.left, .right, .center, .lfe, .leftSurround, .rightSurround, .centerSurround]
        default:
            var roles: [ChannelRole] = [
                .left, .right, .center, .lfe, .leftSurround, .rightSurround,
                .leftSurround, .rightSurround
            ]
            if channelCount > roles.count {
                roles.append(contentsOf: repeatElement(.unknown, count: channelCount - roles.count))
            }
            return roles
        }
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
