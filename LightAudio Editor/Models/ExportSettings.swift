import Foundation

enum ExportFormat: String, Codable, CaseIterable {
    case wav = "WAV"
    case m4a = "M4A"
    case aiff = "AIFF"
    case mp3 = "MP3"
    case flac = "FLAC"
}

enum ExportRange: Codable, Equatable {
    case entireProject
    case timeRange(start: TimeInterval, end: TimeInterval)

    private enum CodingKeys: String, CodingKey {
        case type
        case start
        case end
    }

    private enum RangeType: String, Codable {
        case entireProject
        case timeRange
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(RangeType.self, forKey: .type) ?? .entireProject
        switch type {
        case .entireProject:
            self = .entireProject
        case .timeRange:
            let start = try container.decodeIfPresent(TimeInterval.self, forKey: .start) ?? 0
            let end = try container.decodeIfPresent(TimeInterval.self, forKey: .end) ?? start
            self = .timeRange(start: min(start, end), end: max(start, end))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .entireProject:
            try container.encode(RangeType.entireProject, forKey: .type)
        case .timeRange(let start, let end):
            try container.encode(RangeType.timeRange, forKey: .type)
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
        }
    }

    var start: TimeInterval? {
        if case .timeRange(let start, _) = self { return start }
        return nil
    }

    var end: TimeInterval? {
        if case .timeRange(_, let end) = self { return end }
        return nil
    }
}

struct ExportSettings: Codable {
    var format: ExportFormat
    var sampleRate: Double
    var channelCount: Int
    var bitrate: Int?
    var outputURL: URL
    var range: ExportRange

    init(format: ExportFormat, sampleRate: Double, channelCount: Int, bitrate: Int?, outputURL: URL, range: ExportRange = .entireProject) {
        self.format = format
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitrate = bitrate
        self.outputURL = outputURL
        self.range = range
    }
}
