import Foundation

struct ApplicationCacheClearResult {
    let waveformFileCount: Int
    let proxyFileCount: Int
    let recoveryFileCount: Int

    var summary: String {
        let total = waveformFileCount + proxyFileCount + recoveryFileCount
        if total == 0 {
            return "App cache is already empty"
        }
        return "Cleared \(total) cached item\(total == 1 ? "" : "s")"
    }
}

final class ApplicationCacheService {
    private let fileManager = FileManager.default

    private var applicationSupportDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LightAudio Editor", isDirectory: true)
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
