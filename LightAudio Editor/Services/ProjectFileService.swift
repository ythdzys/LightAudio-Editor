import Foundation
import os

final class ProjectFileService {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let resolver = FileReferenceResolver()

    init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    @discardableResult
    func save(_ project: Project, to url: URL) throws -> Project {
        let trace = OSSignpostID(log: MediaPreparationScheduler.log)
        os_signpost(.begin, log: MediaPreparationScheduler.log, name: "Project save", signpostID: trace)
        defer { os_signpost(.end, log: MediaPreparationScheduler.log, name: "Project save", signpostID: trace) }
        var copy = project
        try validateStructure(of: &copy)
        copy.lastSavedAt = Date()
        let data = try encoder.encode(copy)
        try data.write(to: url, options: .atomic)
        return copy
    }

    func load(from url: URL, deferUncachedChecks: Bool = false, cancellation: ExportCancellationToken? = nil) throws -> (Project, [MediaAsset]) {
        let trace = OSSignpostID(log: MediaPreparationScheduler.log)
        os_signpost(.begin, log: MediaPreparationScheduler.log, name: "Project open", signpostID: trace)
        defer { os_signpost(.end, log: MediaPreparationScheduler.log, name: "Project open", signpostID: trace) }
        if cancellation?.isCancelled == true { throw CocoaError(.userCancelled) }
        let data = try Data(contentsOf: url)
        var project = try decoder.decode(Project.self, from: data)
        let missing = try prepareForOpening(&project, projectURL: url, deferUncachedChecks: deferUncachedChecks, cancellation: cancellation)
        return (project, missing)
    }

    /// Validates relationships that Codable cannot express before the timeline is allowed to render.
    /// Declared assets with missing files remain valid and are handled by the relink flow below.
    func prepareForOpening(_ project: inout Project, projectURL: URL?, deferUncachedChecks: Bool = false,
                           cancellation: ExportCancellationToken? = nil) throws -> [MediaAsset] {
        if cancellation?.isCancelled == true { throw CocoaError(.userCancelled) }
        try validateStructure(of: &project)
        if let cancellation {
            return try resolver.markMissingAssets(in: &project, projectURL: projectURL, deferUncachedChecks: deferUncachedChecks, cancellation: cancellation)
        }
        return resolver.markMissingAssets(in: &project, projectURL: projectURL, deferUncachedChecks: deferUncachedChecks)
    }

    func encodeRecovery(_ snapshot: ProjectRecoverySnapshot, to url: URL) throws {
        let trace = OSSignpostID(log: MediaPreparationScheduler.log)
        os_signpost(.begin, log: MediaPreparationScheduler.log, name: "Recovery write", signpostID: trace)
        defer { os_signpost(.end, log: MediaPreparationScheduler.log, name: "Recovery write", signpostID: trace) }
        // Preserve subsecond timestamps for reliable recovery ordering.
        let recoveryEncoder = JSONEncoder()
        recoveryEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        recoveryEncoder.dateEncodingStrategy = .secondsSince1970
        var copy = snapshot
        try validateStructure(of: &copy.project)
        let data = try recoveryEncoder.encode(copy)
        try data.write(to: url, options: .atomic)
    }

