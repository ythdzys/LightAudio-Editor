import Foundation
import os
import CryptoKit

final class WaveformCacheService {
    private var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LightAudio Editor/Waveforms", isDirectory: true)
    }

    func cacheKey(for asset: MediaAsset, fileURL: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? asset.metadata.fileSize ?? 0
        let identity = [
            "waveform-cache-v\(WaveformData.currentCacheFormatVersion)",
            asset.kind.rawValue,
            fileURL.standardizedFileURL.path,
            "\(size)",
            "\(modified)",
            "\(asset.metadata.duration)",
            "\(asset.metadata.sampleRate)",
            "\(asset.metadata.channelCount)",
            asset.proxyCacheKey ?? "",
            asset.metadata.checksum ?? ""
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func load(cacheKey: String) -> WaveformData? {
        let trace = OSSignpostID(log: MediaPreparationScheduler.log)
        os_signpost(.begin, log: MediaPreparationScheduler.log, name: "Waveform cache load", signpostID: trace)
        defer { os_signpost(.end, log: MediaPreparationScheduler.log, name: "Waveform cache load", signpostID: trace) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let url = cacheURL(for: cacheKey)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let waveform = try? decoder.decode(WaveformData.self, from: data),
              waveform.cacheFormatVersion == WaveformData.currentCacheFormatVersion else {
            return nil
        }
        return waveform
    }

    func save(_ waveform: WaveformData) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(waveform)
        try data.write(to: cacheURL(for: waveform.cacheKey), options: .atomic)
    }

    func delete(cacheKey: String) throws {
        let url = cacheURL(for: cacheKey)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func cacheURL(for cacheKey: String) -> URL {
        cacheDirectory.appendingPathComponent("\(cacheKey).waveform.json")
    }
}
