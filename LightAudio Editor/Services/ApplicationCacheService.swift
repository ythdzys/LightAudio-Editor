import Foundation

struct ApplicationCacheClearResult {
    let waveformFileCount: Int
    let proxyFileCount: Int
    let recoveryFileCount: Int

    var summary: String {
        let total = waveformFileCount + proxyFileCount + recoveryFileCount
        if total == 0 {
            return L10n.tr("App cache is already empty")
        }
        return L10n.format(total == 1 ? "Cleared %d cached item" : "Cleared %d cached items", total)
    }
}

struct ApplicationCacheUsage {
    let waveformBytes: Int64
    let proxyBytes: Int64
    let recoveryBytes: Int64
    var totalBytes: Int64 { waveformBytes + proxyBytes + recoveryBytes }
}

final class ApplicationCacheService {
    private let fileManager = FileManager.default

    private let applicationSupportDirectory: URL

    init(applicationSupportDirectory: URL? = nil) {
        self.applicationSupportDirectory = applicationSupportDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LightAudio Editor", isDirectory: true)
    }

    func measureApplicationCaches(completion: @escaping (Result<ApplicationCacheUsage, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async { [applicationSupportDirectory] in
            let result = Result {
                try ApplicationCacheUsage(
                    waveformBytes: Self.byteCount(in: applicationSupportDirectory.appendingPathComponent("Waveforms")),
                    proxyBytes: Self.byteCount(in: applicationSupportDirectory.appendingPathComponent("Media Proxies")),
                    recoveryBytes: Self.byteCount(in: applicationSupportDirectory.appendingPathComponent("Recovery")))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func byteCount(in directory: URL) throws -> Int64 {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return 0 }
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { return 0 }
        var traversalError: Error?
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let entries = manager.enumerator(at: directory, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
            traversalError = error; return false
        })
        var bytes: Int64 = 0
        while let url = entries?.nextObject() as? URL {
            do {
                let values = try url.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { continue }
                if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
            } catch {
                // Background cache jobs may replace/remove a file during measurement.
                if manager.fileExists(atPath: url.path) { throw error }
            }
        }
        if let error = traversalError { throw error }
        return bytes
    }

    func clearApplicationCaches(completion: @escaping (Result<ApplicationCacheClearResult, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async { [fileManager, applicationSupportDirectory] in
            do {
                let waveformCount = try Self.clearDirectory(
                    applicationSupportDirectory.appendingPathComponent("Waveforms", isDirectory: true),
                    using: fileManager
                )
                let proxyCount = try Self.clearDirectory(
                    applicationSupportDirectory.appendingPathComponent("Media Proxies", isDirectory: true),
                    using: fileManager
                )
                let recoveryCount = try Self.clearDirectory(
                    applicationSupportDirectory.appendingPathComponent("Recovery", isDirectory: true),
                    using: fileManager
                )
                let result = ApplicationCacheClearResult(
                    waveformFileCount: waveformCount,
                    proxyFileCount: proxyCount,
                    recoveryFileCount: recoveryCount
                )
                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private static func clearDirectory(_ directory: URL, using fileManager: FileManager) throws -> Int {
        guard fileManager.fileExists(atPath: directory.path) else { return 0 }
        let contents = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects ?? []
        try fileManager.removeItem(at: directory)
        return contents.count
    }
}
