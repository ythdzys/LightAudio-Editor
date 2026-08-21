import Foundation

struct Timeline: Codable {
    var tracks: [Track]
    var markers: [TimelineMarker] = []
    var crossfades: [Crossfade] = []

    enum CodingKeys: String, CodingKey {
        case tracks
        case markers
        case crossfades
    }

    init(tracks: [Track], markers: [TimelineMarker] = [], crossfades: [Crossfade] = []) {
        self.tracks = tracks
        self.markers = markers
        self.crossfades = crossfades
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tracks = try container.decode([Track].self, forKey: .tracks)
        markers = try container.decodeIfPresent([TimelineMarker].self, forKey: .markers) ?? []
        crossfades = try container.decodeIfPresent([Crossfade].self, forKey: .crossfades) ?? []
    }
}

struct TimelineMarker: Codable, Identifiable {
    var id: UUID = UUID()
    var time: TimeInterval
    var name: String
    var color: String? = nil
}

enum CrossfadeCurve: String, Codable, CaseIterable {
    case linear
    case equalPower

    var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .equalPower: return "Equal Power"
        }
    }
}

struct Crossfade: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var leadingClipID: UUID
    var trailingClipID: UUID
    var startTime: TimeInterval
    var duration: TimeInterval
    var curve: CrossfadeCurve = .equalPower

    init(id: UUID = UUID(), leadingClipID: UUID, trailingClipID: UUID, startTime: TimeInterval, duration: TimeInterval, curve: CrossfadeCurve = .equalPower) {
        self.id = id
        self.leadingClipID = leadingClipID
        self.trailingClipID = trailingClipID
        self.startTime = max(0, startTime)
        self.duration = max(0, duration)
        self.curve = curve
    }

    func contains(clipID: UUID, timelineTime: TimeInterval) -> Bool {
        (clipID == leadingClipID || clipID == trailingClipID) &&
            timelineTime >= startTime &&
            timelineTime <= startTime + duration
    }
}

struct Track: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var isMuted: Bool = false
    var isSolo: Bool = false
    var isLocked: Bool = false
    var volumeDB: Double = 0
    var pan: Double = 0
    var isCollapsed: Bool = false
    var volumeAutomationKeyframes: [TrackVolumeAutomationKeyframe] = []
    var clips: [Clip] = []

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case isMuted
        case isSolo
        case isLocked
        case volumeDB
        case pan
        case isCollapsed
        case volumeAutomationKeyframes
        case clips
    }

    init(id: UUID = UUID(), name: String, isMuted: Bool = false, isSolo: Bool = false, isLocked: Bool = false, volumeDB: Double = 0, pan: Double = 0, isCollapsed: Bool = false, volumeAutomationKeyframes: [TrackVolumeAutomationKeyframe] = [], clips: [Clip] = []) {
        self.id = id
        self.name = name
        self.isMuted = isMuted
        self.isSolo = isSolo
        self.isLocked = isLocked
        self.volumeDB = MixMath.clampTrackVolumeDB(volumeDB)
        self.pan = MixMath.clampPan(pan)
        self.isCollapsed = isCollapsed
        self.volumeAutomationKeyframes = volumeAutomationKeyframes.map { $0.clamped() }.sorted { $0.time < $1.time }
        self.clips = clips
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isSolo = try container.decodeIfPresent(Bool.self, forKey: .isSolo) ?? false
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        volumeDB = MixMath.clampTrackVolumeDB(try container.decodeIfPresent(Double.self, forKey: .volumeDB) ?? 0)
        pan = MixMath.clampPan(try container.decodeIfPresent(Double.self, forKey: .pan) ?? 0)
        isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        volumeAutomationKeyframes = (try container.decodeIfPresent([TrackVolumeAutomationKeyframe].self, forKey: .volumeAutomationKeyframes) ?? []).map { $0.clamped() }.sorted { $0.time < $1.time }
        clips = try container.decodeIfPresent([Clip].self, forKey: .clips) ?? []
    }
}

struct ClipVolumeAutomationKeyframe: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var time: TimeInterval
    var gainDB: Double

    func clamped(maxTime: TimeInterval) -> ClipVolumeAutomationKeyframe {
        ClipVolumeAutomationKeyframe(id: id, time: min(max(0, time), max(0, maxTime)), gainDB: MixMath.clampClipAutomationDB(gainDB))
    }
}

struct ClipPanAutomationKeyframe: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var time: TimeInterval
    var pan: Double

    func clamped(maxTime: TimeInterval) -> ClipPanAutomationKeyframe {
        ClipPanAutomationKeyframe(id: id, time: min(max(0, time), max(0, maxTime)), pan: MixMath.clampPanPercent(pan))
    }
}

