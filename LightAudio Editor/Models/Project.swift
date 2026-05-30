import Foundation

struct Project: Codable {
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

    init(id: UUID = UUID(), name: String, sampleRate: Double, duration: TimeInterval, assets: [MediaAsset], timeline: Timeline, mixState: MixState = MixState(), viewState: TimelineViewState, lastSavedAt: Date?) {
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
    var originalProjectURL: URL?
    var project: Project
    var wasDirty: Bool = true
    var savedProjectModificationDate: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case originalProjectURL
        case project
        case wasDirty
        case savedProjectModificationDate
    }

    init(id: UUID = UUID(), createdAt: Date, originalProjectURL: URL?, project: Project, wasDirty: Bool = true, savedProjectModificationDate: Date? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.originalProjectURL = originalProjectURL
        self.project = project
        self.wasDirty = wasDirty
        self.savedProjectModificationDate = savedProjectModificationDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        originalProjectURL = try container.decodeIfPresent(URL.self, forKey: .originalProjectURL)
        project = try container.decode(Project.self, forKey: .project)
        wasDirty = try container.decodeIfPresent(Bool.self, forKey: .wasDirty) ?? true
        savedProjectModificationDate = try container.decodeIfPresent(Date.self, forKey: .savedProjectModificationDate)
    }
}

struct TimelineViewState: Codable {
    static let defaultTrackHeight: Double = 86
    static let minimumTrackHeight: Double = 72
    static let maximumTrackHeight: Double = 150

    var zoom: Double = 80
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
        zoom: Double = 80,
        horizontalScroll: Double = 0,
        snappingEnabled: Bool = true,
        followPlayhead: Bool = false,
        inPoint: TimeInterval? = nil,
        outPoint: TimeInterval? = nil,
        loopRangeEnabled: Bool = false,
        trackHeight: Double = TimelineViewState.defaultTrackHeight
    ) {
        self.zoom = zoom
        self.horizontalScroll = horizontalScroll
        self.snappingEnabled = snappingEnabled
        self.followPlayhead = followPlayhead
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.loopRangeEnabled = loopRangeEnabled
        self.trackHeight = TimelineViewState.clampedTrackHeight(trackHeight)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        zoom = try container.decodeIfPresent(Double.self, forKey: .zoom) ?? 80
        horizontalScroll = try container.decodeIfPresent(Double.self, forKey: .horizontalScroll) ?? 0
        snappingEnabled = try container.decodeIfPresent(Bool.self, forKey: .snappingEnabled) ?? true
        followPlayhead = try container.decodeIfPresent(Bool.self, forKey: .followPlayhead) ?? false
        inPoint = try container.decodeIfPresent(TimeInterval.self, forKey: .inPoint)
        outPoint = try container.decodeIfPresent(TimeInterval.self, forKey: .outPoint)
        loopRangeEnabled = try container.decodeIfPresent(Bool.self, forKey: .loopRangeEnabled) ?? false
        trackHeight = TimelineViewState.clampedTrackHeight(try container.decodeIfPresent(Double.self, forKey: .trackHeight) ?? TimelineViewState.defaultTrackHeight)
    }

    static func clampedTrackHeight(_ value: Double) -> Double {
        min(maximumTrackHeight, max(minimumTrackHeight, value))
    }

    var validRange: (start: TimeInterval, end: TimeInterval)? {
        guard let start = inPoint, let end = outPoint, end > start else { return nil }
        return (start, end)
    }
}
