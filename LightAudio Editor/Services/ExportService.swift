import Foundation
import AVFoundation
import Darwin

protocol AudioExportBackend {
    func export(project: Project, settings: ExportSettings, cancellationToken: ExportCancellationToken, progress: @escaping (Double) -> Void) throws -> ExportResult
}

struct ExportResult {
    var clippingDetected: Bool = false
    var maximumPeak: Double = 0
}

/// A single export owns one token from the moment it is requested until it completes.
/// This avoids a quick Cancel being cleared by work that has not reached a backend yet.
final class ExportCancellationToken {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [UUID: () -> Void] = [:]

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let activeHandlers = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()

        activeHandlers.forEach { $0() }
    }

    @discardableResult
    func addCancellationHandler(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        let shouldRunImmediately = cancelled
        if !shouldRunImmediately {
            handlers[id] = handler
        }
        lock.unlock()

        if shouldRunImmediately {
            handler()
        }
        return id
    }

    func removeCancellationHandler(_ id: UUID) {
        lock.lock()
        handlers.removeValue(forKey: id)
        lock.unlock()
    }
}

private func exportCancellationError() -> NSError {
    NSError(domain: "LightAudio", code: 11, userInfo: [NSLocalizedDescriptionKey: L10n.tr("Export cancelled.")])
}

/// Source media and generated caches are inputs, never export destinations. Keep this guard in
/// the render backends as well as the UI so programmatic exports remain non-destructive.
private func validateExportDestination(_ destinationURL: URL, for project: Project) throws {
    let destinationPath = canonicalExportPath(destinationURL)
    let protectedPaths = Set(project.assets.flatMap { asset -> [String] in
        var urls: [URL] = []
        if !asset.originalPath.isEmpty {
            urls.append(URL(fileURLWithPath: asset.originalPath))
        }
        if let resolvedPath = asset.resolvedPath, !resolvedPath.isEmpty {
            urls.append(URL(fileURLWithPath: resolvedPath))
        }
        if let proxyPath = asset.proxyPath, !proxyPath.isEmpty {
            urls.append(URL(fileURLWithPath: proxyPath))
        }
        return urls.map(canonicalExportPath)
    })

    guard !protectedPaths.contains(destinationPath) else {
        throw NSError(
            domain: "LightAudioExport",
            code: 41,
            userInfo: [NSLocalizedDescriptionKey: L10n.tr("The export destination is an imported media file or generated audio proxy. Choose a different output file to keep project media non-destructive.")]
        )
    }
}

private func canonicalExportPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
}

/// Keeps an existing export intact until a complete replacement has been rendered beside it.
private struct ExportOutputTransaction {
    let destinationURL: URL
    let stagingURL: URL

    init(destinationURL: URL) {
        self.destinationURL = destinationURL
        let directory = destinationURL.deletingLastPathComponent()
        let baseName = destinationURL.deletingPathExtension().lastPathComponent
        let fileExtension = destinationURL.pathExtension
        let extensionSuffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        stagingURL = directory.appendingPathComponent(".\(baseName).lightaudio-\(UUID().uuidString).partial\(extensionSuffix)")
    }

    func commit(overwritingExisting: Bool) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destinationURL.path) {
            guard overwritingExisting else {
                throw NSError(
                    domain: "LightAudioExport",
                    code: 40,
                    userInfo: [NSLocalizedDescriptionKey: L10n.tr("An output file already exists at this location. Choose a different name or confirm replacement.")]
                )
            }
            _ = try manager.replaceItemAt(destinationURL, withItemAt: stagingURL, backupItemName: nil, options: [])
        } else {
            try manager.moveItem(at: stagingURL, to: destinationURL)
        }
    }

    func discard() {
        try? FileManager.default.removeItem(at: stagingURL)
    }
}

final class NativeAudioExportBackend: AudioExportBackend {
    private final class SourceCache {
        var sources: [UUID: TimelineAudioSource] = [:]
    }

