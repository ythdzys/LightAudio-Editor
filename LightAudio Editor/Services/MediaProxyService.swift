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

    /// Owns one AVFoundation export operation. Keeping this separate from the controller lets
    /// cache clears, project switches, and explicit user cancellation all stop the same work.
    final class ProxyGenerationHandle {
        private let lock = NSLock()
        private var exportSession: AVAssetExportSession?
        private var cancellationHandler: (() -> Void)?
        private var cancelled = false

        func cancel() {
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                return
            }
            cancelled = true
            let session = exportSession
            let handler = cancellationHandler
            lock.unlock()

            session?.cancelExport()
            handler?()
        }

        fileprivate var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        @discardableResult
        fileprivate func install(_ session: AVAssetExportSession) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { return false }
            exportSession = session
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

    private let proxyDirectory: URL

    init(proxyDirectory: URL? = nil) {
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
        guard asset.kind == .videoAudio,
              let sourceURL = asset.resolvedURL,
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            return nil
        }
        let key = cacheKey(for: asset, sourceURL: sourceURL)
        let proxyURL = managedProxyURL(for: key)
        guard isUsableProxy(proxyURL) else {
            return nil
        }
        return proxyURL
    }

    func invalidateProxy(for asset: MediaAsset) {
        if let proxyPath = asset.proxyPath {
            removeManagedProxy(at: URL(fileURLWithPath: proxyPath))
        }
        guard asset.kind == .videoAudio,
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

        guard asset.kind == .videoAudio else {
            if gate.claim() {
                gate.deliver(.success(asset))
            }
            return handle
        }
        guard let sourceURL = asset.resolvedURL, FileManager.default.fileExists(atPath: sourceURL.path) else {
            if gate.claim() {
                gate.deliver(.failure(self.proxyError("Source media is missing.")))
            }
            return handle
        }

        let key = cacheKey(for: asset, sourceURL: sourceURL)
        if let proxyURL = existingValidProxy(for: asset) {
            var ready = asset
            ready.proxyPath = proxyURL.path
            ready.proxyCacheKey = key
            ready.proxyStatus = .ready
            ready.proxyFailureReason = nil
            if gate.claim() {
                gate.deliver(.success(ready))
            }
            return handle
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard !handle.isCancelled else { return }

            let stagingURL: URL
            let outputURL: URL
            let session: AVAssetExportSession
            do {
                let prepared = try self.makeExportSession(sourceURL: sourceURL, cacheKey: key)
                stagingURL = prepared.stagingURL
                outputURL = prepared.outputURL
                session = prepared.session
            } catch {
                if gate.claim() {
                    gate.deliver(.failure(error))
                }
                return
            }

            guard handle.install(session) else {
                session.cancelExport()
                try? FileManager.default.removeItem(at: stagingURL)
                return
            }

            let timeout = DispatchWorkItem { [weak self, weak session] in
                guard gate.claim() else { return }
                session?.cancelExport()
                try? FileManager.default.removeItem(at: stagingURL)
                self?.finishProxyFailure(ProxyGenerationError.timedOut, gate: gate)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + self.timeoutInterval(for: asset),
                execute: timeout
            )

            session.exportAsynchronously { [weak self, weak session] in
                timeout.cancel()
                guard let self else {
                    try? FileManager.default.removeItem(at: stagingURL)
                    return
                }
                guard gate.claim() else {
                    try? FileManager.default.removeItem(at: stagingURL)
                    return
                }

                defer {
                    if FileManager.default.fileExists(atPath: stagingURL.path) {
                        try? FileManager.default.removeItem(at: stagingURL)
                    }
                }

                if handle.isCancelled || session?.status == .cancelled {
                    self.finishProxyFailure(ProxyGenerationError.cancelled, gate: gate)
                    return
                }

                guard session?.status == .completed else {
                    self.finishProxyFailure(session?.error ?? self.proxyError("Audio proxy generation failed."), gate: gate)
                    return
                }

                do {
                    let proxyURL = try self.publishProxy(stagingURL: stagingURL, outputURL: outputURL)
                    var updated = asset
                    updated.proxyPath = proxyURL.path
                    updated.proxyCacheKey = key
                    updated.proxyStatus = .ready
                    updated.proxyFailureReason = nil
                    gate.deliver(.success(updated))
                } catch {
                    gate.deliver(.failure(error))
                }
            }
        }

        return handle
    }

    private func makeExportSession(sourceURL: URL, cacheKey: String) throws -> (session: AVAssetExportSession, stagingURL: URL, outputURL: URL) {
        let asset = AVURLAsset(url: sourceURL)
        guard !asset.tracks(withMediaType: .audio).isEmpty else {
            throw proxyError("This video does not contain an audio track.")
        }
        try FileManager.default.createDirectory(at: proxyDirectory, withIntermediateDirectories: true)
        let outputURL = managedProxyURL(for: cacheKey)
        let stagingURL = proxyDirectory.appendingPathComponent(".\(cacheKey).\(UUID().uuidString).partial.m4a")
        try? FileManager.default.removeItem(at: stagingURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw proxyError("This video's audio cannot be exported by AVFoundation.")
        }
        session.outputURL = stagingURL
        session.outputFileType = .m4a
        session.shouldOptimizeForNetworkUse = false
        return (session, stagingURL, outputURL)
    }

    private func publishProxy(stagingURL: URL, outputURL: URL) throws -> URL {
        guard isUsableProxy(stagingURL) else {
            throw proxyError("Generated audio proxy could not be read.")
        }
        if isUsableProxy(outputURL) {
            return outputURL
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.moveItem(at: stagingURL, to: outputURL)
        guard isUsableProxy(outputURL) else {
            try? FileManager.default.removeItem(at: outputURL)
            throw proxyError("Generated audio proxy could not be read.")
        }
        return outputURL
    }

    private func timeoutInterval(for asset: MediaAsset) -> TimeInterval {
        let duration = max(0, asset.metadata.duration)
        return min(3_600, max(120, duration * 4))
    }

    private func managedProxyURL(for cacheKey: String) -> URL {
        proxyDirectory.appendingPathComponent("\(cacheKey).m4a")
    }

    private func removeManagedProxy(at url: URL) {
        guard isManagedProxyURL(url), FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func isManagedProxyURL(_ url: URL) -> Bool {
        let directoryPath = proxyDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : "\(directoryPath)/"
        return candidatePath.hasPrefix(prefix)
    }

    private func finishProxyFailure(_ error: Error, gate: CompletionGate) {
        gate.deliver(.failure(error))
    }

    private func proxyError(_ message: String) -> NSError {
        NSError(domain: "LightAudioProxy", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func isUsableProxy(_ url: URL) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
              size > 0 else {
            return false
        }
        do {
            let file = try AVAudioFile(forReading: url)
            return file.length > 0 && file.processingFormat.sampleRate > 0 && file.processingFormat.channelCount > 0
        } catch {
            return false
        }
    }
}
