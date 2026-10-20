import Foundation

struct Project: Codable {
    static let currentFormatVersion = 3
    static let minimumSupportedFormatVersion = 1

    var formatVersion: Int
    var id: UUID = UUID()
    var name: String
    var sampleRate: Double
    var duration: TimeInterval
    var assets: [MediaAsset]
    var timeline: Timeline
    var mixState: MixState
    var viewState: TimelineViewState
    var lastSavedAt: Date?

    enum CodingKeys: String, CodingKey {
        case formatVersion
        case id
        case name
        case sampleRate
        case duration
        case assets
        case timeline
        case mixState
        case viewState
        case lastSavedAt
    }

    static func empty(name: String = "Untitled") -> Project {
        Project(
            name: name,
            sampleRate: 44100,
            duration: 0,
            assets: [],
            timeline: Timeline(tracks: [Track(name: "A1")]),
            mixState: MixState(),
            viewState: TimelineViewState(),
            lastSavedAt: nil
        )
    }

    init(formatVersion: Int = Project.currentFormatVersion, id: UUID = UUID(), name: String, sampleRate: Double, duration: TimeInterval, assets: [MediaAsset], timeline: Timeline, mixState: MixState = MixState(), viewState: TimelineViewState, lastSavedAt: Date?) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.sampleRate = sampleRate
        self.duration = duration
        self.assets = assets
        self.timeline = timeline
        self.mixState = mixState
        self.viewState = viewState
        self.lastSavedAt = lastSavedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Projects written before Beta 1 had no explicit schema marker. Their structure is the
        // version 1 schema, so treating a missing value as 1 preserves those existing files.
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        sampleRate = try container.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 44100
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        assets = try container.decodeIfPresent([MediaAsset].self, forKey: .assets) ?? []
        timeline = try container.decode(Timeline.self, forKey: .timeline)
        mixState = try container.decodeIfPresent(MixState.self, forKey: .mixState) ?? MixState()
        viewState = try container.decodeIfPresent(TimelineViewState.self, forKey: .viewState) ?? TimelineViewState()
        lastSavedAt = try container.decodeIfPresent(Date.self, forKey: .lastSavedAt)
    }

    mutating func recalculateDuration() {
        duration = timeline.tracks.flatMap { $0.clips }.map { $0.timelineStart + $0.duration }.max() ?? 0
    }

    func asset(id: UUID) -> MediaAsset? {
        assets.first { $0.id == id }
    }

    var missingAssets: [MediaAsset] {
        assets.filter { $0.isMissing }
    }

    /// Older readers must reject partial fades instead of silently changing their sound.
    var requiredFormatVersion: Int {
        if timeline.crossfades.contains(where: \.isPartial) { return 3 }
        return timeline.tracks.flatMap(\.clips).contains { $0.fadeIn.isPartial || $0.fadeOut.isPartial } ? 2 : 1
    }

    var hasMissingAssets: Bool {
        !missingAssets.isEmpty
    }
}

struct MixState: Codable {
    var masterVolumeDB: Double = 0

    enum CodingKeys: String, CodingKey {
        case masterVolumeDB
    }

    init(masterVolumeDB: Double = 0) {
        self.masterVolumeDB = MixMath.clampMasterVolumeDB(masterVolumeDB)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        masterVolumeDB = MixMath.clampMasterVolumeDB(try container.decodeIfPresent(Double.self, forKey: .masterVolumeDB) ?? 0)
    }
}

struct ProjectRecoverySnapshot: Codable {
    var id: UUID = UUID()
    var createdAt: Date
    var sessionID: UUID?
    var originalProjectURL: URL?
    var project: Project
    var wasDirty: Bool = true
    var savedProjectModificationDate: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case sessionID
        case originalProjectURL
        case project
        case wasDirty
        case savedProjectModificationDate
    }

    init(id: UUID = UUID(), createdAt: Date, sessionID: UUID? = nil, originalProjectURL: URL?, project: Project, wasDirty: Bool = true, savedProjectModificationDate: Date? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.sessionID = sessionID
        self.originalProjectURL = originalProjectURL
        self.project = project
        self.wasDirty = wasDirty
        self.savedProjectModificationDate = savedProjectModificationDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
        originalProjectURL = try container.decodeIfPresent(URL.self, forKey: .originalProjectURL)
        project = try container.decode(Project.self, forKey: .project)
        wasDirty = try container.decodeIfPresent(Bool.self, forKey: .wasDirty) ?? true
        savedProjectModificationDate = try container.decodeIfPresent(Date.self, forKey: .savedProjectModificationDate)
    }
}