struct TrackVolumeAutomationKeyframe: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var time: TimeInterval
    var gainDB: Double

    func clamped() -> TrackVolumeAutomationKeyframe {
        TrackVolumeAutomationKeyframe(id: id, time: max(0, time), gainDB: MixMath.clampTrackVolumeDB(gainDB))
    }
}

enum AudioEffectType: String, Codable, CaseIterable {
    case normalizeAnalysis
    case threeBandEQ
}

struct AudioEffectParameter: Codable, Equatable {
    var key: String
    var value: Double
}

struct AudioEffect: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var type: AudioEffectType
    var isEnabled: Bool = true
    var parameters: [AudioEffectParameter] = []
}

struct Clip: Codable, Identifiable {
    var id: UUID = UUID()
    var sourceAssetID: UUID
    var customName: String?
    var colorLabel: ClipColorLabel = .default
    var timelineStart: TimeInterval
    var sourceStart: TimeInterval
    var sourceEnd: TimeInterval
    var gain: Double = 1.0
    var pan: Double = 0.0
    var fadeIn: Fade = Fade()
    var fadeOut: Fade = Fade()
    var volumeAutomationKeyframes: [ClipVolumeAutomationKeyframe] = []
    var panAutomationKeyframes: [ClipPanAutomationKeyframe] = []
    var effects: [AudioEffect] = []
    var isSelected: Bool = false

    var duration: TimeInterval {
        max(0, sourceEnd - sourceStart)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sourceAssetID
        case customName
        case colorLabel
        case timelineStart
        case sourceStart
        case sourceEnd
        case gain
        case pan
        case fadeIn
        case fadeOut
        case volumeAutomationKeyframes
        case panAutomationKeyframes
        case effects
        case isSelected
    }

    init(id: UUID = UUID(), sourceAssetID: UUID, customName: String? = nil, colorLabel: ClipColorLabel = .default, timelineStart: TimeInterval, sourceStart: TimeInterval, sourceEnd: TimeInterval, gain: Double = 1.0, pan: Double = 0.0, fadeIn: Fade = Fade(), fadeOut: Fade = Fade(), volumeAutomationKeyframes: [ClipVolumeAutomationKeyframe] = [], panAutomationKeyframes: [ClipPanAutomationKeyframe] = [], effects: [AudioEffect] = [], isSelected: Bool = false) {
        self.id = id
        self.sourceAssetID = sourceAssetID
        self.customName = customName
        self.colorLabel = colorLabel
        self.timelineStart = timelineStart
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.gain = gain
        self.pan = pan
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.volumeAutomationKeyframes = volumeAutomationKeyframes.map { $0.clamped(maxTime: max(0, sourceEnd - sourceStart)) }.sorted { $0.time < $1.time }
        self.panAutomationKeyframes = panAutomationKeyframes.map { $0.clamped(maxTime: max(0, sourceEnd - sourceStart)) }.sorted { $0.time < $1.time }
        self.effects = effects
        self.isSelected = isSelected
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sourceAssetID = try container.decode(UUID.self, forKey: .sourceAssetID)
        customName = try container.decodeIfPresent(String.self, forKey: .customName)
        colorLabel = try container.decodeIfPresent(ClipColorLabel.self, forKey: .colorLabel) ?? .default
        timelineStart = try container.decodeIfPresent(TimeInterval.self, forKey: .timelineStart) ?? 0
        sourceStart = try container.decodeIfPresent(TimeInterval.self, forKey: .sourceStart) ?? 0
        sourceEnd = try container.decodeIfPresent(TimeInterval.self, forKey: .sourceEnd) ?? sourceStart
        gain = try container.decodeIfPresent(Double.self, forKey: .gain) ?? 1.0
        pan = try container.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        fadeIn = try container.decodeIfPresent(Fade.self, forKey: .fadeIn) ?? Fade()
        fadeOut = try container.decodeIfPresent(Fade.self, forKey: .fadeOut) ?? Fade()
        volumeAutomationKeyframes = (try container.decodeIfPresent([ClipVolumeAutomationKeyframe].self, forKey: .volumeAutomationKeyframes) ?? []).map { $0.clamped(maxTime: max(0, sourceEnd - sourceStart)) }.sorted { $0.time < $1.time }
        panAutomationKeyframes = (try container.decodeIfPresent([ClipPanAutomationKeyframe].self, forKey: .panAutomationKeyframes) ?? []).map { $0.clamped(maxTime: max(0, sourceEnd - sourceStart)) }.sorted { $0.time < $1.time }
        effects = try container.decodeIfPresent([AudioEffect].self, forKey: .effects) ?? []
        isSelected = try container.decodeIfPresent(Bool.self, forKey: .isSelected) ?? false
    }
}

