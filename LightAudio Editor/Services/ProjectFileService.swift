import Foundation

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
        var copy = project
        copy.formatVersion = Project.currentFormatVersion
        copy.lastSavedAt = Date()
        let data = try encoder.encode(copy)
        try data.write(to: url, options: .atomic)
        return copy
    }

    func load(from url: URL) throws -> (Project, [MediaAsset]) {
        let data = try Data(contentsOf: url)
        var project = try decoder.decode(Project.self, from: data)
        let missing = try prepareForOpening(&project, projectURL: url)
        return (project, missing)
    }

    /// Validates relationships that Codable cannot express before the timeline is allowed to render.
    /// Declared assets with missing files remain valid and are handled by the relink flow below.
    func prepareForOpening(_ project: inout Project, projectURL: URL?) throws -> [MediaAsset] {
        try validateStructure(of: &project)
        return resolver.markMissingAssets(in: &project, projectURL: projectURL)
    }

    func encodeRecovery(_ snapshot: ProjectRecoverySnapshot, to url: URL) throws {
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    func decodeRecovery(from url: URL) throws -> ProjectRecoverySnapshot {
        let data = try Data(contentsOf: url)
        return try decoder.decode(ProjectRecoverySnapshot.self, from: data)
    }

    private func validateStructure(of project: inout Project) throws {
        guard project.formatVersion >= Project.minimumSupportedFormatVersion else {
            throw ProjectFileValidationError(L10n.format("The project uses an obsolete format version (%d).", project.formatVersion))
        }
        guard project.formatVersion <= Project.currentFormatVersion else {
            throw ProjectFileValidationError(
                L10n.format("This project was created by a newer version of LightAudio Editor (format %d). Update the app before opening it.", project.formatVersion)
            )
        }
        project.formatVersion = Project.currentFormatVersion

        guard project.sampleRate.isFinite, project.sampleRate > 0 else {
            throw ProjectFileValidationError(L10n.tr("The project sample rate is invalid."))
        }
        guard project.duration.isFinite, project.duration >= 0 else {
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
            guard asset.metadata.duration.isFinite,
                  asset.metadata.duration >= 0,
                  asset.metadata.sampleRate.isFinite,
                  asset.metadata.sampleRate >= 0,
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
              project.timeline.markers.allSatisfy({ $0.time.isFinite && $0.time >= 0 }) else {
            throw ProjectFileValidationError(L10n.tr("The project contains invalid timeline markers."))
        }

        let assetsByID = Dictionary(uniqueKeysWithValues: project.assets.map { ($0.id, $0) })
        let knownAssetIDs = Set(assetIDs)
        var clipIDs = Set<UUID>()
        for (trackIndex, track) in project.timeline.tracks.enumerated() {
            guard track.volumeDB.isFinite,
                  track.pan.isFinite,
                  track.volumeAutomationKeyframes.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.gainDB.isFinite }) else {
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
                guard clip.timelineStart.isFinite, clip.timelineStart >= 0,
                      clip.sourceStart.isFinite, clip.sourceStart >= 0,
                      clip.sourceEnd.isFinite, clip.sourceEnd >= clip.sourceStart,
                      clip.sourceEnd <= asset.metadata.duration + 0.001 else {
                    throw ProjectFileValidationError(L10n.format("Track %d, clip %d has invalid timing data.", trackIndex + 1, clipIndex + 1))
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
