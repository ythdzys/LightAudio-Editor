import Foundation
import AVFoundation

/// Time arithmetic can put an exact sample boundary a few floating-point ulps away
/// from its integer frame. Snap only that rounding noise before floor/ceiling.
enum AudioFrameMath {
    private static func snapped(_ value: Double) -> Double {
        let nearest = value.rounded()
        return abs(value - nearest) <= max(1e-7, 8 * value.ulp) ? nearest : value
    }
    static func ceiling(_ value: Double) -> Double { snapped(value).rounded(.up) }
    static func floor(_ value: Double) -> Double { snapped(value).rounded(.down) }
}

final class TimelineRenderService {
    func unavailableVideoProxyAssets(in project: Project) -> [MediaAsset] {
        unavailableAudioProxyAssets(in: project)
    }
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
    func unavailableAudioProxyAssets(in project: Project) -> [MediaAsset] {
        let activeAssetIDs = Set(activeClips(in: project).map { $0.2.id })
        return project.assets.filter {
            guard activeAssetIDs.contains($0.id), $0.requiresAudioPreparation else { return false }
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
    }

    private struct DownmixCoefficients {
        let left: [Float]
        let right: [Float]
    }

    private final class ConversionState {
        let converter: AVAudioConverter
        let inputBuffer: AVAudioPCMBuffer
        let outputFormat: AVAudioFormat
        var remainingSourceFrames: AVAudioFramePosition
        var nextOutputFrame: AVAudioFramePosition

        init(converter: AVAudioConverter, inputBuffer: AVAudioPCMBuffer, outputFormat: AVAudioFormat,
             remainingSourceFrames: AVAudioFramePosition, nextOutputFrame: AVAudioFramePosition) {
            self.converter = converter
            self.inputBuffer = inputBuffer
            self.outputFormat = outputFormat
            self.remainingSourceFrames = remainingSourceFrames
            self.nextOutputFrame = nextOutputFrame
        }
    }

    private let file: AVAudioFile
    private let sourceSampleRate: Double
    private let sourceChannelCount: Int
    private let downmixCoefficients: DownmixCoefficients
    private var conversionState: ConversionState?
    #if os(iOS)
    private var flac: OpaquePointer?
    private var flacPosition: AVAudioFramePosition = 0
    private var flacSamples: [Float] = []
    #endif

    private var sourceFrameCount: AVAudioFramePosition {
        #if os(iOS)
        if let flac, la_flac_frame_count(flac) > 0 { return AVAudioFramePosition(la_flac_frame_count(flac)) }
        #endif
        return file.length
    }

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        sourceSampleRate = file.processingFormat.sampleRate
        sourceChannelCount = Int(file.processingFormat.channelCount)
        downmixCoefficients = try Self.makeDownmixCoefficients(
            channelCount: sourceChannelCount,
            layout: file.processingFormat.channelLayout
        )
        #if os(iOS)
        // Use the same decoder as waveform analysis. AVAudioFile on iPadOS 27
        // can reject valid FLAC final blocks, including during resampling.
        if file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatFLAC {
            guard let decoder = url.withUnsafeFileSystemRepresentation({ la_flac_open($0) }) else {
                throw flacFailure("Could not open FLAC audio.")
            }
            flac = decoder
            guard Int(la_flac_channels(decoder)) == sourceChannelCount,
                  Double(la_flac_sample_rate(decoder)) == sourceSampleRate,
                  file.processingFormat.commonFormat == .pcmFormatFloat32,
                  !file.processingFormat.isInterleaved else {
                throw flacFailure("The FLAC audio format is invalid.")
            }
        }
        #endif
    }

    deinit {
        #if os(iOS)
        if let flac { la_flac_close(flac) }
        #endif
    }

    private func seek(to frame: AVAudioFramePosition) throws {
        #if os(iOS)
        if let flac {
            guard flacPosition != frame else { return }
            guard frame >= 0, la_flac_seek(flac, UInt64(frame)) != 0 else {
                throw flacFailure("Could not seek in FLAC audio.")
            }
            flacPosition = frame
            return
        }
        #endif
        file.framePosition = frame
    }

    private func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws {
        #if os(iOS)
        if let flac {
            let requested = min(Int(frameCount), Int(max(0, sourceFrameCount - flacPosition)))
            guard let channels = buffer.floatChannelData else { throw flacFailure("The FLAC audio format is invalid.") }
            let needed = requested * sourceChannelCount
            if flacSamples.count < needed { flacSamples = [Float](repeating: 0, count: needed) }
            let count = flacSamples.withUnsafeMutableBufferPointer {
                Int(la_flac_read(flac, UInt64(requested), $0.baseAddress))
            }
            // Do not turn a genuinely truncated stream into a successful export.
            guard count == requested else { throw flacFailure("FLAC audio ended before the requested samples were decoded.") }
            buffer.frameLength = AVAudioFrameCount(count)
            for frame in 0..<count {
                for channel in 0..<sourceChannelCount { channels[channel][frame] = flacSamples[frame * sourceChannelCount + channel] }
            }
            flacPosition += AVAudioFramePosition(count)
            return
        }
        #endif
        try file.read(into: buffer, frameCount: frameCount)
    }