    private let renderer = TimelineRenderService()

    func export(project: Project, settings: ExportSettings, cancellationToken: ExportCancellationToken, progress: @escaping (Double) -> Void) throws -> ExportResult {
        if cancellationToken.isCancelled { throw exportCancellationError() }
        try settings.validate()
        try ProjectFileService().validateForRendering(project)
        try validateExportDestination(settings.outputURL, for: project)
        let sourceCache = SourceCache()
        let activeClips = renderer.activeClips(in: project)
        guard settings.format == .wav || settings.format == .aiff else {
            throw NSError(domain: "LightAudio", code: 10, userInfo: [NSLocalizedDescriptionKey: L10n.tr("This MVP exports WAV or AIFF with the native backend.")])
        }

        let sampleRate = settings.sampleRate
        let channels = AVAudioChannelCount(max(1, min(2, settings.channelCount)))
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false) else {
            throw NSError(domain: "LightAudioExport", code: 51, userInfo: [NSLocalizedDescriptionKey: L10n.tr("Could not create the requested output audio format.")])
        }
        let range = renderRange(for: project, settings: settings)
        let outputTransaction = ExportOutputTransaction(destinationURL: settings.outputURL)
        defer { outputTransaction.discard() }
        let requestedFrameCount = range.duration * sampleRate
        guard requestedFrameCount.isFinite,
              requestedFrameCount >= 0,
              requestedFrameCount < Double(Int64.max) else {
            throw NSError(domain: "LightAudioExport", code: 52, userInfo: [NSLocalizedDescriptionKey: L10n.tr("The requested export duration is too large.")])
        }
        let roundedFrameCount = AudioFrameMath.floor(requestedFrameCount)
        guard roundedFrameCount >= 1 else {
            throw NSError(domain: "LightAudioExport", code: 52, userInfo: [NSLocalizedDescriptionKey: L10n.tr("The export range contains no audio frames.")])
        }
        let totalFrames = AVAudioFramePosition(roundedFrameCount)
        let chunkFrames: AVAudioFrameCount = 4096
        var frame: AVAudioFramePosition = 0
        var clippingDetected = false
        var maximumPeak = 0.0

        do {
            let output = try AVAudioFile(forWriting: outputTransaction.stagingURL, settings: format.settings)
            while frame < totalFrames {
                if cancellationToken.isCancelled { throw exportCancellationError() }
                let count = AVAudioFrameCount(min(Int64(chunkFrames), totalFrames - frame))
                guard let mixBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { throw CocoaError(.fileWriteUnknown) }
                mixBuffer.frameLength = count
                clear(buffer: mixBuffer)

                let outputChunkStart = Double(frame) / sampleRate
                let chunkStart = range.start + outputChunkStart
                let chunkEnd = range.start + Double(frame + AVAudioFramePosition(count)) / sampleRate
                for (track, clip, asset) in activeClips {
                    let clipStart = clip.timelineStart
                    let clipEnd = clip.timelineStart + clip.duration
                    if clipEnd <= chunkStart || clipStart >= chunkEnd { continue }
                    try mix(clip: clip, track: track, project: project, asset: asset, into: mixBuffer, chunkStart: chunkStart, origin: range.start, chunkFrame: frame, sampleRate: sampleRate, sourceCache: sourceCache)
                    let endFrame = Int64(AudioFrameMath.ceiling((clipEnd - range.start) * sampleRate))
                    if endFrame <= frame + Int64(count) { sourceCache.sources.removeValue(forKey: clip.id) }
                }

                applyMasterGain(project.mixState.masterVolumeDB, to: mixBuffer)

                let peakReport = clampAndDetectClipping(in: mixBuffer)
                maximumPeak = max(maximumPeak, peakReport.maximumPeak)
                clippingDetected = clippingDetected || peakReport.clipped
                try output.write(from: mixBuffer)
                frame += AVAudioFramePosition(count)
                let fraction = Double(frame) / Double(max(totalFrames, 1))
                DispatchQueue.main.async { progress(fraction) }
            }
        }
        if cancellationToken.isCancelled { throw exportCancellationError() }
        try outputTransaction.commit(overwritingExisting: settings.overwriteExisting)
        return ExportResult(clippingDetected: clippingDetected, maximumPeak: maximumPeak)
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

