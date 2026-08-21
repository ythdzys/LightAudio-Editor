import Foundation

enum MediaKind: String, Codable {
    case audio
    case videoAudio
}

enum WaveformStatus: String, Codable {
    case notGenerated
    case generating
    case ready
    case failed
    case missing
}

enum ProxyStatus: String, Codable {
    case none
    case generating
    case ready
    case failed
    case missing
    case unsupported
}

struct MediaAsset: Codable, Identifiable {
    var id: UUID = UUID()
    var displayName: String
    var originalPath: String
    var relativePath: String?
    /// The usable on-disk location resolved for this app session. It is intentionally not persisted so a moved project is resolved again when opened.
    var resolvedPath: String?
    var kind: MediaKind
    var metadata: MediaFileMetadata
    var importedAt: Date?
    /// A lightweight source fingerprint used to detect an in-place replacement before the old trims are rendered.
    var sourceModificationTimestamp: TimeInterval?
    var waveformCacheKey: String?
    var waveformStatus: WaveformStatus = .notGenerated
    var waveformFailureReason: String?
    var proxyPath: String?
    var proxyCacheKey: String?
    var proxyStatus: ProxyStatus = .none
    var proxyFailureReason: String?
    var isMissing: Bool = false

    var resolvedURL: URL? {
        URL(fileURLWithPath: resolvedPath ?? originalPath)
    }

    var audioSourceURL: URL? {
        if kind == .videoAudio {
            guard proxyStatus == .ready, let proxyPath = proxyPath else { return nil }
            return URL(fileURLWithPath: proxyPath)
        }
        return resolvedURL
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case originalPath
        case relativePath
        case kind
        case metadata
        case importedAt
        case sourceModificationTimestamp
        case waveformCacheKey
        case waveformStatus
        case waveformFailureReason
        case proxyPath
        case proxyCacheKey
        case proxyStatus
        case proxyFailureReason
        case isMissing
    }

    init(id: UUID = UUID(), displayName: String, originalPath: String, relativePath: String?, resolvedPath: String? = nil, kind: MediaKind, metadata: MediaFileMetadata, importedAt: Date? = Date(), sourceModificationTimestamp: TimeInterval? = nil, waveformCacheKey: String?, waveformStatus: WaveformStatus = .notGenerated, waveformFailureReason: String? = nil, proxyPath: String? = nil, proxyCacheKey: String? = nil, proxyStatus: ProxyStatus = .none, proxyFailureReason: String? = nil, isMissing: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.originalPath = originalPath
        self.relativePath = relativePath
        self.resolvedPath = resolvedPath
        self.kind = kind
        self.metadata = metadata
        self.importedAt = importedAt
        self.sourceModificationTimestamp = sourceModificationTimestamp
        self.waveformCacheKey = waveformCacheKey
        self.waveformStatus = waveformStatus
        self.waveformFailureReason = waveformFailureReason
        self.proxyPath = proxyPath
        self.proxyCacheKey = proxyCacheKey
        self.proxyStatus = proxyStatus
        self.proxyFailureReason = proxyFailureReason
        self.isMissing = isMissing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        originalPath = try container.decode(String.self, forKey: .originalPath)
        relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath)
        resolvedPath = nil
        kind = try container.decode(MediaKind.self, forKey: .kind)
        metadata = try container.decode(MediaFileMetadata.self, forKey: .metadata)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? URL(fileURLWithPath: originalPath).deletingPathExtension().lastPathComponent
        importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt)
        sourceModificationTimestamp = try container.decodeIfPresent(TimeInterval.self, forKey: .sourceModificationTimestamp)
        waveformCacheKey = try container.decodeIfPresent(String.self, forKey: .waveformCacheKey)
        waveformStatus = try container.decodeIfPresent(WaveformStatus.self, forKey: .waveformStatus) ?? .notGenerated
        waveformFailureReason = try container.decodeIfPresent(String.self, forKey: .waveformFailureReason)
        proxyPath = try container.decodeIfPresent(String.self, forKey: .proxyPath)
        proxyCacheKey = try container.decodeIfPresent(String.self, forKey: .proxyCacheKey)
        proxyStatus = try container.decodeIfPresent(ProxyStatus.self, forKey: .proxyStatus) ?? (kind == .videoAudio ? .missing : .none)
        proxyFailureReason = try container.decodeIfPresent(String.self, forKey: .proxyFailureReason)
        isMissing = try container.decodeIfPresent(Bool.self, forKey: .isMissing) ?? false
        if isMissing {
            waveformStatus = .missing
            if kind == .videoAudio {
                proxyStatus = .missing
            }
        }
    }
}

struct MediaFileMetadata: Codable {
    var fileName: String
    var fileSize: Int64?
    var duration: TimeInterval
    var sampleRate: Double
    var channelCount: Int
    var checksum: String?
}