struct TimelineViewState: Codable {
    static let defaultZoom: Double = 80
    static let minimumZoom: Double = 0.02
    static let maximumZoom: Double = 2400
    static let maximumHorizontalScroll: Double = 8_000_000
    static let maximumTimelineTime: TimeInterval = 8_000_000
    static let defaultTrackHeight: Double = 86
    static let minimumTrackHeight: Double = 72
    static let maximumTrackHeight: Double = 150

    var zoom: Double = TimelineViewState.defaultZoom
    var horizontalScroll: Double = 0
    var snappingEnabled: Bool = true
    var followPlayhead: Bool = false
    var inPoint: TimeInterval?
    var outPoint: TimeInterval?
    var loopRangeEnabled: Bool = false
    var trackHeight: Double = TimelineViewState.defaultTrackHeight

    enum CodingKeys: String, CodingKey {
        case zoom
        case horizontalScroll
        case snappingEnabled
        case followPlayhead
        case inPoint
        case outPoint
        case loopRangeEnabled
        case trackHeight
    }

    init(
        zoom: Double = TimelineViewState.defaultZoom,
        horizontalScroll: Double = 0,
        snappingEnabled: Bool = true,
        followPlayhead: Bool = false,
        inPoint: TimeInterval? = nil,
        outPoint: TimeInterval? = nil,
        loopRangeEnabled: Bool = false,
        trackHeight: Double = TimelineViewState.defaultTrackHeight
    ) {
        self.zoom = TimelineViewState.clampedZoom(zoom)
        self.horizontalScroll = TimelineViewState.clampedHorizontalScroll(horizontalScroll)
        self.snappingEnabled = snappingEnabled
        self.followPlayhead = followPlayhead
        self.inPoint = TimelineViewState.clampedTimelineTime(inPoint)
        self.outPoint = TimelineViewState.clampedTimelineTime(outPoint)
        self.loopRangeEnabled = loopRangeEnabled
        self.trackHeight = TimelineViewState.clampedTrackHeight(trackHeight)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        zoom = TimelineViewState.clampedZoom(try container.decodeIfPresent(Double.self, forKey: .zoom) ?? TimelineViewState.defaultZoom)
        horizontalScroll = TimelineViewState.clampedHorizontalScroll(try container.decodeIfPresent(Double.self, forKey: .horizontalScroll) ?? 0)
        snappingEnabled = try container.decodeIfPresent(Bool.self, forKey: .snappingEnabled) ?? true
        followPlayhead = try container.decodeIfPresent(Bool.self, forKey: .followPlayhead) ?? false
        inPoint = TimelineViewState.clampedTimelineTime(try container.decodeIfPresent(TimeInterval.self, forKey: .inPoint))
        outPoint = TimelineViewState.clampedTimelineTime(try container.decodeIfPresent(TimeInterval.self, forKey: .outPoint))
        loopRangeEnabled = try container.decodeIfPresent(Bool.self, forKey: .loopRangeEnabled) ?? false
        trackHeight = TimelineViewState.clampedTrackHeight(try container.decodeIfPresent(Double.self, forKey: .trackHeight) ?? TimelineViewState.defaultTrackHeight)
    }

    static func clampedTrackHeight(_ value: Double) -> Double {
        guard value.isFinite else { return defaultTrackHeight }
        return min(maximumTrackHeight, max(minimumTrackHeight, value))
    }

    static func clampedZoom(_ value: Double) -> Double {
        guard value.isFinite else { return defaultZoom }
        return min(maximumZoom, max(minimumZoom, value))
    }

    static func clampedHorizontalScroll(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(maximumHorizontalScroll, max(0, value))
    }

    static func isValidTimelineTime(_ value: TimeInterval) -> Bool {
        value.isFinite && value >= 0 && value <= maximumTimelineTime
    }

    static func clampedTimelineTime(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite else { return nil }
        return min(maximumTimelineTime, max(0, value))
    }

    var validRange: (start: TimeInterval, end: TimeInterval)? {
        guard let start = inPoint, let end = outPoint, end > start else { return nil }
        return (start, end)
    }
}
