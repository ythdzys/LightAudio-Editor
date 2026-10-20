import Foundation
import AVFoundation
import CryptoKit

final class MediaProxyService {
    enum ProxyGenerationError: LocalizedError {
        case cancelled
        case timedOut

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Audio proxy generation was cancelled."
            case .timedOut:
                return "Audio proxy generation timed out. Try regenerating the proxy or use a shorter source file."
            }
        }
    }

    /// Owns one AVFoundation decode operation. Keeping this separate from the controller lets
    /// cache clears, project switches, and explicit user cancellation all stop the same work.
    final class ProxyGenerationHandle {
        private let lock = NSLock()
        fileprivate let checksumCancellation = ExportCancellationToken()
        private var reader: AVAssetReader?
        private var cancellationHandler: (() -> Void)?
        private var cancelled = false
        private var preparationJob: MediaPreparationScheduler.Job?

        func cancel() {
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                return
            }
            cancelled = true
            let session = reader
            let handler = cancellationHandler
            let job = preparationJob
            lock.unlock()
            job?.cancel()
            checksumCancellation.cancel()

            session?.cancelReading()
            handler?()
        }

        fileprivate func installJob(_ job: MediaPreparationScheduler.Job) {
            lock.lock(); preparationJob = job; let cancel = cancelled; lock.unlock()
            if cancel { job.cancel() }
        }

        fileprivate var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        @discardableResult
        fileprivate func install(_ session: AVAssetReader) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { return false }
            reader = session
            return true
        }

        fileprivate func setCancellationHandler(_ handler: @escaping () -> Void) {
            lock.lock()
            cancellationHandler = handler
            let shouldNotify = cancelled
            lock.unlock()

            if shouldNotify {
                handler()
            }
        }
    }

    private final class CompletionGate {
        private let lock = NSLock()
        private var hasClaimedCompletion = false
        private let completion: (Result<MediaAsset, Error>) -> Void

        init(completion: @escaping (Result<MediaAsset, Error>) -> Void) {
            self.completion = completion
        }

        /// Claims the right to complete exactly once. The caller may safely perform final file
        /// publication after this succeeds because timeout/cancellation callbacks will stand down.
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !hasClaimedCompletion else { return false }
            hasClaimedCompletion = true
            return true
        }

        func deliver(_ result: Result<MediaAsset, Error>) {
            DispatchQueue.main.async { [completion] in
                completion(result)
            }
        }
    }

    private let scheduler: MediaPreparationScheduler
    private let proxyDirectory: URL

    init(proxyDirectory: URL? = nil, scheduler: MediaPreparationScheduler = .shared) {
        self.scheduler = scheduler
        if let proxyDirectory {
            self.proxyDirectory = proxyDirectory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.proxyDirectory = base.appendingPathComponent("LightAudio Editor/Media Proxies", isDirectory: true)
        }
    }

    func cacheKey(for asset: MediaAsset, sourceURL: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? asset.metadata.fileSize ?? 0
        let identity = [
            "lossless-pcm-v4-container-edits",
            sourceURL.standardizedFileURL.path,
            "\(size)",
            "\(modified)",
            "\(asset.metadata.duration)",
            "\(asset.metadata.sampleRate)",
            "\(asset.metadata.channelCount)",
            asset.metadata.checksum ?? ""
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func existingValidProxy(for asset: MediaAsset) -> URL? {
        guard asset.requiresAudioPreparation,
              let sourceURL = asset.resolvedURL,
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            return nil
        }
        let key = cacheKey(for: asset, sourceURL: sourceURL)
        let proxyURL = managedProxyURL(for: key)
        guard isUsableProxy(proxyURL, duration: asset.metadata.duration, rate: asset.metadata.sampleRate, channels: asset.metadata.channelCount) else {
            return nil
        }
        return proxyURL
    }

    func invalidateProxy(for asset: MediaAsset) {
        if let proxyPath = asset.proxyPath {
            removeManagedProxy(at: URL(fileURLWithPath: proxyPath))
        }
        guard asset.requiresAudioPreparation,
              let sourceURL = asset.resolvedURL,
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            return
        }
        let key = cacheKey(for: asset, sourceURL: sourceURL)
        removeManagedProxy(at: managedProxyURL(for: key))
    }

    /// Returns a handle immediately. Completion is always delivered on the main queue.
    @discardableResult
    func prepareProxy(for asset: MediaAsset, completion: @escaping (Result<MediaAsset, Error>) -> Void) -> ProxyGenerationHandle {
        let handle = ProxyGenerationHandle()
        let gate = CompletionGate(completion: completion)
        handle.setCancellationHandler {
            guard gate.claim() else { return }
            gate.deliver(.failure(ProxyGenerationError.cancelled))
        }

        let job = scheduler.submit { [self] _, finished in
            defer { finished() }
            guard !handle.isCancelled else { return }
            guard asset.requiresAudioPreparation else {
                if gate.claim() { gate.deliver(.success(asset)) }; return
            }
            let timeout = DispatchWorkItem {
                guard gate.claim() else { return }
                handle.cancel()
                gate.deliver(.failure(ProxyGenerationError.timedOut))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutInterval(for: asset), execute: timeout)
            defer { timeout.cancel() }
            let staging = proxyDirectory.appendingPathComponent(".\(UUID().uuidString).partial.caf")
            defer { try? FileManager.default.removeItem(at: staging) }
            var ownsCompletion = false
            do {
                guard let sourceURL = asset.resolvedURL else { throw proxyError("Source media is missing.") }
                let plan = try VideoAudioPlan(asset: AVURLAsset(url: sourceURL), preserveLeadingSilence: asset.kind == .audio)
                var updated = asset
                updated.metadata.duration = plan.duration
                updated.metadata.sampleRate = plan.sampleRate
                updated.metadata.channelCount = plan.channelCount
                let key = cacheKey(for: updated, sourceURL: sourceURL)
                let output = managedProxyURL(for: key)
                var stagingDigest: String?
                if !isUsableProxy(output, plan: plan, cancellation: handle.checksumCancellation) {
                    try FileManager.default.createDirectory(at: proxyDirectory, withIntermediateDirectories: true)
                    try extractPCM(plan: plan, to: staging, handle: handle)
                    guard decodedExtentIsValid(staging, duration: plan.duration, rate: plan.sampleRate, channels: plan.channelCount) else {
                        throw proxyError(L10n.tr("Generated audio proxy could not be read."))
                    }
                    stagingDigest = try FileMetadataHasher.fullChecksum(for: staging, cancellation: handle.checksumCancellation)
                }
                guard !handle.isCancelled, gate.claim() else { return }
                ownsCompletion = true
                let url = isUsableProxy(output, plan: plan, allowHashing: false) ? output : try publishProxy(stagingURL: staging, outputURL: output, plan: plan, digest: stagingDigest)
                updated.proxyPath = url.path; updated.proxyCacheKey = key
                updated.proxyStatus = .ready; updated.proxyFailureReason = nil
                gate.deliver(.success(updated))
            } catch {
                if ownsCompletion || gate.claim() { gate.deliver(.failure(error)) }
            }
        }
        handle.installJob(job)
        return handle
    }

    /// A self-contained source for portable projects, independent of this device's proxy cache.
    /// Uses the same native-rate float PCM and container edit handling as playback.
    func exportLosslessAudio(from source: URL, to destination: URL,
                             cancellation: ExportCancellationToken) throws -> MediaFileMetadata {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        let handle = ProxyGenerationHandle()
        let handler = cancellation.addCancellationHandler { handle.cancel() }
        defer { cancellation.removeCancellationHandler(handler) }
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: destination) } }
        do {
            let plan = try VideoAudioPlan(asset: AVURLAsset(url: source))
            try extractPCM(plan: plan, to: destination, handle: handle)
            if cancellation.isCancelled { throw CocoaError(.userCancelled) }
            guard decodedExtentIsValid(destination, duration: plan.duration, rate: plan.sampleRate, channels: plan.channelCount) else {
                throw proxyError(L10n.tr("Generated audio proxy could not be read."))
            }
            let checksum = try FileMetadataHasher.fullChecksum(for: destination, cancellation: cancellation)
            let size = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber
            complete = true
            return MediaFileMetadata(fileName: destination.lastPathComponent, fileSize: size?.int64Value,
                duration: plan.duration, sampleRate: plan.sampleRate, channelCount: plan.channelCount, checksum: checksum)
        } catch {
            if cancellation.isCancelled { throw CocoaError(.userCancelled) }
            throw error
        }
    }

    private func extractPCM(plan: VideoAudioPlan, to url: URL, handle: ProxyGenerationHandle) throws {
        if plan.tracks.contains(where: { track in track.segments.contains { segment in
            !segment.isEmpty && CMTimeCompare(segment.timeMapping.source.duration, segment.timeMapping.target.duration) != 0
        } }) {
            try extractRetimedPCM(plan: plan, to: url, handle: handle)
            return
        }
        let reader = try AVAssetReader(asset: plan.asset)
        guard handle.install(reader) else { throw ProxyGenerationError.cancelled }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: plan.sampleRate]
        let output: AVAssetReaderOutput
        if plan.tracks.count == 1 {
            let single = AVAssetReaderTrackOutput(track: plan.tracks[0], outputSettings: settings)
            single.audioTimePitchAlgorithm = .varispeed
            output = single
        } else {
            var mixed = settings; mixed[AVNumberOfChannelsKey] = 2
            let mix = AVAssetReaderAudioMixOutput(audioTracks: plan.tracks, audioSettings: mixed)
            mix.audioTimePitchAlgorithm = .varispeed
            output = mix
        }
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw proxyError(L10n.tr("This video's audio cannot be decoded.")) }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: plan.start, preferredTimescale: 1_000_000_000),
                                      duration: CMTime(seconds: plan.duration, preferredTimescale: 1_000_000_000))
        guard reader.startReading() else { throw reader.error ?? proxyError(L10n.tr("Audio decoding failed.")) }
        defer { reader.cancelReading() }
        var file: AVAudioFile?
        var written: Int64 = 0
        let total = Int64(AudioFrameMath.ceiling(plan.duration * plan.sampleRate))
        while true {
            let hasSample = try autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { return false }
                if handle.isCancelled { throw ProxyGenerationError.cancelled }
                guard let description = CMSampleBufferGetFormatDescription(sample),
                      let format = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat? else { throw proxyError(L10n.tr("Unreadable decoded audio format.")) }
                if file == nil { file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved) }
                let sampleStart = Int64(((CMSampleBufferGetPresentationTimeStamp(sample).seconds - plan.start) * plan.sampleRate).rounded())
                // Preserve gaps between edits/tracks. Trim only the container's leading silence.
                while written < min(total, sampleStart) {
                    let count = UInt32(min(4096, min(total, sampleStart) - written))
                    guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { throw proxyError(L10n.tr("Could not allocate audio buffer.")) }
                    silence.frameLength = count
                    for entry in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) { if let data = entry.mData { memset(data, 0, Int(entry.mDataByteSize)) } }
                    try file!.write(from: silence); written += Int64(count)
                    if handle.isCancelled { throw ProxyGenerationError.cancelled }
                }
                let skip = max(0, written - sampleStart)
                let count = min(Int64(CMSampleBufferGetNumSamples(sample)) - skip, total - written)
                if count > 0 {
                    guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count)) else { throw proxyError(L10n.tr("Could not allocate audio buffer.")) }
                    pcm.frameLength = UInt32(count)
                    guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: Int32(skip), frameCount: Int32(count), into: pcm.mutableAudioBufferList) == noErr else { throw proxyError(L10n.tr("Could not copy decoded audio.")) }
                    try file!.write(from: pcm); written += count
                }
                return true
            }
            if !hasSample { break }
        }
        guard !handle.isCancelled else { throw ProxyGenerationError.cancelled }
        guard reader.status == .completed, written == total else { throw reader.error ?? proxyError(L10n.tr("Decoded audio is incomplete.")) }
        file = nil
    }

    /// Decode each edit at its native speed before rate conversion. AVAssetReader's native
    /// time-stretcher can finish without draining its tail, even with .varispeed selected.
    /// Changing the movie edit map in memory bypasses that path; the source file is never written.
    /// The explicit policy is varispeed: duration changes pitch as well as speed.
    private func extractRetimedPCM(plan: VideoAudioPlan, to url: URL, handle: ProxyGenerationHandle) throws {
        guard let source = plan.asset as? AVURLAsset else {
            throw proxyError(L10n.tr("This movie's retimed audio cannot be prepared. Export it at normal speed before importing."))
        }
        let directory = proxyDirectory.appendingPathComponent(".\(UUID().uuidString).retiming", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let assembled = AVMutableComposition()
        for original in plan.tracks {
            guard let destination = assembled.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw proxyError(L10n.tr("Could not prepare retimed audio."))
            }
            for segment in original.segments where !segment.isEmpty {
                if handle.isCancelled { throw ProxyGenerationError.cancelled }
                let mapping = segment.timeMapping
                guard mapping.source.duration.seconds > 0, mapping.target.duration.seconds > 0 else {
                    throw proxyError(L10n.tr("This movie contains an unsupported audio edit rate."))
                }
                // Rebuild only the edit map using media sample coordinates. Scaling target
                // ranges on AAC movies can reinterpret priming and leave a retimed tail.
                // Removing edits retains the source sample tables; no source bytes are written.
                let movie = AVMutableMovie(url: source.url, options: nil)
                guard let track = movie.tracks(withMediaType: .audio).first(where: { $0.trackID == original.trackID }) else {
                    throw proxyError(L10n.tr("Could not prepare retimed audio."))
                }
                for other in movie.tracks where other.trackID != track.trackID { movie.removeTrack(other) }
                // Include unpresented encoder priming/padding: removing just timeRange
                // can leave residual AAC edits beyond its reported presentation end.
                let clearEnd = CMTimeAdd(track.timeRange.end, track.mediaPresentationTimeRange.end)
                track.removeTimeRange(CMTimeRange(start: .zero, duration: clearEnd))
                guard track.segments.allSatisfy({ $0.isEmpty }) else {
                    throw proxyError(L10n.tr("Could not prepare retimed audio."))
                }
                // Movie edits can express a sample boundary at nanosecond precision. Return
                // source bounds to the audio sample grid before asking the decoder to drain.
                let sourceScale = original.naturalTimeScale
                guard sourceScale > 0 else { throw proxyError(L10n.tr("Could not prepare retimed audio.")) }
                let mediaStart = CMTimeConvertScale(mapping.source.start, timescale: sourceScale, method: .roundHalfAwayFromZero)
                let mediaEnd = CMTimeConvertScale(mapping.source.end, timescale: sourceScale, method: .roundHalfAwayFromZero)
                let mediaRange = CMTimeRange(start: mediaStart, end: mediaEnd)
                guard track.insertMediaTimeRange(mediaRange, into: CMTimeRange(start: .zero, duration: mediaRange.duration)) else {
                    throw proxyError(L10n.tr("Could not prepare retimed audio."))
                }
                let nativePlan = try VideoAudioPlan(asset: movie)
                guard !nativePlan.tracks.contains(where: { $0.segments.contains { !$0.isEmpty && CMTimeCompare($0.timeMapping.source.duration, $0.timeMapping.target.duration) != 0 } }) else {
                    throw proxyError(L10n.tr("This movie contains an unsupported audio edit rate."))
                }
                let nativeURL = directory.appendingPathComponent("native-\(UUID().uuidString).caf")
                try extractPCM(plan: nativePlan, to: nativeURL, handle: handle)
                let start = Int64(((mapping.target.start.seconds - plan.start) * plan.sampleRate).rounded())
                let end = Int64(AudioFrameMath.ceiling((mapping.target.end.seconds - plan.start) * plan.sampleRate))
                guard end > start else { continue }
                let convertedURL = directory.appendingPathComponent("timed-\(UUID().uuidString).caf")
                try convertEdit(at: nativeURL, to: convertedURL, frames: end - start, rate: plan.sampleRate, handle: handle)
                let converted = AVURLAsset(url: convertedURL)
                defer { withExtendedLifetime(converted) {} }
                guard let convertedTrack = converted.tracks(withMediaType: .audio).first else { throw proxyError(L10n.tr("Could not prepare retimed audio.")) }
                try destination.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: Double(end - start) / plan.sampleRate, preferredTimescale: 1_000_000_000)),
                                                of: convertedTrack, at: CMTime(seconds: Double(start) / plan.sampleRate, preferredTimescale: 1_000_000_000))
                try FileManager.default.removeItem(at: nativeURL)
            }
        }
        try extractPCM(plan: VideoAudioPlan(asset: assembled, preserveLeadingSilence: true), to: url, handle: handle)
    }

    private func convertEdit(at source: URL, to destination: URL, frames: Int64, rate: Double, handle: ProxyGenerationHandle) throws {
        let input = try AVAudioFile(forReading: source)
        let native = input.processingFormat
        let virtualRate = Double(input.length) / Double(frames) * rate
        func format(rate: Double) -> AVAudioFormat? {
            if let layout = native.channelLayout {
                return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: layout)
            }
            return AVAudioFormat(standardFormatWithSampleRate: rate, channels: native.channelCount)
        }
        guard virtualRate.isFinite, virtualRate > 0,
              let sourceFormat = format(rate: virtualRate), let outputFormat = format(rate: rate),
              let converter = AVAudioConverter(from: sourceFormat, to: outputFormat),
              let readBuffer = AVAudioPCMBuffer(pcmFormat: native, frameCapacity: 4096),
              let adjusted = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else {
            throw proxyError(L10n.tr("This movie contains an unsupported audio edit rate."))
        }
        converter.sampleRateConverterQuality = 127
        converter.primeMethod = .normal
        let file = try AVAudioFile(forWriting: destination, settings: outputFormat.settings)
        var written: Int64 = 0, inputError: Error?
        while written < frames {
            if handle.isCancelled { throw ProxyGenerationError.cancelled }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, state in
                guard !handle.isCancelled, input.framePosition < input.length, inputError == nil else {
                    state.pointee = .endOfStream; return nil
                }
                do {
                    try input.read(into: readBuffer, frameCount: min(requested, readBuffer.frameCapacity))
                    adjusted.frameLength = readBuffer.frameLength
                    guard adjusted.frameLength > 0 else { state.pointee = .endOfStream; return nil }
                    for channel in 0..<Int(native.channelCount) {
                        memcpy(adjusted.floatChannelData![channel], readBuffer.floatChannelData![channel], Int(adjusted.frameLength) * MemoryLayout<Float>.size)
                    }
                    state.pointee = .haveData; return adjusted
                } catch { inputError = error; state.pointee = .endOfStream; return nil }
            }
            if let inputError { throw inputError }
            if let error { throw error }
            guard status != .error else { throw proxyError(L10n.tr("Could not convert retimed audio.")) }
            output.frameLength = UInt32(min(Int64(output.frameLength), frames - written))
            if output.frameLength > 0 { try file.write(from: output); written += Int64(output.frameLength) }
            else { break }
            if status == .endOfStream { break }
        }
        guard !handle.isCancelled else { throw ProxyGenerationError.cancelled }
        guard written == frames else { throw proxyError(L10n.tr("Retimed audio decoding is incomplete.")) }
    }

    private func publishProxy(stagingURL: URL, outputURL: URL, plan: VideoAudioPlan, digest: String?) throws -> URL {
        guard decodedExtentIsValid(stagingURL, duration: plan.duration, rate: plan.sampleRate, channels: plan.channelCount) else {
            throw proxyError(L10n.tr("Generated audio proxy could not be read."))
        }
        guard let digest else { throw proxyError(L10n.tr("Generated audio proxy could not be read.")) }
        if isUsableProxy(outputURL, plan: plan, allowHashing: false) { return outputURL }
        removeManagedProxy(at: outputURL)
        try FileManager.default.moveItem(at: stagingURL, to: outputURL)
        do {
            try Data(digest.utf8).write(to: integrityURL(for: outputURL), options: .atomic)
            guard decodedExtentIsValid(outputURL, duration: plan.duration, rate: plan.sampleRate, channels: plan.channelCount) else { throw proxyError(L10n.tr("Generated audio proxy could not be read.")) }
        } catch {
            removeManagedProxy(at: outputURL)
            throw error
        }
        return outputURL
    }

    private func timeoutInterval(for asset: MediaAsset) -> TimeInterval {
        let duration = max(0, asset.metadata.duration)
        return min(3_600, max(120, duration * 4))
    }

    private func managedProxyURL(for cacheKey: String) -> URL {
        proxyDirectory.appendingPathComponent("\(cacheKey).caf")
    }

    private func removeManagedProxy(at url: URL) {
        guard isManagedProxyURL(url), FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: integrityURL(for: url))
    }

    private func isManagedProxyURL(_ url: URL) -> Bool {
        let directoryPath = proxyDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : "\(directoryPath)/"
        return candidatePath.hasPrefix(prefix)
    }

    private func proxyError(_ message: String) -> NSError {
        NSError(domain: "LightAudioProxy", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func integrityURL(for url: URL) -> URL { url.appendingPathExtension("sha256") }

    private func isUsableProxy(_ url: URL, plan: VideoAudioPlan, cancellation: ExportCancellationToken? = nil, allowHashing: Bool = true) -> Bool {
        isUsableProxy(url, duration: plan.duration, rate: plan.sampleRate, channels: plan.channelCount, cancellation: cancellation, allowHashing: allowHashing)
    }

    private func isUsableProxy(_ url: URL, duration: Double, rate: Double, channels: Int, cancellation: ExportCancellationToken? = nil, allowHashing: Bool = true) -> Bool {
        guard decodedExtentIsValid(url, duration: duration, rate: rate, channels: channels),
              let expected = try? String(contentsOf: integrityURL(for: url), encoding: .utf8),
              expected.hasPrefix("sha256:"),
              let actual = allowHashing ? (try? FileMetadataHasher.verifiedFullChecksum(for: url, cancellation: cancellation))
                  : FileMetadataHasher.cachedFullChecksum(for: url) else { return false }
        // The digest covers the complete CAF, including its channel-layout header and PCM data.
        return actual == expected
    }

    private func decodedExtentIsValid(_ url: URL, duration: Double, rate: Double, channels: Int) -> Bool {
        do {
            let file = try AVAudioFile(forReading: url)
            guard duration.isFinite, duration > 0, rate.isFinite, rate > 0,
                  file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM,
                  file.fileFormat.commonFormat == .pcmFormatFloat32,
                  file.length == Int64(AudioFrameMath.ceiling(duration * rate)),
                  file.processingFormat.sampleRate == rate,
                  file.processingFormat.channelCount == channels,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1) else { return false }
            try file.read(into: buffer, frameCount: 1)
            guard buffer.frameLength == 1 else { return false }
            file.framePosition = file.length - 1
            try file.read(into: buffer, frameCount: 1)
            return buffer.frameLength == 1
        } catch { return false }
    }
}
