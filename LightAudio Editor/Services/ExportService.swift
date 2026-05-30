import Foundation
import AVFoundation

protocol AudioExportBackend {
    func export(project: Project, settings: ExportSettings, progress: @escaping (Double) -> Void) throws -> ExportResult
}

struct ExportResult {
    var clippingDetected: Bool = false
}

final class NativeAudioExportBackend: AudioExportBackend {
    private let renderer = TimelineRenderService()
    private var cancelled = false

    func cancel() {
        cancelled = true
    }

    func export(project: Project, settings: ExportSettings, progress: @escaping (Double) -> Void) throws -> ExportResult {
        cancelled = false
        guard settings.format == .wav || settings.format == .aiff else {
            throw NSError(domain: "LightAudio", code: 10, userInfo: [NSLocalizedDescriptionKey: "This MVP exports WAV or AIFF with the native backend."])
        }

        let sampleRate = settings.sampleRate
        let channels = AVAudioChannelCount(max(1, min(2, settings.channelCount)))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
        let range = renderRange(for: project, settings: settings)
        let output = try AVAudioFile(forWriting: settings.outputURL, settings: format.settings)
        let minimumDuration = settings.range.start == nil ? 0.1 : 0
        let totalFrames = AVAudioFramePosition(max(range.duration, minimumDuration) * sampleRate)
        let chunkFrames: AVAudioFrameCount = 4096
        var frame: AVAudioFramePosition = 0
        var clippingDetected = false

        while frame < totalFrames {
            if cancelled { throw NSError(domain: "LightAudio", code: 11, userInfo: [NSLocalizedDescriptionKey: "Export cancelled."]) }
            let count = AVAudioFrameCount(min(Int64(chunkFrames), totalFrames - frame))
            guard let mixBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { break }
            mixBuffer.frameLength = count
            clear(buffer: mixBuffer)

            let outputChunkStart = Double(frame) / sampleRate
            let chunkStart = range.start + outputChunkStart
            let chunkEnd = range.start + Double(frame + AVAudioFramePosition(count)) / sampleRate
            for (track, clip, asset) in renderer.activeClips(in: project) {
                let clipStart = clip.timelineStart
                let clipEnd = clip.timelineStart + clip.duration
                if clipEnd <= chunkStart || clipStart >= chunkEnd { continue }
                try mix(clip: clip, track: track, project: project, asset: asset, into: mixBuffer, chunkStart: chunkStart, sampleRate: sampleRate)
            }

            if clampAndDetectClipping(in: mixBuffer) {
                clippingDetected = true
            }
            try output.write(from: mixBuffer)
            frame += AVAudioFramePosition(count)
            DispatchQueue.main.async { progress(Double(frame) / Double(max(totalFrames, 1))) }
        }
        return ExportResult(clippingDetected: clippingDetected)
    }

    private func renderRange(for project: Project, settings: ExportSettings) -> (start: TimeInterval, end: TimeInterval, duration: TimeInterval) {
        switch settings.range {
        case .entireProject:
            let end = max(project.duration, 0)
            return (0, end, end)
        case .timeRange(let start, let end):
            let cleanStart = max(0, min(start, end))
            let cleanEnd = max(cleanStart, max(start, end))
            return (cleanStart, cleanEnd, cleanEnd - cleanStart)
        }
    }

    private func clear(buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            for index in 0..<Int(buffer.frameLength) {
                channels[channel][index] = 0
            }
        }
    }

    private func mix(clip: Clip, track: Track, project: Project, asset: MediaAsset, into mixBuffer: AVAudioPCMBuffer, chunkStart: TimeInterval, sampleRate: Double) throws {
        guard let url = asset.audioSourceURL else { return }
        let file = try AVAudioFile(forReading: url)
        let overlapStart = max(chunkStart, clip.timelineStart)
        let overlapEnd = min(chunkStart + Double(mixBuffer.frameLength) / sampleRate, clip.timelineStart + clip.duration)
        let outputStartFrame = Int((overlapStart - chunkStart) * sampleRate)
        let requestedFrames = AVAudioFrameCount(max(0, (overlapEnd - overlapStart) * sampleRate))
        if requestedFrames == 0 { return }

        let sourceStart = clip.sourceStart + (overlapStart - clip.timelineStart)
        file.framePosition = AVAudioFramePosition(sourceStart * file.processingFormat.sampleRate)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: requestedFrames) else { return }
        try file.read(into: inputBuffer, frameCount: requestedFrames)

        guard let inData = inputBuffer.floatChannelData, let outData = mixBuffer.floatChannelData else { return }
        let frames = Int(min(inputBuffer.frameLength, requestedFrames))
        let inChannels = Int(inputBuffer.format.channelCount)
        let outChannels = Int(mixBuffer.format.channelCount)
        let pan = MixMath.combinedPan(clip.pan, track.pan)
        let leftPan = Float(pan <= 0 ? 1 : 1 - pan)
        let rightPan = Float(pan >= 0 ? 1 : 1 + pan)
        let trackGain = MixMath.linearGain(forDB: track.volumeDB)
        let masterGain = MixMath.linearGain(forDB: project.mixState.masterVolumeDB)
        for i in 0..<frames {
            let timelineTime = overlapStart + Double(i) / sampleRate
            let clipTime = timelineTime - clip.timelineStart
            let fadeMultiplier = FadeMath.edgeFadeGain(for: clip, timelineTime: timelineTime)
            let crossfadeMultiplier = FadeMath.crossfadeGain(for: clip.id, timelineTime: timelineTime, timeline: project.timeline)
            let automationGain = AutomationMath.volumeAutomationGain(for: clip, atClipTime: clipTime)
            let trackAutomationGain = AutomationMath.trackVolumeAutomationGain(for: track, atTimelineTime: timelineTime)
            let gain = Float(MixMath.clampClipGainLinear(clip.gain) * automationGain * fadeMultiplier * crossfadeMultiplier * trackGain * trackAutomationGain * masterGain)
            let monoLeft = inData[0][i]
            let monoRight = inChannels > 1 ? inData[1][i] : monoLeft
            let leftSample = monoLeft * gain * leftPan
            let rightSample = monoRight * gain * rightPan
            let outIndex = outputStartFrame + i
            if outIndex < Int(mixBuffer.frameLength) {
                outData[0][outIndex] += leftSample
                if outChannels > 1 { outData[1][outIndex] += rightSample }
            }
        }
    }

    private func clampAndDetectClipping(in buffer: AVAudioPCMBuffer) -> Bool {
        guard let data = buffer.floatChannelData else { return false }
        var clipped = false
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                let sample = data[channel][frame]
                if sample > 1 {
                    data[channel][frame] = 1
                    clipped = true
                } else if sample < -1 {
                    data[channel][frame] = -1
                    clipped = true
                }
            }
        }
        return clipped
    }

}

