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

    static func parsedTimeRange(start: String, end: String, projectDuration: Double) -> ExportRange? {
        guard let a = NumericInput.number(start), let b = NumericInput.number(end),
              projectDuration.isFinite, a >= 0, b > a, b <= projectDuration + 0.0001 else { return nil }
        return .timeRange(start: a, end: b)
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
    static let mp3SupportedSampleRates: [Double] = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]

    var format: ExportFormat
    var sampleRate: Double
    var channelCount: Int
    var bitrate: Int?
    var outputURL: URL
    var range: ExportRange
    /// Output replacement must be explicitly approved by the caller.
    var overwriteExisting: Bool

    init(
        format: ExportFormat,
        sampleRate: Double,
        channelCount: Int,
        bitrate: Int?,
        outputURL: URL,
        range: ExportRange = .entireProject,
        overwriteExisting: Bool = false
    ) {
        self.format = format
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitrate = bitrate
        self.outputURL = outputURL
        self.range = range
        self.overwriteExisting = overwriteExisting
    }

    enum CodingKeys: String, CodingKey {
        case format
        case sampleRate
        case channelCount
        case bitrate
        case outputURL
        case range
        case overwriteExisting
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(ExportFormat.self, forKey: .format)
        sampleRate = try container.decode(Double.self, forKey: .sampleRate)
        channelCount = try container.decode(Int.self, forKey: .channelCount)
        bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate)
        outputURL = try container.decode(URL.self, forKey: .outputURL)
        range = try container.decodeIfPresent(ExportRange.self, forKey: .range) ?? .entireProject
        overwriteExisting = try container.decodeIfPresent(Bool.self, forKey: .overwriteExisting) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(sampleRate, forKey: .sampleRate)
        try container.encode(channelCount, forKey: .channelCount)
        try container.encodeIfPresent(bitrate, forKey: .bitrate)
        try container.encode(outputURL, forKey: .outputURL)
        try container.encode(range, forKey: .range)
        try container.encode(overwriteExisting, forKey: .overwriteExisting)
    }

    func validate() throws {
        guard sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 384_000 else {
            throw ExportSettingsValidationError(L10n.tr("Choose a valid output sample rate."))
        }
        guard Self.supports(sampleRate: sampleRate, for: format) else {
            throw ExportSettingsValidationError(L10n.tr("MP3 export supports 8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, or 48000 Hz. Choose a compatible sample rate."))
        }
        guard (1...2).contains(channelCount) else {
            throw ExportSettingsValidationError(L10n.tr("Choose mono or stereo output."))
        }
        guard outputURL.isFileURL,
              !outputURL.path.isEmpty,
              !outputURL.hasDirectoryPath else {
            throw ExportSettingsValidationError(L10n.tr("Choose a valid output file."))
        }
        if let bitrate {
            guard (8...512).contains(bitrate) else {
                throw ExportSettingsValidationError(L10n.tr("Choose a valid audio bitrate."))
            }
        }
        if case .timeRange(let start, let end) = range {
            guard start.isFinite, end.isFinite, start >= 0, end > start else {
                throw ExportSettingsValidationError(L10n.tr("The selected export range is invalid."))
            }
        }
    }

    static func supports(sampleRate: Double, for format: ExportFormat) -> Bool {
        guard sampleRate.isFinite else { return false }
        guard format == .mp3 else { return true }
        return mp3SupportedSampleRates.contains { abs($0 - sampleRate) < 0.5 }
    }
}

private struct ExportSettingsValidationError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