enum ClipColorLabel: String, Codable, CaseIterable {
    case `default`
    case blue
    case green
    case purple
    case orange
    case red
    case gray

    var displayName: String {
        switch self {
        case .default: return "Default"
        case .blue: return "Blue"
        case .green: return "Green"
        case .purple: return "Purple"
        case .orange: return "Orange"
        case .red: return "Red"
        case .gray: return "Gray"
        }
    }
}

enum FadeCurve: String, Codable, CaseIterable {
    case linear
    case equalPower
    case easeIn
    case easeOut

    var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .equalPower: return "Equal Power"
        case .easeIn: return "Ease In"
        case .easeOut: return "Ease Out"
        }
    }
}

struct Fade: Codable {
    var duration: TimeInterval = 0
    var curve: FadeCurve = .linear

    enum CodingKeys: String, CodingKey {
        case duration
        case curve
    }

    init(duration: TimeInterval = 0, curve: FadeCurve = .linear) {
        self.duration = max(0, duration)
        self.curve = curve
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        duration = max(0, try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0)
        curve = try container.decodeIfPresent(FadeCurve.self, forKey: .curve) ?? .linear
    }
}

enum TimelineTool {
    case selection
    case razor
}

enum MixMath {
    static func linearGain(forDB db: Double) -> Double {
        if db <= -60 { return 0 }
        return pow(10, db / 20)
    }

    static func db(forLinearGain gain: Double) -> Double {
        guard gain > 0.000001 else { return -60 }
        return min(12, max(-60, 20 * log10(gain)))
    }

    static func clampClipGainLinear(_ gain: Double) -> Double {
        min(linearGain(forDB: 12), max(0, gain))
    }

    static func clampClipAutomationDB(_ db: Double) -> Double {
        min(12, max(-60, db))
    }

    static func clampTrackVolumeDB(_ db: Double) -> Double {
        min(12, max(-60, db))
    }

    static func clampMasterVolumeDB(_ db: Double) -> Double {
        min(6, max(-60, db))
    }

    static func clampPan(_ pan: Double) -> Double {
        min(1, max(-1, pan))
    }

    static func clampPanPercent(_ pan: Double) -> Double {
        min(100, max(-100, pan))
    }

    static func combinedPan(_ clipPan: Double, _ trackPan: Double) -> Double {
        clampPan(clipPan + trackPan)
    }
}

enum AudioPeakMath {
    /// Ignore sub-sample floating-point noise around 0 dBFS while still reporting real overs.
    static let clippingThreshold = 1.0001

    static func isClipping(peak: Double) -> Bool {
        peak.isFinite && peak > clippingThreshold
    }
}

enum AutomationMath {
    // Clip automation times are intentionally relative to the visible, trimmed clip.
    // Trimming clamps out-of-range keyframes, while moving a clip requires no keyframe edits.
    static func volumeAutomationGain(for clip: Clip, atClipTime time: TimeInterval) -> Double {
        MixMath.linearGain(forDB: volumeAutomationDB(for: clip, atClipTime: time))
    }

    static func volumeAutomationDB(for clip: Clip, atClipTime time: TimeInterval) -> Double {
        interpolatedDB(keyframes: clip.volumeAutomationKeyframes, time: time, defaultDB: 0)
    }

    static func panAutomation(for clip: Clip, atClipTime time: TimeInterval) -> Double {
        interpolatedPan(keyframes: clip.panAutomationKeyframes, time: time, defaultPan: 0)
    }

    static func trackVolumeAutomationGain(for track: Track, atTimelineTime time: TimeInterval) -> Double {
        MixMath.linearGain(forDB: trackVolumeAutomationDB(for: track, atTimelineTime: time))
    }

    static func trackVolumeAutomationDB(for track: Track, atTimelineTime time: TimeInterval) -> Double {
        interpolatedDB(keyframes: track.volumeAutomationKeyframes, time: time, defaultDB: 0)
    }

    private static func interpolatedDB(keyframes: [ClipVolumeAutomationKeyframe], time: TimeInterval, defaultDB: Double) -> Double {
        guard let first = keyframes.first else { return defaultDB }
        guard keyframes.count > 1 else { return first.gainDB }
        let clampedTime = max(0, time)
        if clampedTime <= first.time { return first.gainDB }
        if let last = keyframes.last, clampedTime >= last.time { return last.gainDB }
        let indexes = surroundingIndexes(in: keyframes, time: clampedTime) { $0.time }
        let left = keyframes[indexes.left]
        let right = keyframes[indexes.right]
        let span = max(0.000001, right.time - left.time)
        let fraction = (clampedTime - left.time) / span
        return left.gainDB + (right.gainDB - left.gainDB) * fraction
    }