    private func mix(clip: Clip, track: Track, project: Project, asset: MediaAsset, into mixBuffer: AVAudioPCMBuffer, chunkStart: TimeInterval, origin: TimeInterval, chunkFrame: AVAudioFramePosition, sampleRate: Double, sourceCache: SourceCache) throws {
        guard let url = asset.audioSourceURL else { return }
        let overlapStart = max(chunkStart, clip.timelineStart)
        let overlapEnd = min(chunkStart + Double(mixBuffer.frameLength) / sampleRate, clip.timelineStart + clip.duration)
        guard overlapEnd > overlapStart else { return }

        // Map clip edges against one export origin, not by subtracting each chunk's
        // floating-point time. Adjacent clips must agree on the exact boundary frame.
        let first = Int64(AudioFrameMath.ceiling((clip.timelineStart - origin) * sampleRate))
        let last = Int64(AudioFrameMath.ceiling((clip.timelineStart + clip.duration - origin) * sampleRate))
        let startFrame = max(0, Int(first - chunkFrame))
        let endFrame = min(Int(mixBuffer.frameLength), Int(last - chunkFrame))
        let frameCount = max(0, endFrame - startFrame)
        guard frameCount > 0 else { return }

        let renderStart = chunkStart + Double(startFrame) / sampleRate
        do {
            let source = try source(for: clip, url: url, sourceCache: sourceCache)
            try source.mix(
                clip: clip,
                track: track,
                project: project,
                into: mixBuffer,
                timelineStart: renderStart,
                frameCount: AVAudioFrameCount(frameCount),
                destinationOffset: startFrame
            )
        } catch {
            throw NSError(domain: "LightAudioRender", code: 72, userInfo: [
                NSLocalizedDescriptionKey: L10n.format("Could not read audio from %@ at %.2f seconds.", asset.metadata.fileName, clip.sourceStart + renderStart - clip.timelineStart),
                NSUnderlyingErrorKey: error
            ])
        }
    }

    private func source(for clip: Clip, url: URL, sourceCache: SourceCache) throws -> TimelineAudioSource {
        if let source = sourceCache.sources[clip.id] {
            return source
        }
        let source = try TimelineAudioSource(url: url)
        sourceCache.sources[clip.id] = source
        return source
    }

    private func clampAndDetectClipping(in buffer: AVAudioPCMBuffer) -> (clipped: Bool, maximumPeak: Double) {
        guard let data = buffer.floatChannelData else { return (false, 0) }
        var clipped = false
        var maximumPeak = 0.0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                let sample = data[channel][frame]
                if sample.isFinite {
                    maximumPeak = max(maximumPeak, Double(abs(sample)))
                }
                if sample > 1 {
                    data[channel][frame] = 1
                    clipped = clipped || AudioPeakMath.isClipping(peak: Double(sample))
                } else if sample < -1 {
                    data[channel][frame] = -1
                    clipped = clipped || AudioPeakMath.isClipping(peak: Double(-sample))
                }
            }
        }
        return (clipped, maximumPeak)
    }

    private func applyMasterGain(_ volumeDB: Double, to buffer: AVAudioPCMBuffer) {
        let gain = Float(MixMath.linearGain(forDB: MixMath.clampMasterVolumeDB(volumeDB)))
        guard gain != 1, let data = buffer.floatChannelData else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                data[channel][frame] *= gain
            }
        }
    }

}