    func decodeRecovery(from url: URL) throws -> ProjectRecoverySnapshot {
        let data = try Data(contentsOf: url)
        let recoveryDecoder = JSONDecoder()
        recoveryDecoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) { return Date(timeIntervalSince1970: seconds) }
            let string = try container.decode(String.self)
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: string) { return date }
            iso.formatOptions.insert(.withFractionalSeconds)
            if let date = iso.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid recovery date")
        }
        return try recoveryDecoder.decode(ProjectRecoverySnapshot.self, from: data)
    }

    /// Content identity shared by dirty tracking and recovery. Ignore save timestamps and
    /// derived presentation/cache state, but retain every persisted editing choice.
    static func editableProjectFingerprint(_ value: Project) -> Data? {
        var copy = value
        copy.lastSavedAt = nil
        copy.viewState.zoom = TimelineViewState.defaultZoom
        copy.viewState.horizontalScroll = 0
        for index in copy.assets.indices {
            copy.assets[index].resolvedPath = nil
            if copy.assets[index].metadata.checksum?.hasPrefix("sha256:") == true {
                // The full digest is the editing identity. A verified timestamp refresh is
                // derived availability state, and must not make Undo or recovery look dirty.
                copy.assets[index].sourceModificationTimestamp = nil
            }
            copy.assets[index].waveformCacheKey = nil
            copy.assets[index].waveformStatus = .notGenerated
            copy.assets[index].waveformFailureReason = nil
            copy.assets[index].proxyPath = nil
            copy.assets[index].proxyCacheKey = nil
            copy.assets[index].proxyStatus = .none
            copy.assets[index].proxyFailureReason = nil
            copy.assets[index].isMissing = false
        }
        for trackIndex in copy.timeline.tracks.indices {
            for clipIndex in copy.timeline.tracks[trackIndex].clips.indices {
                copy.timeline.tracks[trackIndex].clips[clipIndex].isSelected = false
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(copy)
    }

    func savedEditingContentMatches(_ candidate: Project, at url: URL) throws -> Bool {
        var saved = try decoder.decode(Project.self, from: Data(contentsOf: url))
        var candidate = candidate
        try validateStructure(of: &saved)
        try validateStructure(of: &candidate)
        guard let savedContent = Self.editableProjectFingerprint(saved),
              let candidateContent = Self.editableProjectFingerprint(candidate) else { return false }
        return savedContent == candidateContent
    }

    /// Validate a snapshot without touching source files or changing the live document.
    /// Rendering and replacement acceptance require coverage down to the source frame;
    /// the document reader retains its historical millisecond rounding tolerance.
    func validateForRendering(_ project: Project) throws {
        var copy = project
        try validateStructure(of: &copy, requireCompleteSourceCoverage: true)
    }

    private func validateStructure(of project: inout Project, requireCompleteSourceCoverage: Bool = false) throws {
        guard project.formatVersion >= Project.minimumSupportedFormatVersion else {
            throw ProjectFileValidationError(L10n.format("The project uses an obsolete format version (%d).", project.formatVersion))
        }
        guard project.formatVersion <= Project.currentFormatVersion else {
            throw ProjectFileValidationError(
                L10n.format("This project was created by a newer version of LightAudio Editor (format %d). Update the app before opening it.", project.formatVersion)
            )
        }
        project.formatVersion = project.requiredFormatVersion

        func validTime(_ time: TimeInterval) -> Bool { TimelineViewState.isValidTimelineTime(time) }
        guard project.sampleRate.isFinite, project.sampleRate > 0, project.sampleRate <= 384_000 else {
            throw ProjectFileValidationError(L10n.tr("The project sample rate is invalid."))
        }
        guard validTime(project.duration) else {
            throw ProjectFileValidationError(L10n.tr("The project duration is invalid."))
        }
        guard project.mixState.masterVolumeDB.isFinite else {
            throw ProjectFileValidationError(L10n.tr("The project master volume is invalid."))
        }
        guard project.viewState.zoom.isFinite,
              project.viewState.horizontalScroll.isFinite,
              project.viewState.trackHeight.isFinite,
              project.viewState.inPoint.map({ $0.isFinite && $0 >= 0 }) ?? true,
              project.viewState.outPoint.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw ProjectFileValidationError(L10n.tr("The project timeline view state is invalid."))
        }
        project.viewState.zoom = TimelineViewState.clampedZoom(project.viewState.zoom)
        project.viewState.horizontalScroll = TimelineViewState.clampedHorizontalScroll(project.viewState.horizontalScroll)
        project.viewState.trackHeight = TimelineViewState.clampedTrackHeight(project.viewState.trackHeight)
        project.viewState.inPoint = TimelineViewState.clampedTimelineTime(project.viewState.inPoint)
        project.viewState.outPoint = TimelineViewState.clampedTimelineTime(project.viewState.outPoint)

        if project.timeline.tracks.isEmpty {
            project.timeline.tracks = [Track(name: "A1")]
        }

        let assetIDs = project.assets.map(\.id)
        guard Set(assetIDs).count == assetIDs.count else {
            throw ProjectFileValidationError(L10n.tr("The project contains duplicate media asset identifiers."))
        }
        for asset in project.assets {
            guard validTime(asset.metadata.duration),
                  asset.metadata.sampleRate.isFinite,
                  asset.metadata.sampleRate >= 0, asset.metadata.sampleRate <= 384_000,
                  asset.metadata.channelCount >= 0 else {
                throw ProjectFileValidationError(L10n.tr("The project contains invalid media metadata."))
            }
        }

        let trackIDs = project.timeline.tracks.map(\.id)
        guard Set(trackIDs).count == trackIDs.count else {
            throw ProjectFileValidationError(L10n.tr("The project contains duplicate track identifiers."))
        }

        let markerIDs = project.timeline.markers.map(\.id)
        guard Set(markerIDs).count == markerIDs.count,
              project.timeline.markers.allSatisfy({ validTime($0.time) }) else {
            throw ProjectFileValidationError(L10n.tr("The project contains invalid timeline markers."))
        }

        let assetsByID = Dictionary(uniqueKeysWithValues: project.assets.map { ($0.id, $0) })
        let knownAssetIDs = Set(assetIDs)
        var clipIDs = Set<UUID>()
        for (trackIndex, track) in project.timeline.tracks.enumerated() {
            guard track.volumeDB.isFinite,
                  track.pan.isFinite,
                  track.volumeAutomationKeyframes.allSatisfy({ validTime($0.time) && $0.gainDB.isFinite }) else {
                throw ProjectFileValidationError(L10n.format("Track %d has invalid mix or automation data.", trackIndex + 1))
            }
            for (clipIndex, clip) in track.clips.enumerated() {
                guard knownAssetIDs.contains(clip.sourceAssetID) else {
                    throw ProjectFileValidationError(L10n.format("Track %d, clip %d references media that is not present in this project.", trackIndex + 1, clipIndex + 1))
                }
                guard let asset = assetsByID[clip.sourceAssetID],
                      asset.metadata.duration.isFinite,
                      asset.metadata.duration >= 0 else {
                    throw ProjectFileValidationError(L10n.format("Track %d, clip %d references media with invalid duration metadata.", trackIndex + 1, clipIndex + 1))
                }
                guard validTime(clip.timelineStart), validTime(clip.timelineStart + clip.duration),
                      validTime(clip.sourceStart), validTime(clip.sourceEnd), clip.sourceEnd >= clip.sourceStart else {
                    throw ProjectFileValidationError(L10n.format("Track %d, clip %d has invalid timing data.", trackIndex + 1, clipIndex + 1))
                }
                let rate = asset.metadata.sampleRate
                let covered = rate > 0
                    ? AudioFrameMath.ceiling(clip.sourceEnd * rate) <= AudioFrameMath.ceiling(asset.metadata.duration * rate)
                    : clip.sourceEnd <= asset.metadata.duration
                guard clip.sourceEnd <= asset.metadata.duration + 0.001,
                      !requireCompleteSourceCoverage || covered else {
                    throw NSError(domain: "LightAudio", code: 35, userInfo: [NSLocalizedDescriptionKey:
                        L10n.format("The source for track %d, clip %d ends before the clip. Choose replacement media that covers all existing clips.", trackIndex + 1, clipIndex + 1)])
                }
                guard clip.fadeIn.duration.isFinite,
                      clip.fadeOut.duration.isFinite,
                      clip.fadeIn.duration >= 0,
                      clip.fadeOut.duration >= 0,
                      clip.fadeIn.duration <= clip.duration + 0.001,
                      clip.fadeOut.duration <= clip.duration + 0.001 else {
                    throw ProjectFileValidationError(L10n.format("Track %d, clip %d has fades outside its visible duration.", trackIndex + 1, clipIndex + 1))
                }
                guard clip.gain.isFinite,
                      clip.pan.isFinite,
                      clip.volumeAutomationKeyframes.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.gainDB.isFinite }),
                      clip.panAutomationKeyframes.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.pan.isFinite }) else {
                    throw ProjectFileValidationError(L10n.format("Track %d, clip %d has invalid mix or automation data.", trackIndex + 1, clipIndex + 1))
                }
                guard clipIDs.insert(clip.id).inserted else {
                    throw ProjectFileValidationError(L10n.tr("The project contains duplicate clip identifiers."))
                }
            }
        }

        project.recalculateDuration()
        guard validTime(project.duration) else {
            throw ProjectFileValidationError(L10n.tr("The project duration is invalid."))
        }
    }
}

private struct ProjectFileValidationError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        L10n.format("This .liau project is corrupted: %@", message)
    }
}