    private static func interpolatedDB(keyframes: [TrackVolumeAutomationKeyframe], time: TimeInterval, defaultDB: Double) -> Double {
        guard let first = keyframes.first else { return defaultDB }
        guard keyframes.count > 1 else { return first.gainDB }
        let clampedTime = max(0, time)
        if clampedTime <= first.time { return first.gainDB }
        if let last = keyframes.last, clampedTime >= last.time { return last.gainDB }
        let indexes = surroundingIndexes(in: keyframes, time: clampedTime) { $0.time }
        let left = keyframes[indexes.left]
        let right = keyframes[indexes.right]
        let span = max(0.000001, right.time - left.time)
        let fraction = (clampedTime - left.time) / span
        return left.gainDB + (right.gainDB - left.gainDB) * fraction
    }

    private static func interpolatedPan(keyframes: [ClipPanAutomationKeyframe], time: TimeInterval, defaultPan: Double) -> Double {
        guard let first = keyframes.first else { return MixMath.clampPanPercent(defaultPan) }
        guard keyframes.count > 1 else { return MixMath.clampPanPercent(first.pan) }
        let clampedTime = max(0, time)
        if clampedTime <= first.time { return MixMath.clampPanPercent(first.pan) }
        if let last = keyframes.last, clampedTime >= last.time { return MixMath.clampPanPercent(last.pan) }
        let indexes = surroundingIndexes(in: keyframes, time: clampedTime) { $0.time }
        let left = keyframes[indexes.left]
        let right = keyframes[indexes.right]
        let span = max(0.000001, right.time - left.time)
        let fraction = (clampedTime - left.time) / span
        return MixMath.clampPanPercent(left.pan + (right.pan - left.pan) * fraction)
    }

    /// Keyframes are maintained in sorted order. Binary search avoids re-walking an entire
    /// envelope for every rendered audio sample.
    private static func surroundingIndexes<T>(
        in keyframes: [T],
        time: TimeInterval,
        keyframeTime: (T) -> TimeInterval
    ) -> (left: Int, right: Int) {
        var left = 0
        var right = keyframes.count - 1
        while left + 1 < right {
            let middle = (left + right) / 2
            if keyframeTime(keyframes[middle]) <= time {
                left = middle
            } else {
                right = middle
            }
        }
        return (left, right)
    }
}

enum FadeMath {
    static func edgeFadeGain(for clip: Clip, timelineTime: TimeInterval) -> Double {
        var value = 1.0
        let fadeIn = min(max(0, clip.fadeIn.duration), clip.duration)
        let fadeOut = min(max(0, clip.fadeOut.duration), clip.duration)
        if fadeIn > 0 {
            let progress = min(1, max(0, (timelineTime - clip.timelineStart) / fadeIn))
            value = min(value, curveGain(progress: progress, curve: clip.fadeIn.curve))
        }
        if fadeOut > 0 {
            let remaining = clip.timelineStart + clip.duration - timelineTime
            let progress = min(1, max(0, remaining / fadeOut))
            value = min(value, curveGain(progress: progress, curve: clip.fadeOut.curve))
        }
        return value
    }

    static func crossfadeGain(for clipID: UUID, timelineTime: TimeInterval, timeline: Timeline) -> Double {
        guard let crossfade = timeline.crossfades.first(where: {
            $0.contains(clipID: clipID, timelineTime: timelineTime) && $0.duration > 0
        }) else {
            return 1
        }
        let progress = min(1, max(0, (timelineTime - crossfade.startTime) / crossfade.duration))
        if clipID == crossfade.leadingClipID {
            return crossfadeGain(progress: 1 - progress, curve: crossfade.curve)
        }
        if clipID == crossfade.trailingClipID {
            return crossfadeGain(progress: progress, curve: crossfade.curve)
        }
        return 1
    }

    static func curveGain(progress: Double, curve: FadeCurve) -> Double {
        let t = min(1, max(0, progress))
        switch curve {
        case .linear:
            return t
        case .equalPower:
            return sin(t * Double.pi / 2)
        case .easeIn:
            return t * t
        case .easeOut:
            return 1 - pow(1 - t, 2)
        }
    }

    static func crossfadeGain(progress: Double, curve: CrossfadeCurve) -> Double {
        let t = min(1, max(0, progress))
        switch curve {
        case .linear:
            return t
        case .equalPower:
            return sin(t * Double.pi / 2)
        }
    }
}