#if os(macOS)
final class ExternalEncoderExportBackend: AudioExportBackend {
    private let nativeBackend = NativeAudioExportBackend()
    private let encoderPathProvider: () -> String?

    init(encoderPathProvider: @escaping () -> String? = { ExternalEncoderSettings.ffmpegPath }) {
        self.encoderPathProvider = encoderPathProvider
    }

    static func availability(for format: ExportFormat) -> (available: Bool, reason: String?) {
        availability(for: format, encoderPath: ExternalEncoderSettings.ffmpegPath)
    }

    private static func availability(for format: ExportFormat, encoderPath: String?) -> (available: Bool, reason: String?) {
        switch format {
        case .wav, .aiff:
            return (true, L10n.tr("Available (Native)"))
        case .m4a, .mp3, .flac:
            guard let ffmpegPath = encoderPath,
                  FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
                return (false, L10n.tr("The bundled encoder is unavailable. Reinstall LightAudio Editor and try again."))
            }
            guard let encoders = ExternalEncoderSettings.audioEncoderNames(path: ffmpegPath) else {
                return (false, L10n.format("Could not read supported audio encoders from %@.", L10n.tr(ExternalEncoderSettings.sourceDescription(for: ffmpegPath))))
            }
            let requiredEncoder: String
            switch format {
            case .m4a: requiredEncoder = "aac"
            case .mp3: requiredEncoder = "libmp3lame"
            case .flac: requiredEncoder = "flac"
            case .wav, .aiff: requiredEncoder = ""
            }
            guard encoders.contains(requiredEncoder) else {
                return (false, L10n.format("%@ does not include the %@ audio encoder required for %@ export.", L10n.tr(ExternalEncoderSettings.sourceDescription(for: ffmpegPath)), requiredEncoder, format.rawValue))
            }
            return (true, L10n.format("Available (%@)", L10n.tr(ExternalEncoderSettings.sourceDescription(for: ffmpegPath))))
        }
    }

    func export(project: Project, settings: ExportSettings, cancellationToken: ExportCancellationToken, progress: @escaping (Double) -> Void) throws -> ExportResult {
        if cancellationToken.isCancelled { throw exportCancellationError() }
        try settings.validate()
        try ProjectFileService().validateForRendering(project)
        try validateExportDestination(settings.outputURL, for: project)
        let ffmpegPath = encoderPathProvider()
        let availability = Self.availability(for: settings.format, encoderPath: ffmpegPath)
        guard availability.available,
              let ffmpegPath else {
            throw NSError(domain: "LightAudio", code: 30, userInfo: [NSLocalizedDescriptionKey: availability.reason ?? L10n.tr("The bundled encoder is unavailable. Reinstall LightAudio Editor and try again.")])
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let outputTransaction = ExportOutputTransaction(destinationURL: settings.outputURL)
        defer { outputTransaction.discard() }

        let renderSettings = ExportSettings(format: .wav, sampleRate: settings.sampleRate, channelCount: settings.channelCount, bitrate: nil, outputURL: tempURL, range: settings.range)
        let result = try nativeBackend.export(project: project, settings: renderSettings, cancellationToken: cancellationToken) { value in
            DispatchQueue.main.async { progress(value * 0.7) }
        }

        if cancellationToken.isCancelled { throw exportCancellationError() }
        let stagedSettings = ExportSettings(format: settings.format, sampleRate: settings.sampleRate, channelCount: settings.channelCount, bitrate: settings.bitrate, outputURL: outputTransaction.stagingURL, range: settings.range)
        DispatchQueue.main.async { progress(0.7) }
        try runFFmpeg(
            path: ffmpegPath,
            inputURL: tempURL,
            settings: stagedSettings,
            duration: renderedDuration(for: project, settings: settings),
            cancellationToken: cancellationToken
        ) { value in
            DispatchQueue.main.async { progress(0.7 + value * 0.3) }
        }
        if cancellationToken.isCancelled { throw exportCancellationError() }
        try outputTransaction.commit(overwritingExisting: settings.overwriteExisting)
        DispatchQueue.main.async { progress(1) }
        return result
    }

    private func runFFmpeg(
        path: String,
        inputURL: URL,
        settings: ExportSettings,
        duration: TimeInterval,
        cancellationToken: ExportCancellationToken,
        progress: @escaping (Double) -> Void
    ) throws {
        if cancellationToken.isCancelled { throw exportCancellationError() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ffmpegArguments(inputURL: inputURL, settings: settings)
        let progressPipe = Pipe()
        let errorPipe = Pipe()
        let errorLock = NSLock()
        var errorData = Data()
        let progressLock = NSLock()
        var progressLineBuffer = ""
        process.standardOutput = progressPipe
        process.standardError = errorPipe

        func consumeProgress(_ data: Data) {
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            progressLock.lock()
            progressLineBuffer.append(text)
            let lines = progressLineBuffer.split(separator: "\n", omittingEmptySubsequences: false)
            progressLineBuffer = String(lines.last ?? "")
            let completedLines = lines.dropLast()
            var latestFraction: Double?
            for line in completedLines {
                let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2,
                      (pair[0] == "out_time_us" || pair[0] == "out_time_ms"),
                      let microseconds = Double(pair[1]),
                      duration > 0 else {
                    continue
                }
                latestFraction = min(1, max(0, microseconds / 1_000_000 / duration))
            }
            progressLock.unlock()
            if let latestFraction {
                progress(latestFraction)
            }
        }

        progressPipe.fileHandleForReading.readabilityHandler = { handle in
            consumeProgress(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            errorLock.lock()
            if errorData.count < 512 * 1024 {
                errorData.append(data.prefix(512 * 1024 - errorData.count))
            }
            errorLock.unlock()
        }
        let cancellationHandlerID = cancellationToken.addCancellationHandler {
            if process.isRunning {
                process.terminate()
            }
        }
        defer {
            cancellationToken.removeCancellationHandler(cancellationHandlerID)
            progressPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            progressPipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
        }
        if cancellationToken.isCancelled { throw exportCancellationError() }
        try process.run()
        let exportDeadline = Date().addingTimeInterval(ffmpegTimeout(for: duration))
        var terminationRequestedAt: Date?
        var forcedTerminationSent = false
        var didTimeOut = false

        while process.isRunning {
            let now = Date()
            if cancellationToken.isCancelled || now >= exportDeadline {
                didTimeOut = didTimeOut || !cancellationToken.isCancelled
                if terminationRequestedAt == nil {
                    process.terminate()
                    terminationRequestedAt = now
                }
            }
            if let terminationRequestedAt,
               !forcedTerminationSent,
               now.timeIntervalSince(terminationRequestedAt) >= 0.5,
               process.isRunning {
                let processID = process.processIdentifier
                if processID > 0 {
                    _ = Darwin.kill(processID, SIGKILL)
                }
                forcedTerminationSent = true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        if cancellationToken.isCancelled { throw exportCancellationError() }
        if didTimeOut {
            throw NSError(
                domain: "LightAudioFFmpeg",
                code: 31,
                userInfo: [NSLocalizedDescriptionKey: L10n.tr("Audio encoding timed out. Check the FFmpeg setting in Preferences and try again.")]
            )
        }
        guard process.terminationStatus == 0 else {
            errorLock.lock()
            let message = String(data: errorData, encoding: .utf8) ?? L10n.tr("External encoder failed.")
            errorLock.unlock()
            throw NSError(domain: "LightAudioFFmpeg", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func ffmpegArguments(inputURL: URL, settings: ExportSettings) -> [String] {
        var args = ["-y", "-nostdin", "-hide_banner", "-loglevel", "error", "-progress", "pipe:1", "-nostats", "-i", inputURL.path, "-ar", "\(Int(settings.sampleRate))", "-ac", "\(settings.channelCount)"]
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

    private func ffmpegTimeout(for duration: TimeInterval) -> TimeInterval {
        let safeDuration = duration.isFinite ? max(0, duration) : 0
        return min(4 * 60 * 60, max(300, safeDuration * 12 + 120))
    }

    private func renderedDuration(for project: Project, settings: ExportSettings) -> TimeInterval {
        switch settings.range {
        case .entireProject:
            return max(0, project.duration)
        case .timeRange(let start, let end):
            return max(0, abs(end - start))
        }
    }
}

#endif

final class ExportService {
    private let operationLock = NSLock()
    private var activeCancellationToken: ExportCancellationToken?

    var isExporting: Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        return activeCancellationToken != nil
    }

    func export(project: Project, settings: ExportSettings, progress: @escaping (Double) -> Void, completion: @escaping (Result<ExportResult, Error>) -> Void) {
        let cancellationToken = ExportCancellationToken()
        operationLock.lock()
        let previousToken = activeCancellationToken
        activeCancellationToken = cancellationToken
        operationLock.unlock()
        previousToken?.cancel()

        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.finish(cancellationToken) }
            do {
                if cancellationToken.isCancelled { throw exportCancellationError() }
                try settings.validate()
                try validateExportDestination(settings.outputURL, for: project)
                try self.validateProjectMedia(project)
                let result: ExportResult
                switch settings.format {
                case .wav, .aiff:
                    result = try NativeAudioExportBackend().export(project: project, settings: settings, cancellationToken: cancellationToken, progress: progress)
                case .m4a, .mp3, .flac:
                    #if os(macOS)
                    result = try ExternalEncoderExportBackend().export(project: project, settings: settings, cancellationToken: cancellationToken, progress: progress)
                    #else
                    throw NSError(domain: "LightAudioExport", code: 53, userInfo: [NSLocalizedDescriptionKey: "Choose WAV or AIFF on iPad. Compressed export is not available yet."])
                    #endif
                }
                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func cancel() {
        operationLock.lock()
        let token = activeCancellationToken
        operationLock.unlock()
        token?.cancel()
    }

    private func finish(_ cancellationToken: ExportCancellationToken) {
        operationLock.lock()
        if activeCancellationToken === cancellationToken {
            activeCancellationToken = nil
        }
        operationLock.unlock()
    }

    private func validateProjectMedia(_ project: Project) throws {
        try ProjectFileService().validateForRendering(project)
        let unavailableSources = project.assets.filter { asset in
            guard !asset.isMissing, let sourceURL = asset.resolvedURL else { return true }
            return !FileManager.default.fileExists(atPath: sourceURL.path)
        }
        guard unavailableSources.isEmpty else {
            let names = unavailableSources.map { $0.metadata.fileName }.sorted().joined(separator: "\n")
            throw NSError(domain: "LightAudio", code: 12, userInfo: [NSLocalizedDescriptionKey: L10n.format("Relink missing media before exporting:\n%@", names)])
        }

        let unavailableProxies = TimelineRenderService().unavailableAudioProxyAssets(in: project)
        guard unavailableProxies.isEmpty else {
            let names = unavailableProxies.map { $0.metadata.fileName }.sorted().joined(separator: "\n")
            throw NSError(domain: "LightAudio", code: 13, userInfo: [NSLocalizedDescriptionKey: L10n.format("Finish generating or relink unavailable audio proxies before exporting:\n%@", names)])
        }

        let assetIDs = Set(project.assets.map(\.id))
        let hasUnresolvedClip = project.timeline.tracks.contains { track in
            track.clips.contains { !assetIDs.contains($0.sourceAssetID) }
        }
        guard !hasUnresolvedClip else {
            throw NSError(domain: "LightAudio", code: 14, userInfo: [NSLocalizedDescriptionKey: L10n.tr("This project contains clips with unresolved media references.")])
        }
    }
}
