import Foundation
import AVFoundation
import CryptoKit

final class MediaProxyService {
    private var proxyDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LightAudio Editor/Media Proxies", isDirectory: true)
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
        guard asset.proxyCacheKey == key,
              let proxyPath = asset.proxyPath,
              isUsableFile(URL(fileURLWithPath: proxyPath)) else {
            return nil
        }
        return URL(fileURLWithPath: proxyPath)
    }

    func invalidateProxy(for asset: MediaAsset) {
        if let proxyPath = asset.proxyPath, FileManager.default.fileExists(atPath: proxyPath) {
            try? FileManager.default.removeItem(atPath: proxyPath)
        }
        guard asset.kind == .videoAudio,
              let sourceURL = asset.resolvedURL,
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            return
        }
        let key = cacheKey(for: asset, sourceURL: sourceURL)
        let cachedURL = proxyDirectory.appendingPathComponent("\(key).m4a")
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            try? FileManager.default.removeItem(at: cachedURL)
        }
    }

    func prepareProxy(for asset: MediaAsset, completion: @escaping (Result<MediaAsset, Error>) -> Void) {
        guard asset.kind == .videoAudio else {
            completion(.success(asset))
            return
        }
        guard let sourceURL = asset.resolvedURL, FileManager.default.fileExists(atPath: sourceURL.path) else {
            completion(.failure(proxyError("Source media is missing.")))
            return
        }

        let key = cacheKey(for: asset, sourceURL: sourceURL)
        if let proxyPath = asset.proxyPath,
           asset.proxyCacheKey == key,
           FileManager.default.fileExists(atPath: proxyPath) {
            var ready = asset
            ready.proxyStatus = .ready
            ready.proxyFailureReason = nil
            completion(.success(ready))
            return
        }

        DispatchQueue.global(qos: .utility).async {
            do {
                let proxyURL = try self.generateProxy(sourceURL: sourceURL, cacheKey: key)
                var updated = asset
                updated.proxyPath = proxyURL.path
                updated.proxyCacheKey = key
                updated.proxyStatus = .ready
                updated.proxyFailureReason = nil
                DispatchQueue.main.async { completion(.success(updated)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func generateProxy(sourceURL: URL, cacheKey: String) throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard !asset.tracks(withMediaType: .audio).isEmpty else {
            throw proxyError("This video does not contain an audio track.")
        }
        try FileManager.default.createDirectory(at: proxyDirectory, withIntermediateDirectories: true)
        let outputURL = proxyDirectory.appendingPathComponent("\(cacheKey).m4a")
        if isUsableFile(outputURL) {
            return outputURL
        } else if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw proxyError("This video's audio cannot be exported by AVFoundation.")
        }
        session.outputURL = outputURL
        session.outputFileType = .m4a
        session.shouldOptimizeForNetworkUse = false

        let semaphore = DispatchSemaphore(value: 0)
        session.exportAsynchronously {
            semaphore.signal()
        }
        semaphore.wait()

        switch session.status {
        case .completed:
            return outputURL
        case .cancelled:
            throw proxyError("Audio proxy generation was cancelled.")
        default:
            throw session.error ?? proxyError("Audio proxy generation failed.")
        }
    }

    private func proxyError(_ message: String) -> NSError {
        NSError(domain: "LightAudioProxy", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func isUsableFile(_ url: URL) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else {
            return false
        }
        return size > 0
    }
}
