import Foundation
import CryptoKit
import Darwin

enum FileMetadataHasher {
    /// Throwing, bounded file I/O also available on the macOS 10.15 deployment target.
    static func readData(_ handle: FileHandle, count: Int = 1024 * 1024) throws -> Data {
        var data = Data(count: count)
        let amount = data.withUnsafeMutableBytes { bytes -> Int in
            var result: Int
            repeat { result = Darwin.read(handle.fileDescriptor, bytes.baseAddress!, count) } while result < 0 && errno == EINTR
            return result
        }
        guard amount >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        data.count = amount
        return data
    }

    static func writeData(_ data: Data, to handle: FileHandle) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.write(handle.fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                offset += amount
            }
        }
    }

    // An inode replacement or write changes ctime even when a provider restores size/mtime.
    // This is a process-local optimization, never a persisted substitute for a content hash.
    private static let verified: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>(); cache.countLimit = 1024; return cache
    }()
    private static func identity(for url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return "\(url.standardizedFileURL.path)|\(info.st_dev)|\(info.st_ino)|\(info.st_size)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)|\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
    }
    static func cachedFullChecksum(for url: URL) -> String? {
        guard let key = identity(for: url) else { return nil }
        return verified.object(forKey: key as NSString) as String?
    }
    static func verifiedFullChecksum(for url: URL, cancellation: ExportCancellationToken? = nil) throws -> String {
        if cancellation?.isCancelled == true { throw CocoaError(.userCancelled) }
        return try cachedFullChecksum(for: url) ?? fullChecksum(for: url, cancellation: cancellation)
    }
    static func clearVerificationCache() { verified.removeAllObjects() }

    /// Versioned full-file identity. Legacy unprefixed values cover only the first MiB.
    static func fullChecksum(for url: URL, cancellation: ExportCancellationToken? = nil,
                             readChunk: (FileHandle) throws -> Data = { try readData($0) }) throws -> String {
        var retriesRemaining = 2
        while true {
            do { return try checksumAttempt(for: url, cancellation: cancellation, readChunk: readChunk) }
            catch {
                let failure = error as NSError
                // iPadOS can finish updating file metadata after a collection moves.
                // Discard the interrupted digest and require a complete stable read;
                // callers still compare it with the recorded content fingerprint.
                guard failure.domain == "LightAudio", failure.code == 21, retriesRemaining > 0 else { throw error }
                if cancellation?.isCancelled == true { throw CocoaError(.userCancelled) }
                retriesRemaining -= 1
            }
        }
    }

    private static func checksumAttempt(for url: URL, cancellation: ExportCancellationToken?,
                                        readChunk: (FileHandle) throws -> Data) throws -> String {
        let before = identity(for: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            // Foundation can autorelease each read buffer until the worker returns.
            // Drain per chunk so large-video verification stays bounded in memory.
            let hasData = try autoreleasepool {
                if cancellation?.isCancelled == true { throw CocoaError(.userCancelled) }
                let data = try readChunk(handle)
                guard !data.isEmpty else { return false }
                digest.update(data: data)
                return true
            }
            if !hasData { break }
        }
        guard cancellation?.isCancelled != true else { throw CocoaError(.userCancelled) }
        guard let before, before == identity(for: url) else {
            throw NSError(domain: "LightAudio", code: 21, userInfo: [NSLocalizedDescriptionKey: L10n.tr("Source media changed during verification. Try opening it again.")])
        }
        let result = "sha256:" + digest.finalize().map { String(format: "%02x", $0) }.joined()
        verified.setObject(result as NSString, forKey: before as NSString)
        return result
    }

    static func matches(_ expected: String, url: URL, cancellation: ExportCancellationToken? = nil) throws -> Bool {
        if cancellation?.isCancelled == true { throw CocoaError(.userCancelled) }
        if expected.hasPrefix("sha256:") { return try fullChecksum(for: url, cancellation: cancellation) == expected }
        return sha256Prefix(for: url) == expected
    }

    static func sha256Prefix(for url: URL, maxBytes: Int = 1024 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: maxBytes)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
