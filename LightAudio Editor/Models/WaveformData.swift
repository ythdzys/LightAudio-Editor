import Foundation

struct WaveformPeak: Codable {
    var min: Float
    var max: Float
}

struct WaveformData: Codable {
    static let currentCacheFormatVersion = 3

    var cacheKey: String
    var cacheFormatVersion: Int = WaveformData.currentCacheFormatVersion
    var duration: TimeInterval
    var sampleRate: Double
    var channelCount: Int
    var peaks: [WaveformPeak]
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case cacheKey
        case cacheFormatVersion
        case duration
        case sampleRate
        case channelCount
        case peaks
        case createdAt
    }

    init(cacheKey: String, cacheFormatVersion: Int = WaveformData.currentCacheFormatVersion, duration: TimeInterval, sampleRate: Double, channelCount: Int, peaks: [WaveformPeak], createdAt: Date) {
        self.cacheKey = cacheKey
        self.cacheFormatVersion = cacheFormatVersion
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.peaks = peaks
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cacheKey = try container.decode(String.self, forKey: .cacheKey)
        cacheFormatVersion = try container.decodeIfPresent(Int.self, forKey: .cacheFormatVersion) ?? 1
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        sampleRate = try container.decode(Double.self, forKey: .sampleRate)
        channelCount = try container.decode(Int.self, forKey: .channelCount)
        peaks = try container.decode([WaveformPeak].self, forKey: .peaks)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}
