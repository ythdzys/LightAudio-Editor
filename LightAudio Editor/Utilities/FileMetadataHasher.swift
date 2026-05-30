import Foundation
import CryptoKit

enum FileMetadataHasher {
    static func sha256Prefix(for url: URL, maxBytes: Int = 1024 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: maxBytes)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