    #if os(iOS)
    private func flacFailure(_ description: String) -> NSError {
        NSError(domain: "LightAudioRender", code: 73, userInfo: [NSLocalizedDescriptionKey: L10n.tr(description)])
    }
    #endif

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
            sourceFrameCount,
            AVAudioFramePosition(AudioFrameMath.ceiling(max(0, clip.sourceEnd * sourceSampleRate)))
        )
        let sourceStartFrame = AVAudioFramePosition(AudioFrameMath.floor(max(0, sourceStartTime * sourceSampleRate)))
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

            let left: Float
            let right: Float
            if sourceChannels == 1 {
                let mono = sourceData[0][outputFrame]
                let angle = (pan + 1) * Double.pi / 4
                left = mono * Float(cos(angle))
                right = mono * Float(sin(angle))
            } else {
                let stereo = downmixedStereo(sourceData: sourceData, sourceChannels: sourceChannels, frame: outputFrame)
                left = stereo.left * (pan > 0 ? Float(1 - pan) : 1)
                right = stereo.right * (pan < 0 ? Float(1 + pan) : 1)
            }
            if outputChannels == 1 {
                // Mono is the arithmetic fold-down of the same panned stereo mix used in playback.
                destinationData[0][destinationFrame] += (left + right) * 0.5 * gain
            } else {
                destinationData[0][destinationFrame] += left * gain
                destinationData[1][destinationFrame] += right * gain
            }
            for channel in 0..<min(2, outputChannels) where !destinationData[channel][destinationFrame].isFinite {
                destinationData[channel][destinationFrame] = 0
            }
        }
    }

    /// Converters always start on a common source/output sample boundary with filter preroll.
    /// Clip edges never truncate converter input: adjacent split clips must see the same history
    /// and lookahead. The caller alone determines which timeline samples belong to the clip.
    private func decodedBuffer(
        fromSourceTime sourceStartTime: TimeInterval,
        from sourceStartFrame: AVAudioFramePosition,
        through sourceEndFrame: AVAudioFramePosition,
        outputSampleRate: Double,
        outputFrameCount: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer? {
        guard outputFrameCount > 0, sourceStartFrame < sourceEndFrame, outputSampleRate > 0 else { return nil }
        let sourceFormat = file.processingFormat
        if abs(sourceFormat.sampleRate - outputSampleRate) < 0.0001 {
            conversionState = nil
            let count = AVAudioFrameCount(min(Int64(outputFrameCount), sourceFrameCount - sourceStartFrame))
            guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: count) else { return nil }
            try seek(to: sourceStartFrame)
            try read(into: buffer, frameCount: count)
            Self.sanitize(buffer)
            return buffer
        }

        guard let format = conversionFormat(sampleRate: outputSampleRate, sourceFormat: sourceFormat) else {
            throw conversionFailure()
        }
        let targetFrame = AVAudioFramePosition(AudioFrameMath.floor(max(0, sourceStartTime * outputSampleRate)))
        if conversionState?.outputFormat != format || conversionState?.nextOutputFrame != targetFrame {
            guard let converter = AVAudioConverter(from: sourceFormat, to: format),
                  let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 16_384) else {
                throw conversionFailure()
            }
            // For integer sample rates the GCD gives an exact repeating phase boundary.
            // Non-integral rates retain the same origin by decoding from zero in bounded chunks.
            var anchorSource: Int64 = 0
            var anchorOutput: Int64 = 0
            if sourceSampleRate.rounded() == sourceSampleRate, outputSampleRate.rounded() == outputSampleRate {
                let sourceRate = Int64(sourceSampleRate), outputRate = Int64(outputSampleRate)
                var a = sourceRate, b = outputRate
                while b != 0 { let remainder = a % b; a = b; b = remainder }
                let sourcePeriod = sourceRate / a, outputPeriod = outputRate / a
                // More than the converter's default filter history, on both rate directions.
                let preroll = max(Int64(4096), Int64(ceil(4096 * sourceSampleRate / outputSampleRate)))
                let periods = max(0, sourceStartFrame - preroll) / sourcePeriod
                anchorSource = periods * sourcePeriod
                anchorOutput = periods * outputPeriod
            }
            try seek(to: anchorSource)
            conversionState = ConversionState(converter: converter, inputBuffer: input, outputFormat: format,
                remainingSourceFrames: sourceFrameCount - anchorSource, nextOutputFrame: anchorOutput)
        }
        guard let state = conversionState else { return nil }
        while state.nextOutputFrame < targetFrame {
            let count = AVAudioFrameCount(min(16_384, targetFrame - state.nextOutputFrame))
            let skipped = try convert(state, count: count)
            if skipped.frameLength == 0 { return nil }
        }
        return try convert(state, count: outputFrameCount)
    }

    private func convert(_ state: ConversionState, count: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let output = AVAudioPCMBuffer(pcmFormat: state.outputFormat, frameCapacity: count) else { throw conversionFailure() }
        var readError: Error?
        var conversionError: NSError?
        let status = state.converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard state.remainingSourceFrames > 0 else { inputStatus.pointee = .endOfStream; return nil }
            let count = AVAudioFrameCount(min(Int64(state.inputBuffer.frameCapacity), state.remainingSourceFrames))
            do {
                try self.read(into: state.inputBuffer, frameCount: count)
                // Sanitize before conversion so one NaN cannot contaminate filter history.
                Self.sanitize(state.inputBuffer)
            } catch { readError = error; inputStatus.pointee = .endOfStream; return nil }
            let read = Int64(state.inputBuffer.frameLength)
            guard read > 0 else { inputStatus.pointee = .endOfStream; return nil }
            state.remainingSourceFrames -= read
            inputStatus.pointee = .haveData
            return state.inputBuffer
        }
        if let readError { throw readError }
        if let conversionError { throw conversionError }
        guard status != .error else { throw conversionFailure() }
        state.nextOutputFrame += Int64(output.frameLength)
        Self.sanitize(output)
        return output
    }

    /// Invalid floating-point PCM is rendered as silence, consistently with waveform analysis.
    static func sanitize(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) where !data[channel][frame].isFinite {
                data[channel][frame] = 0
            }
        }
    }

    private func conversionFailure() -> NSError {
        NSError(domain: "LightAudioRender", code: 71,
                userInfo: [NSLocalizedDescriptionKey: L10n.tr("Audio sample-rate conversion failed.")])
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
        layout: AVAudioChannelLayout?
    ) throws -> DownmixCoefficients {
        let roles = try channelRoles(channelCount: channelCount, layout: layout)
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

            }
        }
        return DownmixCoefficients(left: left, right: right)
    }

    private static func channelRoles(channelCount: Int, layout: AVAudioChannelLayout?) throws -> [ChannelRole] {
        func unsupported() -> NSError {
            NSError(domain: "LightAudio", code: 4, userInfo: [NSLocalizedDescriptionKey:
                L10n.tr("This audio channel layout is unsupported. Convert it to mono or stereo before importing.")])
        }
        // Unlabelled mono/stereo are unambiguous; multichannel audio requires speaker labels.
        guard let layout else {
            if channelCount == 1 { return [.center] }
            if channelCount == 2 { return [.left, .right] }
            throw unsupported()
        }
        let source = layout.layout
        let tag = source.pointee.mChannelLayoutTag
        var allocation: UnsafeMutableRawPointer?
        defer { allocation?.deallocate() }
        let descriptions: UnsafePointer<AudioChannelLayout>
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
            descriptions = source
        } else {
            let property = tag == kAudioChannelLayoutTag_UseChannelBitmap
                ? kAudioFormatProperty_ChannelLayoutForBitmap : kAudioFormatProperty_ChannelLayoutForTag
            var specifier: UInt32 = tag == kAudioChannelLayoutTag_UseChannelBitmap ? source.pointee.mChannelBitmap.rawValue : tag
            var size: UInt32 = 0
            guard AudioFormatGetPropertyInfo(property, 4, &specifier, &size) == noErr, size >= MemoryLayout<AudioChannelLayout>.size else { throw unsupported() }
            let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
            allocation = storage
            guard AudioFormatGetProperty(property, 4, &specifier, &size, storage) == noErr else { throw unsupported() }
            descriptions = UnsafePointer(storage.assumingMemoryBound(to: AudioChannelLayout.self))
        }
        guard descriptions.pointee.mNumberChannelDescriptions == channelCount else { throw unsupported() }
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        let labels = UnsafeRawPointer(descriptions).advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
        return try (0..<channelCount).map { index in
            switch labels[index].mChannelLabel {
            case kAudioChannelLabel_Left, kAudioChannelLabel_LeftCenter: return .left
            case kAudioChannelLabel_Right, kAudioChannelLabel_RightCenter: return .right
            case kAudioChannelLabel_Center, kAudioChannelLabel_Mono: return .center
            case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2: return .lfe
            case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RearSurroundLeft: return .leftSurround
            case kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightSurroundDirect, kAudioChannelLabel_RearSurroundRight: return .rightSurround
            case kAudioChannelLabel_CenterSurround: return .centerSurround
            default: throw unsupported()
            }
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