final class ExternalEncoderExportBackend: AudioExportBackend {
    private let nativeBackend = NativeAudioExportBackend()
    private var process: Process?

    static func availability(for format: ExportFormat) -> (available: Bool, reason: String?) {
        switch format {
        case .wav, .aiff:
            return (true, nil)
        case .m4a, .mp3, .flac:
            // Compressed export is routed through an optional external encoder for now; native AAC can be added behind this abstraction later.
            guard ExternalEncoderSettings.ffmpegPath != nil else {
                return (false, "\(format.rawValue) export requires an external encoder. Configure FFmpeg in Preferences.")
            }
            return (true, nil)
        }
    }

    func cancel() {
        nativeBackend.cancel()
        process?.terminate()
    }

    func export(project: Project, settings: ExportSettings, progress: @escaping (Double) -> Void) throws -> ExportResult {
        guard let ffmpegPath = ExternalEncoderSettings.ffmpegPath,
              FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
            throw NSError(domain: "LightAudio", code: 30, userInfo: [NSLocalizedDescriptionKey: "\(settings.format.rawValue) export requires an external encoder. Configure FFmpeg in Preferences."])
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let renderSettings = ExportSettings(format: .wav, sampleRate: settings.sampleRate, channelCount: settings.channelCount, bitrate: nil, outputURL: tempURL, range: settings.range)
        let result = try nativeBackend.export(project: project, settings: renderSettings) { value in
            progress(value * 0.7)
        }

        try runFFmpeg(path: ffmpegPath, inputURL: tempURL, settings: settings)
        DispatchQueue.main.async { progress(1) }
        return result
    }

    private func runFFmpeg(path: String, inputURL: URL, settings: ExportSettings) throws {
        let process = Process()
        self.process = process
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ffmpegArguments(inputURL: inputURL, settings: settings)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        self.process = nil
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "External encoder failed."
            throw NSError(domain: "LightAudioFFmpeg", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func ffmpegArguments(inputURL: URL, settings: ExportSettings) -> [String] {
        var args = ["-y", "-i", inputURL.path, "-ar", "\(Int(settings.sampleRate))", "-ac", "\(settings.channelCount)"]
        switch settings.format {
        case .m4a:
            args += ["-c:a", "aac"]
            if let bitrate = settings.bitrate { args += ["-b:a", "\(bitrate)k"] }
        case .mp3:
            args += ["-c:a", "libmp3lame"]
            if let bitrate = settings.bitrate { args += ["-b:a", "\(bitrate)k"] }
        case .flac:
            args += ["-c:a", "flac"]
        case .wav, .aiff:
            break
        }
        args.append(settings.outputURL.path)
        return args
    }
}

final class ExportService {
    private let nativeBackend = NativeAudioExportBackend()
    private let externalBackend = ExternalEncoderExportBackend()

    func export(project: Project, settings: ExportSettings, progress: @escaping (Double) -> Void, completion: @escaping (Result<ExportResult, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result: ExportResult
                switch settings.format {
                case .wav, .aiff:
                    result = try self.nativeBackend.export(project: project, settings: settings, progress: progress)
                case .m4a, .mp3, .flac:
                    result = try self.externalBackend.export(project: project, settings: settings, progress: progress)
                }
                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func cancel() {
        nativeBackend.cancel()
        externalBackend.cancel()
    }
}
