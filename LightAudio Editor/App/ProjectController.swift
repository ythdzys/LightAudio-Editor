import Foundation
#if canImport(AppKit)
import AppKit
#endif
import AVFoundation

protocol ProjectControllerDelegate: AnyObject {
    func projectDidChange(_ project: Project)
    func projectController(_ controller: ProjectController, didFindMissingAssets assets: [MediaAsset])
    func projectController(_ controller: ProjectController, didFailWith error: Error)
}

enum MediaImportOutcome {
    case imported(MediaAsset)
    case duplicate(MediaAsset)
    case alreadyImporting
    case failed(Error)
}

struct TimelinePlacementResult {
    var targetTrackName: String
    var createdTrackNames: [String]
    var wasTrackClamped: Bool
    var mediaWasMissing: Bool
    var proxyIsPreparing: Bool
}

struct ProjectMediaCollectionSnapshot {
    let project: Project
    let projectURL: URL?
}

final class ProjectController {
    private struct ContinuousUndoSession {
        let actionName: String
        var hasRegisteredUndo = false
    }

    private struct ClipClipboardItem {
        let trackIndex: Int
        let clip: Clip
    }

    private struct ClipClipboard {
        let items: [ClipClipboardItem]
        let crossfades: [Crossfade]
    }

    private struct FolderRelinkAttempt {
        let assetID: UUID
        let expectedOriginalPath: String
        let fileName: String
        let result: RelinkResult
    }

    weak var delegate: ProjectControllerDelegate?

    private let fileService = ProjectFileService()
    private let importService = MediaImportService()
    private let relinkService = MediaRelinkService()
    private let resolver = FileReferenceResolver()
    private let proxyService: MediaProxyService
    private let applicationCacheService = ApplicationCacheService()
    private let recoveryService: AutosaveRecoveryService
    private let waveformService = WaveformAnalysisService()
    private var waveformData: [UUID: WaveformData] = [:]
    private var waveformGenerationIDs: Set<UUID> = []
    private var waveformJobs: [UUID: MediaPreparationScheduler.Job] = [:]
    private var proxyGenerationTasks: [UUID: MediaProxyService.ProxyGenerationHandle] = [:]
    private var proxyGenerationRequestIDs: [UUID: UUID] = [:]
    private var mediaCacheGeneration = 0
    private var projectGeneration = 0
    private var sourceVerificationTasks: [UUID: ExportCancellationToken] = [:]
    private let sourceVerificationQueue = DispatchQueue(label: "com.lightaudio.source-verification", qos: .utility)
    private var importingMediaPaths: [String: Int] = [:]
    private var continuousUndoSession: ContinuousUndoSession?
    private var continuousEditMediaAvailability: Bool?
    private let undoManagerProvider: () -> UndoManager?
    /// A canonical snapshot of persisted editing state at the last successful save/open.
    /// Derived cache and availability fields are intentionally excluded so waveform/proxy work
    /// does not make the document appear edited.
    private var savedEditableFingerprint: Data?
    private var savedProjectURLPath: String?

    private(set) var project = Project.empty()
    private(set) var projectURL: URL?
    private(set) var selectedClipIDs: Set<UUID> = []
    var selectedClipID: UUID? {
        selectedClipIDs.count == 1 ? selectedClipIDs.first : nil
    }
    var playheadTime: TimeInterval = 0
    private(set) var isDirty = false
    private(set) var audioRenderRevision = 0
    private var clipClipboard: ClipClipboard?
    /// Rechecks source files that may have moved or been removed since the project was opened.
    /// This updates only transient availability state; it does not mark the project as edited.
    @discardableResult
    func refreshMediaAvailability() -> [MediaAsset] {
        let previousTimestamps = project.assets.map(\.sourceModificationTimestamp)
        let previouslyVerifyingIDs = Set(project.assets.filter { $0.isVerifyingSource }.map(\.id))
        let previouslyMissingIDs = Set(project.missingAssets.map(\.id))
        let missing = resolver.markMissingAssets(in: &project, projectURL: projectURL, deferUncachedChecks: true)
        let currentlyMissingIDs = Set(project.missingAssets.map(\.id))

        startSourceVerifications()
        let currentlyVerifyingIDs = Set(project.assets.filter { $0.isVerifyingSource }.map(\.id))
        guard previouslyMissingIDs != currentlyMissingIDs || previouslyVerifyingIDs != currentlyVerifyingIDs
                || previousTimestamps != project.assets.map(\.sourceModificationTimestamp) else { return missing }

        for id in currentlyMissingIDs {
            cancelWaveformGeneration(for: id)
            cancelProxyGeneration(for: id)
            waveformData.removeValue(forKey: id)
        }
        notify()

        let restoredIDs = previouslyMissingIDs.subtracting(currentlyMissingIDs)
        for id in restoredIDs {
            prepareAsset(id)
        }
        return missing
    }

    var waveforms: [UUID: WaveformData] {
        waveformData
    }

    init(
        recoveryService: AutosaveRecoveryService,
        proxyService: MediaProxyService = MediaProxyService(),
        undoManagerProvider: @escaping () -> UndoManager? = {
            #if canImport(AppKit)
            return NSApp.mainWindow?.undoManager
            #else
            return nil
            #endif
        }
    ) {
        self.recoveryService = recoveryService
        self.proxyService = proxyService
        self.undoManagerProvider = undoManagerProvider
        recoveryService.projectProvider = { [weak self] in self?.project }
        recoveryService.isDirtyProvider = { [weak self] in self?.isDirty ?? false }
        recoveryService.start(projectURL: nil)
        captureSaveCheckpoint()
    }

    func renameProject(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != project.name else { return }
        registerUndo("Rename Project")
        project.name = name
        notify()
    }

    deinit {
        sourceVerificationTasks.values.forEach { $0.cancel() }
        waveformJobs.values.forEach { $0.cancel() }
        proxyGenerationTasks.values.forEach { $0.cancel() }
    }

    func newProject() {
        recoveryService.discardSnapshot(forProjectID: project.id)
        resetTransientProjectState()
        project = Project.empty()
        projectURL = nil
        selectedClipIDs = []
        playheadTime = 0
        captureSaveCheckpoint()
        recoveryService.updateProjectURL(nil)
        notify()
    }

    @discardableResult
    func open(url: URL) -> Bool {
        do {
            let (loaded, missing) = try fileService.load(from: url, deferUncachedChecks: true)
            recoveryService.discardSnapshot(forProjectID: project.id)
            resetTransientProjectState()
            project = loaded
            sanitizeCrossfades()
            projectURL = url
            selectedClipIDs = []
            captureSaveCheckpoint()
            recoveryService.updateProjectURL(url)
            notify()
            prepareAvailableAssets()
            let confirmedMissing = missing.filter { !$0.isVerifyingSource }
            if !confirmedMissing.isEmpty {
                delegate?.projectController(self, didFindMissingAssets: confirmedMissing)
            }
            return true
        } catch {
            delegate?.projectController(self, didFailWith: error)
            return false
        }
    }

    @discardableResult
    func restore(snapshot: ProjectRecoverySnapshot) -> Bool {
        do {
            var recoveredProject = snapshot.project
            let missing = try fileService.prepareForOpening(&recoveredProject, projectURL: snapshot.originalProjectURL, deferUncachedChecks: true)
            resetTransientProjectState()
            project = recoveredProject
            sanitizeCrossfades()
            projectURL = snapshot.originalProjectURL
            selectedClipIDs = []
            clearSaveCheckpoint()
            isDirty = true
            recoveryService.updateProjectURL(projectURL)
            notify()
            prepareAvailableAssets()
            let confirmedMissing = missing.filter { !$0.isVerifyingSource }
            if !confirmedMissing.isEmpty {
                delegate?.projectController(self, didFindMissingAssets: confirmedMissing)
            }
            return true
        } catch {
            delegate?.projectController(self, didFailWith: error)
            return false
        }
    }

    func save(to url: URL? = nil) -> Bool {
        guard let destination = url ?? projectURL else { return false }
        do {
            var copy = project
            for index in copy.assets.indices {
                let asset = copy.assets[index]
                let resolvedURL = resolver.resolvedURL(for: asset, projectURL: projectURL)
                // An offline asset's persisted original/relative references are the only reliable
                // way to find it again. Never replace them with a stale fallback while saving.
                guard !asset.isMissing,
                      FileManager.default.fileExists(atPath: resolvedURL.path) else {
                    continue
                }
                copy.assets[index].originalPath = resolvedURL.path
                copy.assets[index].resolvedPath = resolvedURL.path
                copy.assets[index].relativePath = resolver.relativePath(for: resolvedURL, projectURL: destination)
            }
            copy = try fileService.save(copy, to: destination)
            project = copy
            projectURL = destination
            captureSaveCheckpoint()
            recoveryService.updateProjectURL(destination)
            recoveryService.discardSnapshot(forProjectID: project.id)
            notify()
            return true
        } catch {
            delegate?.projectController(self, didFailWith: error)
            return false
        }
    }

    func importMedia(url: URL) {
        importMedia(url: url, addToTimeline: true, completion: nil)
    }

    func importMediaToLibrary(url: URL, completion: ((MediaImportOutcome) -> Void)? = nil) {
        importMedia(url: url, addToTimeline: false, completion: completion)
    }

    private func importMedia(url: URL, addToTimeline: Bool, completion: ((MediaImportOutcome) -> Void)?) {
        guard requireAllMediaOnline() else {
            let error = NSError(domain: "LightAudio", code: 33, userInfo: [NSLocalizedDescriptionKey: L10n.tr("Missing media must be relinked before importing new media.")])
            completion?(.failed(error))
            return
        }
        if let existing = existingAsset(for: url) {
            completion?(.duplicate(existing))
            return
        }
        let path = normalizedPath(url)
        guard importingMediaPaths[path] == nil else {
            completion?(.alreadyImporting)
            return
        }
        let importGeneration = projectGeneration
        importingMediaPaths[path] = importGeneration
        importService.importMedia(at: url, projectURL: projectURL) { [weak self] result in
            guard let self = self else { return }
            guard self.importingMediaPaths[path] == importGeneration else { return }
            self.importingMediaPaths.removeValue(forKey: path)
            guard importGeneration == self.projectGeneration else { return }
            switch result {
            case .success(let asset):
                if let existing = self.existingAsset(for: url) ?? self.project.assets.first(where: {
                    !$0.isMissing && asset.metadata.checksum?.hasPrefix("sha256:") == true &&
                    $0.metadata.checksum == asset.metadata.checksum
                }) {
                    completion?(.duplicate(existing))
                    return
                }
                self.registerUndo("Import Media")
                var asset = asset
                asset.waveformStatus = asset.requiresAudioPreparation ? .notGenerated : .generating
                asset.waveformFailureReason = nil
                self.project.assets.append(asset)
                if addToTimeline {
                    if self.project.timeline.tracks.isEmpty {
                        self.project.timeline.tracks.append(Track(name: "A1"))
                    }
                    let clip = Clip(sourceAssetID: asset.id, timelineStart: self.playheadTime, sourceStart: 0, sourceEnd: asset.metadata.duration)
                    self.project.timeline.tracks[0].clips.append(clip)
                    self.selectedClipIDs = [clip.id]
                }
                self.project.recalculateDuration()
                self.notify(audioChanged: addToTimeline)
                self.prepareAsset(asset.id)
                completion?(.imported(asset))
            case .failure(let error):
                self.delegate?.projectController(self, didFailWith: error)
                completion?(.failed(error))
            }
        }
    }

    @discardableResult
    func addAssetToTimeline(_ assetID: UUID) -> TimelinePlacementResult? {
        addAssetToTimeline(assetID, at: playheadTime, trackIndex: 0)
    }

    @discardableResult
    func addAssetToNewTrack(_ assetID: UUID) -> TimelinePlacementResult? {
        addAssetToTimeline(assetID, at: playheadTime, trackIndex: project.timeline.tracks.count)
    }

    @discardableResult
    func addAssetToTimeline(_ assetID: UUID, at timelineStart: TimeInterval, trackIndex: Int) -> TimelinePlacementResult? {
        guard requireAllMediaOnline() else { return nil }
        guard let asset = project.asset(id: assetID) else { return nil }
        let requestedTrack = max(0, trackIndex)
        let existingTrackCount = project.timeline.tracks.count
        let baseTrackCount = max(existingTrackCount, 1)
        let maximumTargetTrack = min(63, baseTrackCount + 4 - 1)
        let targetTrack = min(requestedTrack, maximumTargetTrack)
        if targetTrack < existingTrackCount, project.timeline.tracks[targetTrack].isLocked {
            showLockedTrackError()
            return nil
        }
        registerUndo("Add Clip")
        var createdTrackNames: [String] = []
        while project.timeline.tracks.count <= targetTrack {
            let name = nextTrackName()
            project.timeline.tracks.append(Track(name: name))
            createdTrackNames.append(name)
        }
        let clip = Clip(sourceAssetID: assetID, timelineStart: max(0, timelineStart), sourceStart: 0, sourceEnd: asset.metadata.duration)
        project.timeline.tracks[targetTrack].clips.append(clip)
        selectedClipIDs = [clip.id]
        project.recalculateDuration()
        notify(audioChanged: true)
        return TimelinePlacementResult(
            targetTrackName: project.timeline.tracks[targetTrack].name,
            createdTrackNames: createdTrackNames,
            wasTrackClamped: requestedTrack != targetTrack,
            mediaWasMissing: asset.isMissing,
            proxyIsPreparing: asset.requiresAudioPreparation && asset.proxyStatus != .ready
        )
    }

    func selectClip(_ clipID: UUID?) {
        selectedClipIDs = clipID.map { [$0] } ?? []
        notify()
    }

    func selectClip(_ clipID: UUID, toggling: Bool, extending: Bool) {
        if toggling {
            if selectedClipIDs.contains(clipID) {
                selectedClipIDs.remove(clipID)
            } else {
                selectedClipIDs.insert(clipID)
            }
        } else if extending {
            selectedClipIDs.insert(clipID)
        } else {
            selectedClipIDs = [clipID]
        }
        notify()
    }

    func selectClips(_ clipIDs: Set<UUID>, adding: Bool) {
        selectedClipIDs = adding ? selectedClipIDs.union(clipIDs) : clipIDs
        notify()
    }

    func setPlayhead(_ time: TimeInterval) {
        playheadTime = max(0, time)
        notify()
    }

    func zoomTimeline(by multiplier: Double) {
        project.viewState.zoom = clampedTimelineZoom(project.viewState.zoom * multiplier)
        notify()
    }

    func setTimelineZoom(_ zoom: Double) {
        project.viewState.zoom = clampedTimelineZoom(zoom)
        notify()
    }

    func addTrack() {
        guard requireAllMediaOnline() else { return }
        registerUndo("Add Track")
        project.timeline.tracks.append(Track(name: nextTrackName()))
        notify()
    }

    func addTrack(above trackID: UUID) {
        guard let index = project.timeline.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        insertTrack(at: index, actionName: "Add Track Above")
    }

    func addTrack(below trackID: UUID) {
        guard let index = project.timeline.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        insertTrack(at: index + 1, actionName: "Add Track Below")
    }

    func duplicateTrack(_ trackID: UUID) {
        guard let index = project.timeline.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        guard requireAllMediaOnline() else { return }
        registerUndo("Duplicate Track")
        var copy = project.timeline.tracks[index]
        copy.id = UUID()
        copy.name = nextTrackName()
        copy.volumeAutomationKeyframes = copy.volumeAutomationKeyframes.map { keyframe in
            var duplicated = keyframe
            duplicated.id = UUID()
            return duplicated
        }
        var duplicatedClipIDs: [UUID: UUID] = [:]
        copy.clips = copy.clips.map { clip in
            var duplicated = clip
            let originalID = duplicated.id
            duplicated.id = UUID()
            duplicatedClipIDs[originalID] = duplicated.id
            duplicated.volumeAutomationKeyframes = duplicated.volumeAutomationKeyframes.map { keyframe in
                var copiedKeyframe = keyframe
                copiedKeyframe.id = UUID()
                return copiedKeyframe
            }
            duplicated.panAutomationKeyframes = duplicated.panAutomationKeyframes.map { keyframe in
                var copiedKeyframe = keyframe
                copiedKeyframe.id = UUID()
                return copiedKeyframe
            }
            duplicated.effects = duplicated.effects.map { effect in
                var copiedEffect = effect
                copiedEffect.id = UUID()
                return copiedEffect
            }
            return duplicated
        }
        let copiedCrossfades = project.timeline.crossfades.compactMap { crossfade -> Crossfade? in
            guard let leadingID = duplicatedClipIDs[crossfade.leadingClipID],
                  let trailingID = duplicatedClipIDs[crossfade.trailingClipID] else {
                return nil
            }
            return Crossfade(
                leadingClipID: leadingID,
                trailingClipID: trailingID,
                startTime: crossfade.startTime,
                duration: crossfade.duration,
                curve: crossfade.curve,
                startProgress: crossfade.startProgress,
                endProgress: crossfade.endProgress
            )
        }
        project.timeline.tracks.insert(copy, at: index + 1)
        project.timeline.crossfades.append(contentsOf: copiedCrossfades)
        sanitizeCrossfades()
        selectedClipIDs = Set(copy.clips.map(\.id))
        project.recalculateDuration()
        notify(audioChanged: true)
    }

    func deleteTrack(_ trackID: UUID, allowNonEmpty: Bool) {
        guard requireAllMediaOnline() else { return }
        guard let index = project.timeline.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        guard project.timeline.tracks[index].clips.isEmpty || allowNonEmpty else {
            delegate?.projectController(self, didFailWith: NSError(domain: "LightAudio", code: 31, userInfo: [NSLocalizedDescriptionKey: L10n.tr("Only empty tracks can be deleted without confirmation.")]))
            return
        }
        guard project.timeline.tracks.count > 1 else { return }
        registerUndo("Delete Track")
        let removedClipIDs = Set(project.timeline.tracks[index].clips.map(\.id))
        project.timeline.tracks.remove(at: index)
        selectedClipIDs.subtract(removedClipIDs)
        removeCrossfades(involving: removedClipIDs)
        project.recalculateDuration()
        notify(audioChanged: true)
    }

    func moveTrack(_ trackID: UUID, to targetIndex: Int) {
        guard requireAllMediaOnline() else { return }
        guard let sourceIndex = project.timeline.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let destination = min(max(targetIndex, 0), project.timeline.tracks.count - 1)
        guard sourceIndex != destination else { return }
        registerUndo("Reorder Track")
        let track = project.timeline.tracks.remove(at: sourceIndex)
        project.timeline.tracks.insert(track, at: destination)
        notify()
    }

    func toggleTrackCollapsed(trackID: UUID) {
        updateTrack(trackID, actionName: "Collapse Track") { $0.isCollapsed.toggle() }
    }

    func toggleMute(trackID: UUID) {
        updateTrack(trackID, actionName: "Mute Track", audioChanged: true) { $0.isMuted.toggle() }
    }

    func toggleSolo(trackID: UUID) {
        updateTrack(trackID, actionName: "Solo Track", audioChanged: true) { $0.isSolo.toggle() }
    }

    func toggleLock(trackID: UUID) {
        updateTrack(trackID, actionName: "Lock Track") { $0.isLocked.toggle() }
    }

    func setTrackVolume(trackID: UUID, volumeDB: Double) {
        guard requireAllMediaOnline() else { return }
        guard let track = project.timeline.tracks.first(where: { $0.id == trackID }), !track.isLocked else {
            showLockedTrackError()
            return
        }
        updateTrack(trackID, actionName: "Track Volume", audioChanged: true) { $0.volumeDB = MixMath.clampTrackVolumeDB(volumeDB) }
    }

    func setTrackPan(trackID: UUID, pan: Double) {
        guard requireAllMediaOnline() else { return }
        guard let track = project.timeline.tracks.first(where: { $0.id == trackID }), !track.isLocked else {
            showLockedTrackError()
            return
        }
        updateTrack(trackID, actionName: "Track Pan", audioChanged: true) { $0.pan = MixMath.clampPan(pan) }
    }

    func setMasterVolume(_ volumeDB: Double) {
        guard requireAllMediaOnline() else { return }
        registerUndo("Master Volume")
        project.mixState.masterVolumeDB = MixMath.clampMasterVolumeDB(volumeDB)
        notify(audioChanged: true)
    }

    func renameTrack(trackID: UUID, name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        updateTrack(trackID, actionName: "Rename Track") { $0.name = cleanName }
    }

    func moveClip(_ clipID: UUID, to newStart: TimeInterval, trackIndex: Int? = nil) {
        guard requireAllMediaOnline(), newStart.isFinite else { return }
        if selectedClipIDs.contains(clipID), selectedClipIDs.count > 1 {
            guard let location = locateClip(clipID) else { return }
            let targetTrack = min(max(trackIndex ?? location.track, 0), project.timeline.tracks.count - 1)
            moveSelectedClips(deltaTime: newStart - project.timeline.tracks[location.track].clips[location.clip].timelineStart, trackDelta: targetTrack - location.track, actionName: "Move Clips")
            return
        }
        guard let location = locateClip(clipID), !project.timeline.tracks[location.track].isLocked else {
            showLockedTrackError()
            return
        }
        let targetTrack = min(max(trackIndex ?? location.track, 0), project.timeline.tracks.count - 1)
        guard !project.timeline.tracks[targetTrack].isLocked else {
            showLockedTrackError()
            return
        }
        let duration = project.timeline.tracks[location.track].clips[location.clip].duration
        guard TimelineViewState.isValidTimelineTime(max(0, newStart) + duration) else { return }
        registerUndo("Move Clip")
        var clip = project.timeline.tracks[location.track].clips.remove(at: location.clip)
        clip.timelineStart = max(0, newStart)
        project.timeline.tracks[targetTrack].clips.append(clip)
        updateAutomaticCrossfadesIfNeeded(involving: [clip.id])
        sanitizeCrossfades()
        project.recalculateDuration()
        notify(audioChanged: true)
    }

    func copySelectedClips() {
        let items = selectedClipLocations().map {
            ClipClipboardItem(trackIndex: $0.track, clip: project.timeline.tracks[$0.track].clips[$0.clip])
        }
        clipClipboard = ClipClipboard(
            items: items,
            crossfades: crossfadesContained(in: Set(items.map { $0.clip.id }))
        )
    }

    func cutSelectedClips() {
        copySelectedClips()
        deleteSelectedClip()
    }

    func pasteClipsAtPlayhead() {
        guard requireAllMediaOnline(), let clipboard = clipClipboard, !clipboard.items.isEmpty else { return }
        let availableAssetIDs = Set(project.assets.map(\.id))
        guard clipboard.items.allSatisfy({ availableAssetIDs.contains($0.clip.sourceAssetID) }) else {
            clipClipboard = nil
            delegate?.projectController(
                self,
                didFailWith: projectError(
                    code: 62,
                    message: "Copied clips belong to a different project. Copy the clips again before pasting."
                )
            )
            return
        }
        let earliest = clipboard.items.map { $0.clip.timelineStart }.min() ?? 0
        let maxTrack = clipboard.items.map { $0.trackIndex }.max() ?? 0
        guard !clipboard.items.contains(where: { item in
            item.trackIndex < project.timeline.tracks.count && project.timeline.tracks[item.trackIndex].isLocked
        }) else {
            showLockedTrackError()
            return
        }
        let proposedOffset = max(0, playheadTime) - earliest
        guard clipboard.items.allSatisfy({ TimelineViewState.isValidTimelineTime($0.clip.timelineStart + $0.clip.duration + proposedOffset) }) else { return }
        registerUndo("Paste Clips")
        while project.timeline.tracks.count <= maxTrack {
            project.timeline.tracks.append(Track(name: nextTrackName()))
        }
        var newIDs: Set<UUID> = []
        var copiedIDs: [UUID: UUID] = [:]
        let timelineOffset = max(0, playheadTime) - earliest
        for item in clipboard.items {
            let originalID = item.clip.id
            var clip = copiedClip(from: item.clip)
            clip.timelineStart = max(0, clip.timelineStart + timelineOffset)
            project.timeline.tracks[item.trackIndex].clips.append(clip)
            copiedIDs[originalID] = clip.id
            newIDs.insert(clip.id)
        }
        appendCopiedCrossfades(clipboard.crossfades, using: copiedIDs, timelineOffset: timelineOffset)
        sanitizeCrossfades()
        selectedClipIDs = newIDs
        project.recalculateDuration()
        notify(audioChanged: true)
    }

    func addMarkerAtPlayhead() {
        guard requireAllMediaOnline(), TimelineViewState.isValidTimelineTime(playheadTime) else { return }
        registerUndo("Add Marker")
        let index = project.timeline.markers.count + 1
        project.timeline.markers.append(TimelineMarker(time: playheadTime, name: "Marker \(index)"))
        notify()
    }

    func deleteMarker(_ markerID: UUID) {
        guard requireAllMediaOnline() else { return }
        guard let index = project.timeline.markers.firstIndex(where: { $0.id == markerID }) else { return }
        registerUndo("Delete Marker")
        project.timeline.markers.remove(at: index)
        notify()
    }

    func renameMarker(_ markerID: UUID, name: String) {
        guard requireAllMediaOnline() else { return }
        guard let index = project.timeline.markers.firstIndex(where: { $0.id == markerID }) else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        registerUndo("Rename Marker")
        project.timeline.markers[index].name = cleanName
        notify()
    }

    func toggleSnapping() {
        guard requireAllMediaOnline() else { return }
        registerUndo("Toggle Snapping")
        project.viewState.snappingEnabled.toggle()
        notify()
    }

    func toggleFollowPlayhead() {
        guard requireAllMediaOnline() else { return }
        registerUndo("Toggle Follow Playhead")
        project.viewState.followPlayhead.toggle()
        notify()
    }

    func setInPoint(at time: TimeInterval? = nil) {
        guard requireAllMediaOnline() else { return }
        registerUndo("Set In Point")
        let value = TimelineViewState.clampedTimelineTime(time ?? playheadTime) ?? 0
        project.viewState.inPoint = value
        if let outPoint = project.viewState.outPoint, outPoint < value {
            project.viewState.inPoint = outPoint
            project.viewState.outPoint = value
        }
        notify(audioChanged: true)
    }

    func setOutPoint(at time: TimeInterval? = nil) {
        guard requireAllMediaOnline() else { return }
        registerUndo("Set Out Point")
        let value = TimelineViewState.clampedTimelineTime(time ?? playheadTime) ?? 0
        project.viewState.outPoint = value
        if let inPoint = project.viewState.inPoint, value < inPoint {
            project.viewState.inPoint = value
            project.viewState.outPoint = inPoint
        }
        notify(audioChanged: true)
    }

    func clearInOutRange() {
        guard requireAllMediaOnline() else { return }
        guard project.viewState.inPoint != nil || project.viewState.outPoint != nil else { return }
        registerUndo("Clear In/Out Range")
        project.viewState.inPoint = nil
        project.viewState.outPoint = nil
        notify(audioChanged: true)
    }

    /// Coalesces a pointer-driven edit into one project snapshot for undo/redo.
    func beginContinuousEdit(actionName: String) {
        guard continuousUndoSession == nil else { return }
        continuousEditMediaAvailability = validateAllMediaOnline()
        continuousUndoSession = ContinuousUndoSession(actionName: actionName)
    }

    func endContinuousEdit() {
        continuousUndoSession = nil
        continuousEditMediaAvailability = nil
    }

    func toggleLoopRange() {
        guard requireAllMediaOnline() else { return }
        registerUndo("Toggle Loop Range")
        project.viewState.loopRangeEnabled.toggle()
        notify(audioChanged: true)
    }

    func increaseTrackHeight() {
        setTrackHeight(project.viewState.trackHeight + 12, actionName: "Increase Track Height")
    }

    func decreaseTrackHeight() {
        setTrackHeight(project.viewState.trackHeight - 12, actionName: "Decrease Track Height")
    }

    func resetTrackHeight() {
        setTrackHeight(TimelineViewState.defaultTrackHeight, actionName: "Reset Track Height")
    }

    func deleteTrack(_ trackID: UUID) {
        deleteTrack(trackID, allowNonEmpty: false)
    }

    func trimClip(_ clipID: UUID, edge: TimelineTrimEdge, to timelineTime: TimeInterval) {
        guard requireAllMediaOnline() else { return }
        guard clipIsEditable(clipID) else { return }
        let sourceDuration = locateClip(clipID).flatMap { location in
            project.asset(id: project.timeline.tracks[location.track].clips[location.clip].sourceAssetID)?.metadata.duration
        }
        updateClip(clipID, actionName: "Trim Clip") { clip in
            let maxSourceEnd = sourceDuration ?? clip.sourceEnd
            switch edge {
            case .left:
                let rightEdge = clip.timelineStart + clip.duration
                let requestedStart = min(max(0, timelineTime), rightEdge - 0.05)
                // Extending left can only consume source material that precedes sourceStart.
                // Clamp the timeline edge first so a blocked extension never moves the right edge.
                let earliestStart = max(0, clip.timelineStart - clip.sourceStart)
                let newStart = max(earliestStart, requestedStart)
                let delta = newStart - clip.timelineStart
                clip.timelineStart = newStart
                clip.sourceStart = min(max(0, clip.sourceStart + delta), max(0, clip.sourceEnd - 0.05))
            case .right:
                let newDuration = max(0.05, timelineTime - clip.timelineStart)
                clip.sourceEnd = min(max(clip.sourceStart + 0.05, clip.sourceStart + newDuration), maxSourceEnd)
            }
            let duration = max(0.05, clip.duration)
            clip.fadeIn.duration = min(max(0, clip.fadeIn.duration), duration)
            clip.fadeOut.duration = min(max(0, clip.fadeOut.duration), duration)
            clip.volumeAutomationKeyframes = clip.volumeAutomationKeyframes.map { $0.clamped(maxTime: duration) }.sorted { $0.time < $1.time }
            clip.panAutomationKeyframes = clip.panAutomationKeyframes.map { $0.clamped(maxTime: duration) }.sorted { $0.time < $1.time }
        }
        updateAutomaticCrossfadesIfNeeded(involving: [clipID])
        if sanitizeCrossfades() {
            notify(audioChanged: true)
        }
    }

    func splitClip(_ clipID: UUID, at timelineTime: TimeInterval) {
        guard requireAllMediaOnline() else { return }
        guard clipIsEditable(clipID) else { return }
        guard let location = locateClip(clipID) else { return }
        var clip = project.timeline.tracks[location.track].clips[location.clip]
        guard timelineTime > clip.timelineStart + 0.05 && timelineTime < clip.timelineStart + clip.duration - 0.05 else { return }
        registerUndo("Split Clip")
        let offset = timelineTime - clip.timelineStart
        let originalVolumeAutomation = clip.volumeAutomationKeyframes
        let originalPanAutomation = clip.panAutomationKeyframes
        let originalFadeIn = clip.fadeIn
        let originalFadeOut = clip.fadeOut
        let splitVolumeDB = AutomationMath.volumeAutomationDB(for: clip, atClipTime: offset)
        let splitPan = AutomationMath.panAutomation(for: clip, atClipTime: offset)
        var right = clip
        right.id = UUID()
        right.timelineStart = timelineTime
        right.sourceStart = clip.sourceStart + offset
        clip.sourceEnd = clip.sourceStart + offset

        // Retain each curve's original progress interval, including splits inside a fade.
        clip.fadeIn = originalFadeIn.segment(from: 0, through: clip.duration)
        right.fadeIn = originalFadeIn.segment(from: offset, through: offset + right.duration)
        clip.fadeOut = originalFadeOut.segment(from: right.duration, through: right.duration + clip.duration)
        right.fadeOut = originalFadeOut.segment(from: 0, through: right.duration)

        let volumeAutomation = splitVolumeAutomation(
            originalVolumeAutomation,
            at: offset,
            leftDuration: clip.duration,
            rightDuration: right.duration,
            valueAtSplit: splitVolumeDB
        )
        let panAutomation = splitPanAutomation(
            originalPanAutomation,
            at: offset,
            leftDuration: clip.duration,
            rightDuration: right.duration,
            valueAtSplit: splitPan
        )
        clip.volumeAutomationKeyframes = volumeAutomation.left
        right.volumeAutomationKeyframes = volumeAutomation.right
        clip.panAutomationKeyframes = panAutomation.left
        right.panAutomationKeyframes = panAutomation.right
        project.timeline.tracks[location.track].clips[location.clip] = clip
        project.timeline.tracks[location.track].clips.insert(right, at: location.clip + 1)
        project.timeline.crossfades = project.timeline.crossfades.flatMap { crossfade -> [Crossfade] in
            guard crossfade.leadingClipID == clip.id || crossfade.trailingClipID == clip.id else { return [crossfade] }
            var pieces: [Crossfade] = []
            for half in [clip, right] {
                guard var piece = crossfade.segment(from: half.timelineStart, through: half.timelineStart + half.duration) else { continue }
                if crossfade.leadingClipID == clip.id { piece.leadingClipID = half.id }
                else { piece.trailingClipID = half.id }
                if !pieces.isEmpty { piece.id = UUID() }
                pieces.append(piece)
            }
            return pieces
        }
        sanitizeCrossfades()
        selectedClipIDs = [right.id]
        project.recalculateDuration()
        notify(audioChanged: true)
    }

    func deleteSelectedClip() {
        guard requireAllMediaOnline() else { return }
        let editableIDs = selectedEditableClipIDs()
        guard !editableIDs.isEmpty else { return }
        registerUndo(editableIDs.count == 1 ? "Delete Clip" : "Delete Clips")
        for trackIndex in project.timeline.tracks.indices {
            project.timeline.tracks[trackIndex].clips.removeAll { editableIDs.contains($0.id) }
        }
        removeCrossfades(involving: editableIDs)
        selectedClipIDs.subtract(editableIDs)
        project.recalculateDuration()
        notify(audioChanged: true)
    }

    func setClipGain(_ gain: Double) {
        guard requireAllMediaOnline() else { return }
        updateSelectedClips(actionName: "Clip Gain") { $0.gain = MixMath.clampClipGainLinear(gain) }
    }

    func setClipPan(_ pan: Double) {
        guard requireAllMediaOnline() else { return }
        updateSelectedClips(actionName: "Clip Pan") { $0.pan = min(max(-1, pan), 1) }
    }

    func setClipFadeIn(_ duration: TimeInterval) {
        guard requireAllMediaOnline() else { return }
        updateSelectedClips(actionName: "Fade In") { clip in
            clip.fadeIn = Fade(duration: min(max(0, duration), clip.duration), curve: clip.fadeIn.curve)
        }
    }

    func setClipFadeOut(_ duration: TimeInterval) {
        guard requireAllMediaOnline() else { return }
        updateSelectedClips(actionName: "Fade Out") { clip in
            clip.fadeOut = Fade(duration: min(max(0, duration), clip.duration), curve: clip.fadeOut.curve)
        }
    }

    func setClipFade(clipID: UUID, edge: TimelineTrimEdge, duration: TimeInterval) {
        guard requireAllMediaOnline() else { return }
        updateClip(clipID, actionName: edge == .left ? "Fade In" : "Fade Out") { clip in
            switch edge {
            case .left:
                clip.fadeIn = Fade(duration: min(max(0, duration), clip.duration), curve: clip.fadeIn.curve)
            case .right:
                clip.fadeOut = Fade(duration: min(max(0, duration), clip.duration), curve: clip.fadeOut.curve)
            }
        }
    }

    func setClipFadeCurve(edge: TimelineTrimEdge, curve: FadeCurve) {
        guard requireAllMediaOnline() else { return }
        updateSelectedClips(actionName: edge == .left ? "Fade In Curve" : "Fade Out Curve") { clip in
            switch edge {
            case .left:
                clip.fadeIn.curve = curve
            case .right:
                clip.fadeOut.curve = curve
            }
        }
    }

    func setClipFadeCurve(clipID: UUID, edge: TimelineTrimEdge, curve: FadeCurve) {
        guard requireAllMediaOnline() else { return }
        updateClip(clipID, actionName: edge == .left ? "Fade In Curve" : "Fade Out Curve") { clip in
            switch edge {
            case .left:
                clip.fadeIn.curve = curve
            case .right:
                clip.fadeOut.curve = curve
            }
        }
    }

    func applyFadeToSelected(edge: TimelineTrimEdge, duration: TimeInterval, curve: FadeCurve) {
        guard requireAllMediaOnline() else { return }
        updateSelectedClips(actionName: edge == .left ? "Apply Fade In" : "Apply Fade Out") { clip in
            let clampedDuration = min(max(0, duration), clip.duration)
            switch edge {
            case .left:
                clip.fadeIn = Fade(duration: clampedDuration, curve: curve)
            case .right:
                clip.fadeOut = Fade(duration: clampedDuration, curve: curve)
            }
        }
    }

    func removeFadesFromSelectedClips() {
        guard requireAllMediaOnline() else { return }
        updateSelectedClips(actionName: "Remove Fades") { clip in
            clip.fadeIn = Fade()
            clip.fadeOut = Fade()
        }
    }

    @discardableResult
    func createCrossfadeForSelectedClips() -> Bool {
        guard requireAllMediaOnline() else { return false }
        let selected = Array(selectedClipIDs)
        guard selected.count == 2 else { return false }
        return createCrossfade(between: selected[0], and: selected[1], curve: .equalPower, actionName: "Create Crossfade")
    }

    @discardableResult
    func createCrossfade(involving clipID: UUID) -> Bool {
        guard requireAllMediaOnline() else { return false }
        if selectedClipIDs.count == 2, selectedClipIDs.contains(clipID) {
            return createCrossfadeForSelectedClips()
        }
        guard let candidate = bestOverlappingClipID(for: clipID) else { return false }
        return createCrossfade(between: clipID, and: candidate, curve: .equalPower, actionName: "Create Crossfade")
    }

    func setCrossfadeCurve(involving clipID: UUID, curve: CrossfadeCurve) {
        guard requireAllMediaOnline() else { return }
        let indexes = project.timeline.crossfades.indices.filter {
            project.timeline.crossfades[$0].leadingClipID == clipID || project.timeline.crossfades[$0].trailingClipID == clipID
        }
        guard !indexes.isEmpty else { return }
        registerUndo("Crossfade Curve")
        for index in indexes {
            project.timeline.crossfades[index].curve = curve
        }
        notify(audioChanged: true)
    }

    func removeCrossfadesForSelectedClips() {
        guard requireAllMediaOnline() else { return }
        guard !selectedClipIDs.isEmpty else { return }
        guard project.timeline.crossfades.contains(where: {
            selectedClipIDs.contains($0.leadingClipID) || selectedClipIDs.contains($0.trailingClipID)
        }) else { return }
        registerUndo("Remove Crossfades")
        removeCrossfades(involving: selectedClipIDs)
        notify(audioChanged: true)
    }

    func removeCrossfades(involving clipID: UUID) {
        guard requireAllMediaOnline() else { return }
        guard project.timeline.crossfades.contains(where: {
            $0.leadingClipID == clipID || $0.trailingClipID == clipID
        }) else { return }
        registerUndo("Remove Crossfades")
        removeCrossfades(involving: [clipID])
        notify(audioChanged: true)
    }

    func renameSelectedClip(_ name: String?) {
        guard requireAllMediaOnline(), selectedClipIDs.count == 1, let clipID = selectedClipID else { return }
        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        updateClip(clipID, actionName: "Rename Clip", audioChanged: false) { clip in
            clip.customName = cleanName?.isEmpty == false ? cleanName : nil
        }
    }

    func renameClip(_ clipID: UUID, name: String?) {
        guard requireAllMediaOnline() else { return }
        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        updateClip(clipID, actionName: "Rename Clip", audioChanged: false) { clip in
            clip.customName = cleanName?.isEmpty == false ? cleanName : nil
        }
    }

    func setSelectedClipColor(_ color: ClipColorLabel) {
        guard requireAllMediaOnline() else { return }
        updateSelectedClips(actionName: "Clip Color", audioChanged: false) { $0.colorLabel = color }
    }

    func setClipColor(_ clipID: UUID, color: ClipColorLabel) {
        guard requireAllMediaOnline() else { return }
        updateClip(clipID, actionName: "Clip Color", audioChanged: false) { $0.colorLabel = color }
    }

    func addVolumeKeyframeToSelectedClip(atPlayheadWith gainDB: Double? = nil) {
        guard selectedClipIDs.count == 1, let clipID = selectedClipID else { return }
        addVolumeKeyframeAtPlayhead(clipID: clipID, gainDB: gainDB)
    }

    func addVolumeKeyframeAtPlayhead(clipID: UUID, gainDB: Double? = nil) {
        guard let location = locateClip(clipID) else { return }
        let clip = project.timeline.tracks[location.track].clips[location.clip]
        let localTime = playheadTime - clip.timelineStart
        addVolumeKeyframe(clipID: clipID, time: localTime, gainDB: gainDB ?? AutomationMath.volumeAutomationDB(for: clip, atClipTime: localTime))
    }

    func addVolumeKeyframe(clipID: UUID, time: TimeInterval, gainDB: Double) {
        guard requireAllMediaOnline() else { return }
        updateClip(clipID, actionName: "Add Volume Keyframe") { clip in
            let keyframe = ClipVolumeAutomationKeyframe(time: time, gainDB: gainDB).clamped(maxTime: clip.duration)
            if let index = clip.volumeAutomationKeyframes.firstIndex(where: { abs($0.time - keyframe.time) < 0.02 }) {
                clip.volumeAutomationKeyframes[index].gainDB = keyframe.gainDB
            } else {
                clip.volumeAutomationKeyframes.append(keyframe)
            }
            clip.volumeAutomationKeyframes = clip.volumeAutomationKeyframes.map { $0.clamped(maxTime: clip.duration) }.sorted { $0.time < $1.time }
        }
    }

    func moveVolumeKeyframe(clipID: UUID, keyframeID: UUID, time: TimeInterval, gainDB: Double) {
        guard requireAllMediaOnline() else { return }
        updateClip(clipID, actionName: "Move Volume Keyframe") { clip in
            guard let index = clip.volumeAutomationKeyframes.firstIndex(where: { $0.id == keyframeID }) else { return }
            clip.volumeAutomationKeyframes[index].time = min(max(0, time), clip.duration)
            clip.volumeAutomationKeyframes[index].gainDB = MixMath.clampClipAutomationDB(gainDB)
            clip.volumeAutomationKeyframes = clip.volumeAutomationKeyframes.map { $0.clamped(maxTime: clip.duration) }.sorted { $0.time < $1.time }
        }
    }

    func deleteVolumeKeyframe(clipID: UUID, keyframeID: UUID) {
        guard requireAllMediaOnline() else { return }
        updateClip(clipID, actionName: "Delete Volume Keyframe") { clip in
            clip.volumeAutomationKeyframes.removeAll { $0.id == keyframeID }
        }
    }

    func clearSelectedClipVolumeAutomation() {
        guard selectedClipIDs.count == 1, let clipID = selectedClipID else { return }
        clearVolumeAutomation(clipID: clipID)
    }

    func clearVolumeAutomation(clipID: UUID) {
        guard requireAllMediaOnline() else { return }
        updateClip(clipID, actionName: "Clear Volume Automation") { clip in
            clip.volumeAutomationKeyframes.removeAll()
        }
    }

    // The automation editors share the cross-platform project keyframes.
    func addPanKeyframe(clipID: UUID, time: TimeInterval, pan: Double) {
        guard time.isFinite, pan.isFinite else { return }
        updateClip(clipID, actionName: "Add Pan Keyframe") { clip in
            let point = ClipPanAutomationKeyframe(time: time, pan: pan).clamped(maxTime: clip.duration)
            if let index = clip.panAutomationKeyframes.firstIndex(where: { abs($0.time - point.time) < 0.02 }) {
                clip.panAutomationKeyframes[index].pan = point.pan
            } else { clip.panAutomationKeyframes.append(point) }
            clip.panAutomationKeyframes.sort { $0.time < $1.time }
        }
    }

    func movePanKeyframe(clipID: UUID, keyframeID: UUID, time: TimeInterval, pan: Double) {
        guard time.isFinite, pan.isFinite else { return }
        updateClip(clipID, actionName: "Move Pan Keyframe") { clip in
            guard let index = clip.panAutomationKeyframes.firstIndex(where: { $0.id == keyframeID }) else { return }
            clip.panAutomationKeyframes[index] = ClipPanAutomationKeyframe(id: keyframeID, time: time, pan: pan).clamped(maxTime: clip.duration)
            clip.panAutomationKeyframes.sort { $0.time < $1.time }
        }
    }

    func deletePanKeyframe(clipID: UUID, keyframeID: UUID) {
        updateClip(clipID, actionName: "Delete Pan Keyframe") { $0.panAutomationKeyframes.removeAll { $0.id == keyframeID } }
    }

    func clearPanAutomation(clipID: UUID) {
        updateClip(clipID, actionName: "Clear Pan Automation") { $0.panAutomationKeyframes.removeAll() }
    }

    func addTrackVolumeKeyframe(trackID: UUID, time: TimeInterval, gainDB: Double) {
        guard time.isFinite, time <= TimelineViewState.maximumTimelineTime, gainDB.isFinite else { return }
        updateTrackAutomation(trackID, actionName: "Add Track Volume Keyframe") { track in
            let point = TrackVolumeAutomationKeyframe(time: time, gainDB: gainDB).clamped()
            if let index = track.volumeAutomationKeyframes.firstIndex(where: { abs($0.time - point.time) < 0.02 }) {
                track.volumeAutomationKeyframes[index].gainDB = point.gainDB
            } else { track.volumeAutomationKeyframes.append(point) }
            track.volumeAutomationKeyframes.sort { $0.time < $1.time }
        }
    }

    func moveTrackVolumeKeyframe(trackID: UUID, keyframeID: UUID, time: TimeInterval, gainDB: Double) {
        guard time.isFinite, time <= TimelineViewState.maximumTimelineTime, gainDB.isFinite else { return }
        updateTrackAutomation(trackID, actionName: "Move Track Volume Keyframe") { track in
            guard let index = track.volumeAutomationKeyframes.firstIndex(where: { $0.id == keyframeID }) else { return }
            track.volumeAutomationKeyframes[index] = TrackVolumeAutomationKeyframe(id: keyframeID, time: time, gainDB: gainDB).clamped()
            track.volumeAutomationKeyframes.sort { $0.time < $1.time }
        }
    }

    func deleteTrackVolumeKeyframe(trackID: UUID, keyframeID: UUID) {
        updateTrackAutomation(trackID, actionName: "Delete Track Volume Keyframe") { $0.volumeAutomationKeyframes.removeAll { $0.id == keyframeID } }
    }

    func clearTrackVolumeAutomation(trackID: UUID) {
        updateTrackAutomation(trackID, actionName: "Clear Track Volume Automation") { $0.volumeAutomationKeyframes.removeAll() }
    }

    private func updateTrackAutomation(_ trackID: UUID, actionName: String, _ body: (inout Track) -> Void) {
        guard let track = project.timeline.tracks.first(where: { $0.id == trackID }) else { return }
        guard !track.isLocked else { showLockedTrackError(); return }
        updateTrack(trackID, actionName: actionName, audioChanged: true, body)
    }

    func normalizeClip(clipID: UUID, targetPeakDB: Double, cancellationToken: ExportCancellationToken = ExportCancellationToken(), completion: @escaping (Result<Double, Error>) -> Void) {
        guard requireAllMediaOnline() else {
            completion(.failure(projectError(code: 56, message: L10n.tr("Relink missing media before editing this project."))))
            return
        }
        guard clipIsEditable(clipID), let location = locateClip(clipID) else {
            completion(.failure(projectError(code: 57, message: L10n.tr("Cannot normalize a clip on a locked or unavailable track."))))
            return
        }
        let clip = project.timeline.tracks[location.track].clips[location.clip]
        guard let asset = project.asset(id: clip.sourceAssetID), !asset.isMissing, let url = asset.audioSourceURL else {
            completion(.failure(projectError(code: 51, message: L10n.tr("Cannot normalize missing or unavailable media."))))
            return
        }
        let targetDB = min(0, max(-60, targetPeakDB))
        let projectGenerationAtStart = projectGeneration
        let analyzedSourcePath = url.standardizedFileURL.path
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let peak = try self.analyzePeak(for: clip, audioURL: url, cancellationToken: cancellationToken)
                guard peak > 0.000001 else {
                    throw self.projectError(code: 52, message: L10n.tr("Cannot normalize silent clip."))
                }
                let targetLinear = pow(10, targetDB / 20) // dBFS has no fader-style mute sentinel.
                let newGain = MixMath.clampClipGainLinear(targetLinear / peak)
                DispatchQueue.main.async {
                    guard !cancellationToken.isCancelled else { completion(.failure(CancellationError())); return }
                    guard self.requireAllMediaOnline() else {
                        completion(.failure(self.projectError(code: 56, message: L10n.tr("Relink missing media before editing this project."))))
                        return
                    }
                    guard self.projectGeneration == projectGenerationAtStart,
                          let current = self.locateClip(clipID) else {
                        completion(.failure(self.projectError(code: 58, message: L10n.tr("The project changed before normalization completed."))))
                        return
                    }
                    let currentClip = self.project.timeline.tracks[current.track].clips[current.clip]
                    let currentTrack = self.project.timeline.tracks[current.track]
                    let currentSourcePath = self.project.asset(id: currentClip.sourceAssetID)?.audioSourceURL?.standardizedFileURL.path
                    guard !currentTrack.isLocked,
                          currentClip.sourceAssetID == clip.sourceAssetID,
                          currentClip.sourceStart == clip.sourceStart,
                          currentClip.sourceEnd == clip.sourceEnd,
                          currentClip.gain == clip.gain,
                          currentSourcePath == analyzedSourcePath else {
                        completion(.failure(self.projectError(code: 58, message: L10n.tr("The clip changed before normalization completed."))))
                        return
                    }
                    self.registerUndo("Normalize Clip")
                    self.project.timeline.tracks[current.track].clips[current.clip].gain = newGain
                    self.notify(audioChanged: true)
                    completion(.success(MixMath.db(forLinearGain: newGain)))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func duplicateSelectedClip() {
        guard requireAllMediaOnline() else { return }
        let selected = selectedEditableClipLocations()
        guard !selected.isEmpty else { return }
        let originals = selected.map { (track: $0.track, clip: project.timeline.tracks[$0.track].clips[$0.clip]) }
        let originalIDs = Set(originals.map { $0.clip.id })
        let copiedCrossfades = crossfadesContained(in: originalIDs)
        let earliestStart = originals.map { $0.clip.timelineStart }.min() ?? 0
        let latestEnd = originals.map { $0.clip.timelineStart + $0.clip.duration }.max() ?? earliestStart
        let timelineOffset = max(0.05, latestEnd - earliestStart)
        guard TimelineViewState.isValidTimelineTime(latestEnd + timelineOffset) else { return }
        registerUndo(selected.count == 1 ? "Duplicate Clip" : "Duplicate Clips")
        var newIDs: Set<UUID> = []
        var copiedIDs: [UUID: UUID] = [:]
        for original in originals {
            let copy = copiedClip(from: original.clip, timelineOffset: timelineOffset)
            project.timeline.tracks[original.track].clips.append(copy)
            copiedIDs[original.clip.id] = copy.id
            newIDs.insert(copy.id)
        }
        appendCopiedCrossfades(copiedCrossfades, using: copiedIDs, timelineOffset: timelineOffset)
        sanitizeCrossfades()
        selectedClipIDs = newIDs
        project.recalculateDuration()
        notify(audioChanged: true)
    }

    func duplicateSelectionForDrag(anchorID: UUID) -> UUID? {
        guard requireAllMediaOnline() else { return nil }
        if !selectedClipIDs.contains(anchorID) {
            selectedClipIDs = [anchorID]
        }
        let selected = selectedEditableClipLocations()
        guard !selected.isEmpty else { return nil }
        registerUndo(selected.count == 1 ? "Option-Drag Duplicate" : "Option-Drag Duplicate Clips")
        let originals = selected.map { (track: $0.track, clip: project.timeline.tracks[$0.track].clips[$0.clip]) }
        let copiedCrossfades = crossfadesContained(in: Set(originals.map { $0.clip.id }))
        var newIDs: Set<UUID> = []
        var anchorCopyID: UUID?
        var copiedIDs: [UUID: UUID] = [:]
        for original in originals {
            let copy = copiedClip(from: original.clip)
            project.timeline.tracks[original.track].clips.append(copy)
            copiedIDs[original.clip.id] = copy.id
            newIDs.insert(copy.id)
            if original.clip.id == anchorID {
                anchorCopyID = copy.id
            }
        }
        appendCopiedCrossfades(copiedCrossfades, using: copiedIDs)
        sanitizeCrossfades()
        selectedClipIDs = newIDs
        project.recalculateDuration()
        notify(audioChanged: true)
        return anchorCopyID
    }

    func rippleDeleteSelectedClips() {
        guard requireAllMediaOnline() else { return }
        let selected = selectedEditableClipLocations()
        guard !selected.isEmpty else { return }
        registerUndo(selected.count == 1 ? "Ripple Delete Clip" : "Ripple Delete Clips")
        let selectedIDs = Set(selected.map { project.timeline.tracks[$0.track].clips[$0.clip].id })

        for trackIndex in project.timeline.tracks.indices where !project.timeline.tracks[trackIndex].isLocked {
            let rawIntervals = project.timeline.tracks[trackIndex].clips
                .filter { selectedIDs.contains($0.id) }
                .map { ($0.timelineStart, $0.timelineStart + $0.duration) }
                .sorted { $0.0 < $1.0 }

            guard !rawIntervals.isEmpty else { continue }
            var removedIntervals: [(TimeInterval, TimeInterval)] = []
            for interval in rawIntervals {
                if let last = removedIntervals.last, interval.0 <= last.1 {
                    removedIntervals[removedIntervals.count - 1] = (last.0, max(last.1, interval.1))
                } else {
                    removedIntervals.append(interval)
                }
            }
            project.timeline.tracks[trackIndex].clips.removeAll { selectedIDs.contains($0.id) }

            for clipIndex in project.timeline.tracks[trackIndex].clips.indices {
                let originalStart = project.timeline.tracks[trackIndex].clips[clipIndex].timelineStart
                let shift = removedIntervals.reduce(0.0) { total, interval in
                    originalStart >= interval.1 ? total + (interval.1 - interval.0) : total
                }
                project.timeline.tracks[trackIndex].clips[clipIndex].timelineStart = max(0, originalStart - shift)
            }
        }

        removeCrossfades(involving: selectedIDs)
        sanitizeCrossfades()
        selectedClipIDs.subtract(selectedIDs)
        project.recalculateDuration()
        notify(audioChanged: true)
    }

    func nudgeSelectedClip(by delta: TimeInterval) {
        moveSelectedClips(deltaTime: delta, trackDelta: 0, actionName: "Nudge Clip")
    }

    func relink(assetID: UUID, replacementURL: URL, allowingMetadataWarnings: Bool = false) -> RelinkResult {
        guard let index = project.assets.firstIndex(where: { $0.id == assetID }) else {
            return RelinkResult(accepted: false, reason: L10n.tr("Asset not found."), updatedAsset: nil)
        }
        let result = relinkService.verifyAndRelink(asset: project.assets[index], replacementURL: replacementURL, projectURL: projectURL)
        return applyRelinkResult(result, to: assetID, allowingMetadataWarnings: allowingMetadataWarnings)
    }

    /// Runs AVFoundation metadata and checksum inspection away from the AppKit event loop.
    /// The captured identity prevents a late verification result from modifying a different project
    /// or a media item that was relinked while work was in flight.
    func relinkAsync(
        assetID: UUID,
        replacementURL: URL,
        allowingMetadataWarnings: Bool = false,
        expectedReplacementChecksum: String? = nil,
        completion: @escaping (RelinkResult) -> Void
    ) {
        guard let asset = project.assets.first(where: { $0.id == assetID }) else {
            completion(RelinkResult(accepted: false, reason: L10n.tr("Asset not found."), updatedAsset: nil))
            return
        }
        let capturedProjectURL = projectURL
        let capturedProjectID = project.id
        let capturedGeneration = projectGeneration
        let expectedOriginalPath = asset.originalPath
        let service = relinkService

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = service.verifyAndRelink(
                asset: asset,
                replacementURL: replacementURL,
                projectURL: capturedProjectURL
            )
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.projectGeneration == capturedGeneration,
                      self.project.id == capturedProjectID,
                      let current = self.project.assets.first(where: { $0.id == assetID }),
                      current.originalPath == expectedOriginalPath else {
                    completion(RelinkResult(accepted: false, reason: L10n.tr("The project changed before media verification completed."), updatedAsset: nil))
                    return
                }
                if let expectedReplacementChecksum, result.updatedAsset?.metadata.checksum != expectedReplacementChecksum {
                    completion(RelinkResult(accepted: false, reason: L10n.tr("The replacement changed after review. Choose it again."), updatedAsset: nil))
                    return
                }
                completion(self.applyRelinkResult(result, to: assetID, allowingMetadataWarnings: allowingMetadataWarnings))
            }
        }
    }

    func locateMissingAssets(in folder: URL, completion: @escaping ([String]) -> Void) {
        let missingAssets = project.assets.filter { $0.isMissing }
        guard !missingAssets.isEmpty else {
            completion([])
            return
        }

        let projectURL = projectURL
        let generation = projectGeneration
        let projectID = project.id
        let service = relinkService
        DispatchQueue.global(qos: .userInitiated).async {
            let candidatesByName = Self.mediaFilesByName(in: folder)
            let attempts = missingAssets.map { asset -> FolderRelinkAttempt in
                let candidates = candidatesByName[asset.metadata.fileName] ?? []
                guard !candidates.isEmpty else {
                    return FolderRelinkAttempt(
                        assetID: asset.id,
                        expectedOriginalPath: asset.originalPath,
                        fileName: asset.metadata.fileName,
                        result: RelinkResult(accepted: false, reason: L10n.tr("not found"), updatedAsset: nil)
                    )
                }

                var latestResult = RelinkResult(accepted: false, reason: L10n.tr("No candidate matched closely enough."), updatedAsset: nil)
                for candidate in candidates {
                    let result = service.verifyAndRelink(asset: asset, replacementURL: candidate, projectURL: projectURL)
                    if result.isSafeForAutomaticRelink {
                        return FolderRelinkAttempt(
                            assetID: asset.id,
                            expectedOriginalPath: asset.originalPath,
                            fileName: asset.metadata.fileName,
                            result: result
                        )
                    }
                    latestResult = result
                }
                return FolderRelinkAttempt(
                    assetID: asset.id,
                    expectedOriginalPath: asset.originalPath,
                    fileName: asset.metadata.fileName,
                    result: latestResult
                )
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.projectGeneration == generation, self.project.id == projectID else {
                    completion([])
                    return
                }
                var messages: [String] = []
                for attempt in attempts {
                    guard let current = self.project.assets.first(where: { $0.id == attempt.assetID }) else {
                        messages.append(L10n.format("%@: removed before relinking", attempt.fileName))
                        continue
                    }
                    guard current.isMissing, current.originalPath == attempt.expectedOriginalPath else {
                        messages.append(L10n.format("%@: already resolved", attempt.fileName))
                        continue
                    }
                    guard attempt.result.isSafeForAutomaticRelink else {
                        if attempt.result.requiresConfirmation {
                            messages.append(L10n.format(
                                "%@: %@ (%@)",
                                attempt.fileName,
                                L10n.tr("candidate needs manual confirmation"),
                                attempt.result.warnings.joined(separator: L10n.tr(", "))
                            ))
                        } else {
                            messages.append(L10n.format("%@: %@", attempt.fileName, attempt.result.reason))
                        }
                        continue
                    }
                    let applied = self.applyRelinkResult(attempt.result, to: attempt.assetID)
                    messages.append(L10n.format("%@: %@", attempt.fileName, applied.reason))
                }
                completion(messages)
            }
        }
    }

    func regenerateWaveform(assetID: UUID) {
        guard let index = project.assets.firstIndex(where: { $0.id == assetID }) else { return }
        cancelWaveformGeneration(for: assetID)
        waveformService.invalidateCache(for: project.assets[index])
        waveformData.removeValue(forKey: assetID)
        project.assets[index].waveformFailureReason = nil
        guard !project.assets[index].isMissing else {
            project.assets[index].waveformStatus = .missing
            notify()
            return
        }
        if project.assets[index].requiresAudioPreparation && project.assets[index].proxyStatus != .ready {
            prepareAsset(assetID)
            return
        }
        project.assets[index].waveformStatus = .generating
        notify()
        startWaveformGeneration(for: assetID)
    }

    func regenerateAudioProxy(assetID: UUID) {
        guard let index = project.assets.firstIndex(where: { $0.id == assetID }), project.assets[index].requiresAudioPreparation else { return }
        cancelProxyGeneration(for: assetID)
        cancelWaveformGeneration(for: assetID)
        waveformService.invalidateCache(for: project.assets[index])
        proxyService.invalidateProxy(for: project.assets[index])
        waveformData.removeValue(forKey: assetID)
        project.assets[index].proxyPath = nil
        project.assets[index].proxyCacheKey = nil
        project.assets[index].proxyStatus = project.assets[index].isMissing ? .missing : .generating
        project.assets[index].waveformStatus = project.assets[index].isMissing ? .missing : .notGenerated
        project.assets[index].waveformFailureReason = nil
        notify()
        prepareAsset(assetID)
    }

    func cancelAudioProxyGeneration(assetID: UUID) {
        guard let index = project.assets.firstIndex(where: { $0.id == assetID }),
              project.assets[index].requiresAudioPreparation,
              proxyGenerationTasks[assetID] != nil else {
            return
        }
        cancelProxyGeneration(for: assetID)
        waveformData.removeValue(forKey: assetID)
        project.assets[index].proxyStatus = .failed
        project.assets[index].proxyFailureReason = MediaProxyService.ProxyGenerationError.cancelled.localizedDescription
        project.assets[index].waveformStatus = .notGenerated
        project.assets[index].waveformFailureReason = nil
        notify()
    }

    private func clampedTimelineZoom(_ zoom: Double) -> Double {
        TimelineViewState.clampedZoom(zoom)
    }

    func removeAssetIfUnused(assetID: UUID) {
        guard !project.timeline.tracks.contains(where: { track in track.clips.contains(where: { $0.sourceAssetID == assetID }) }) else {
            delegate?.projectController(self, didFailWith: NSError(domain: "LightAudio", code: 32, userInfo: [NSLocalizedDescriptionKey: L10n.tr("Remove clips that use this media before removing it from the project.")]))
            return
        }
        guard let index = project.assets.firstIndex(where: { $0.id == assetID }) else { return }
        registerUndo("Remove Media")
        sourceVerificationTasks.removeValue(forKey: assetID)?.cancel()
        cancelWaveformGeneration(for: assetID); cancelProxyGeneration(for: assetID)
        waveformData.removeValue(forKey: assetID)
        project.assets.remove(at: index)
        notify()
    }

    @discardableResult
    func removeUnusedMedia() -> Int {
        let used = usageCountsByAssetID()
        let unusedIDs = Set(project.assets.filter { used[$0.id, default: 0] == 0 }.map(\.id))
        guard !unusedIDs.isEmpty else { return 0 }
        registerUndo("Remove Unused Media")
        for id in unusedIDs {
            sourceVerificationTasks.removeValue(forKey: id)?.cancel()
            cancelWaveformGeneration(for: id); cancelProxyGeneration(for: id)
            waveformData.removeValue(forKey: id)
        }
        project.assets.removeAll { unusedIDs.contains($0.id) }
        notify()
        return unusedIDs.count
    }

    func renameMedia(assetID: UUID, name: String) {
        guard requireAllMediaOnline() else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, let index = project.assets.firstIndex(where: { $0.id == assetID }) else { return }
        registerUndo("Rename Media")
        project.assets[index].displayName = cleanName
        notify()
    }

    func usageCountsByAssetID() -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for track in project.timeline.tracks {
            for clip in track.clips {
                counts[clip.sourceAssetID, default: 0] += 1
            }
        }
        return counts
    }

    func regenerateAllWaveforms() {
        project.assets.map(\.id).forEach { regenerateWaveform(assetID: $0) }
    }

    func regenerateFailedWaveforms() {
        project.assets.filter { $0.waveformStatus == .failed }.map(\.id).forEach { regenerateWaveform(assetID: $0) }
    }

    func regenerateAllVideoProxies() {
        project.assets.filter { $0.requiresAudioPreparation }.map(\.id).forEach { regenerateAudioProxy(assetID: $0) }
    }

    func clearApplicationCaches(completion: @escaping (Result<ApplicationCacheClearResult, Error>) -> Void) {
        guard recoveryService.latestRecoverableSnapshot() == nil else {
            completion(.failure(projectError(code: 62, message: L10n.tr("Resolve the pending recovery before clearing caches."))))
            return
        }
        recoveryService.setSnapshotWritesSuspended(true)
        invalidateAssetPreparation()

        for index in project.assets.indices {
            if project.assets[index].isMissing {
                project.assets[index].waveformStatus = .missing
                if project.assets[index].requiresAudioPreparation {
                    project.assets[index].proxyStatus = .missing
                }
                continue
            }

            project.assets[index].waveformCacheKey = nil
            project.assets[index].waveformStatus = .notGenerated
            project.assets[index].waveformFailureReason = nil
            if project.assets[index].requiresAudioPreparation {
                project.assets[index].proxyPath = nil
                project.assets[index].proxyCacheKey = nil
                project.assets[index].proxyFailureReason = nil
                project.assets[index].proxyStatus = .generating
            }
        }
        notify()

        applicationCacheService.clearApplicationCaches { [weak self] result in
            guard let self = self else {
                completion(result)
                return
            }
            self.recoveryService.resumeSessionAfterRecoveryCacheClear()
            self.recoveryService.setSnapshotWritesSuspended(false)
            self.prepareAvailableAssets()
            completion(result)
        }
    }

    /// An independent document owns all library sources and starts a new editing history.
    func saveIndependentCopy(snapshot: ProjectMediaCollectionSnapshot, to folder: URL, name: String,
                             cancellation: ExportCancellationToken = ExportCancellationToken(),
                             progress: @escaping (Double) -> Void = { _ in }) throws -> URL {
        var copy = snapshot.project
        copy.id = UUID()
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.name.isEmpty else { throw projectError(code: 63, message: L10n.tr("Enter a project name.")) }
        return try collectProjectMedia(snapshot: .init(project: copy, projectURL: snapshot.projectURL),
                                       to: folder, videoAudioOnly: false, cancellation: cancellation, progress: progress)
    }

    func makeProjectMediaCollectionSnapshot() -> ProjectMediaCollectionSnapshot {
        ProjectMediaCollectionSnapshot(project: project, projectURL: projectURL)
    }

    func collectProjectMedia(to destinationFolder: URL, videoAudioOnly: Bool = true,
                             cancellation: ExportCancellationToken = ExportCancellationToken()) throws -> URL {
        try collectProjectMedia(snapshot: makeProjectMediaCollectionSnapshot(), to: destinationFolder,
                                videoAudioOnly: videoAudioOnly, cancellation: cancellation)
    }

    /// Collect the entire library from an immutable snapshot. Publish only a verified, complete
    /// folder; neither the live document nor the original media is modified by this operation.
    func collectProjectMedia(snapshot: ProjectMediaCollectionSnapshot, to destinationFolder: URL,
                             videoAudioOnly: Bool = true,
                             cancellation: ExportCancellationToken = ExportCancellationToken(),
                             progress: (Double) -> Void = { _ in }) throws -> URL {
        let manager = FileManager.default
        let resolver = FileReferenceResolver()
        let fileService = ProjectFileService()
        func checkCancellation() throws {
            if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        }
        func mediaChanged() -> Error {
            NSError(domain: "LightAudio", code: 21, userInfo: [NSLocalizedDescriptionKey:
                L10n.tr("Source media changed during verification. Try opening it again.")])
        }
        try checkCancellation()
        var project = snapshot.project
        let missing = try resolver.markMissingAssets(in: &project, projectURL: snapshot.projectURL, cancellation: cancellation)
        guard missing.isEmpty, !snapshot.project.hasMissingAssets else {
            let count = max(missing.count, snapshot.project.missingAssets.count)
            throw NSError(domain: "LightAudio", code: 41, userInfo: [NSLocalizedDescriptionKey:
                L10n.format(count == 1 ? "Cannot collect project: %d file is missing." : "Cannot collect project: %d files are missing.", count)])
        }
        try fileService.validateForRendering(project)
        // Full digests also protect old projects while a copy or decoder is in flight.
        var sourceDigests: [UUID: String] = [:]
        for asset in project.assets {
            let source = resolver.resolvedURL(for: asset, projectURL: snapshot.projectURL)
            let digest = try FileMetadataHasher.fullChecksum(for: source, cancellation: cancellation)
            if let expected = asset.metadata.checksum {
                let matches = expected.hasPrefix("sha256:") ? digest == expected
                    : try FileMetadataHasher.matches(expected, url: source, cancellation: cancellation)
                guard matches else { throw mediaChanged() }
            }
            sourceDigests[asset.id] = digest
        }
        let staging = destinationFolder.appendingPathComponent(".LightAudio-\(UUID().uuidString).partial", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let media = staging.appendingPathComponent("Media", isDirectory: true)
        try manager.createDirectory(at: media, withIntermediateDirectories: false)
        let document = staging.appendingPathComponent("\(safeFileName(project.name)).liau")
        var collected = project
        var names = Set<String>()
        for index in collected.assets.indices {
            try checkCancellation()
            let asset = project.assets[index]
            let source = resolver.resolvedURL(for: asset, projectURL: snapshot.projectURL)
            let audioOnly = videoAudioOnly && asset.kind == .videoAudio
            let name = audioOnly ? source.deletingPathExtension().lastPathComponent + ".caf" : source.lastPathComponent
            let destination = media.appendingPathComponent(uniqueFileName(for: name, usedNames: &names))
            if audioOnly {
                collected.assets[index].metadata = try MediaProxyService(proxyDirectory: media)
                    .exportLosslessAudio(from: source, to: destination, cancellation: cancellation)
                collected.assets[index].kind = .audio
            } else {
                // Chunked copying bounds memory and lets Cancel interrupt a large video copy.
                let input = try FileHandle(forReadingFrom: source)
                defer { try? input.close() }
                guard manager.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                let output = try FileHandle(forWritingTo: destination)
                defer { try? output.close() }
                while true {
                    let copied = try autoreleasepool { () throws -> Bool in
                        try checkCancellation()
                        let data = try FileMetadataHasher.readData(input)
                        if data.isEmpty { return false }
                        try FileMetadataHasher.writeData(data, to: output)
                        return true
                    }
                    if !copied { break }
                }
                try output.close()
                let digest = try FileMetadataHasher.fullChecksum(for: destination, cancellation: cancellation)
                guard digest == sourceDigests[asset.id] else { throw mediaChanged() }
                collected.assets[index].metadata.checksum = digest
                collected.assets[index].metadata.fileName = destination.lastPathComponent
            }
            guard try FileMetadataHasher.fullChecksum(for: source, cancellation: cancellation) == sourceDigests[asset.id] else { throw mediaChanged() }
            collected.assets[index].originalPath = destination.path
            collected.assets[index].resolvedPath = nil
            collected.assets[index].relativePath = resolver.relativePath(for: destination, projectURL: document)
            collected.assets[index].sourceModificationTimestamp = resolver.sourceModificationTimestamp(for: destination)
            collected.assets[index].isMissing = false
            collected.assets[index].proxyPath = nil
            collected.assets[index].proxyCacheKey = nil
            collected.assets[index].proxyStatus = .none
            collected.assets[index].proxyFailureReason = nil
            collected.assets[index].waveformCacheKey = nil
            collected.assets[index].waveformStatus = .notGenerated
            collected.assets[index].waveformFailureReason = nil
            progress(Double(index + 1) / Double(max(1, collected.assets.count)))
        }
        for asset in project.assets {
            let source = resolver.resolvedURL(for: asset, projectURL: snapshot.projectURL)
            guard try FileMetadataHasher.fullChecksum(for: source, cancellation: cancellation) == sourceDigests[asset.id] else { throw mediaChanged() }
        }
        try fileService.validateForRendering(collected)
        try checkCancellation()
        let package = uniqueFolderURL(in: destinationFolder, baseName: "\(project.name) Collected")
        let publishedDocument = package.appendingPathComponent(document.lastPathComponent)
        for index in collected.assets.indices {
            collected.assets[index].originalPath = package.appendingPathComponent(collected.assets[index].relativePath!).path
        }
        try fileService.save(collected, to: document)
        try checkCancellation()
        try manager.moveItem(at: staging, to: package)
        return publishedDocument
    }

    private func insertTrack(at index: Int, actionName: String) {
        guard requireAllMediaOnline() else { return }
        registerUndo(actionName)
        let insertionIndex = min(max(index, 0), project.timeline.tracks.count)
        project.timeline.tracks.insert(Track(name: nextTrackName()), at: insertionIndex)
        notify()
    }

    private func setTrackHeight(_ height: Double, actionName: String) {
        guard requireAllMediaOnline() else { return }
        let clamped = TimelineViewState.clampedTrackHeight(height)
        guard abs(project.viewState.trackHeight - clamped) > 0.1 else { return }
        registerUndo(actionName)
        project.viewState.trackHeight = clamped
        notify()
    }

    private func nextTrackName() -> String {
        let existing = Set(project.timeline.tracks.map(\.name))
        var index = project.timeline.tracks.count + 1
        while existing.contains("A\(index)") {
            index += 1
        }
        return "A\(index)"
    }

    private func uniqueFolderURL(in folder: URL, baseName: String) -> URL {
        let manager = FileManager.default
        var candidate = folder.appendingPathComponent(safeFileName(baseName), isDirectory: true)
        var suffix = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(safeFileName(baseName)) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private func uniqueFileName(for fileName: String, usedNames: inout Set<String>) -> String {
        let url = URL(fileURLWithPath: fileName)
        let base = safeFileName(url.deletingPathExtension().lastPathComponent)
        let ext = url.pathExtension
        var candidate = ext.isEmpty ? base : "\(base).\(ext)"
        var suffix = 2
        while usedNames.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            suffix += 1
        }
        usedNames.insert(candidate.lowercased())
        return candidate
    }

    private func safeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "LightAudio Project" : cleaned
    }

    private func existingAsset(for url: URL) -> MediaAsset? {
        let targetPath = normalizedPath(url)
        return project.assets.first {
            normalizedPath($0.resolvedURL ?? URL(fileURLWithPath: $0.originalPath)) == targetPath
        }
    }

    private func normalizedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func mediaFilesByName(in folder: URL) -> [String: [URL]] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var result: [String: [URL]] = [:]
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values?.isRegularFile == true,
                  AudioFormatHelpers.supportedImportExtension(url.pathExtension) else { continue }
            result[url.lastPathComponent, default: []].append(url)
        }
        return result
    }

    private func analyzePeak(for clip: Clip, audioURL: URL, cancellationToken: ExportCancellationToken) throws -> Double {
        let file = try AVAudioFile(forReading: audioURL)
        let sampleRate = file.processingFormat.sampleRate
        // Match the renderer's source bounds: include frames intersecting the
        // trimmed interval, snapping floating-point noise at exact boundaries.
        // Derive the exclusive end independently; truncating duration can lose
        // the last peak, and truncating sourceStart can include an earlier peak.
        let startFrame = min(file.length, max(0, AVAudioFramePosition(AudioFrameMath.floor(clip.sourceStart * sampleRate))))
        let endFrame = min(file.length, max(startFrame, AVAudioFramePosition(AudioFrameMath.ceiling(clip.sourceEnd * sampleRate))))
        var remaining = endFrame - startFrame
        guard clip.duration > 0, remaining > 0 else {
            throw projectError(code: 53, message: L10n.tr("The selected clip has no readable audio."))
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384) else {
            throw projectError(code: 54, message: L10n.tr("Could not allocate audio analysis buffer."))
        }
        file.framePosition = startFrame
        var peak = 0.0
        while remaining > 0 {
            if cancellationToken.isCancelled { throw CancellationError() }
            let frames = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
            try file.read(into: buffer, frameCount: frames)
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { break }
            guard let channels = buffer.floatChannelData else {
                throw projectError(code: 55, message: L10n.tr("Unsupported audio sample format."))
            }
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<frameCount {
                    if channels[channel][frame].isFinite { peak = max(peak, abs(Double(channels[channel][frame]))) }
                }
            }
            remaining -= AVAudioFramePosition(frameCount)
        }
        return peak
    }

    private func projectError(code: Int, message: String) -> NSError {
        NSError(domain: "LightAudio", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func updateClip(_ clipID: UUID, actionName: String, audioChanged: Bool = true, _ body: (inout Clip) -> Void) {
        guard requireAllMediaOnline() else { return }
        guard let location = locateClip(clipID) else { return }
        guard !project.timeline.tracks[location.track].isLocked else {
            showLockedTrackError()
            return
        }
        registerUndo(actionName)
        body(&project.timeline.tracks[location.track].clips[location.clip])
        project.recalculateDuration()
        notify(audioChanged: audioChanged)
    }

    private func updateSelectedClips(actionName: String, audioChanged: Bool = true, _ body: (inout Clip) -> Void) {
        guard requireAllMediaOnline() else { return }
        let ids = selectedEditableClipIDs()
        guard !ids.isEmpty else { return }
        registerUndo(actionName)
        for trackIndex in project.timeline.tracks.indices where !project.timeline.tracks[trackIndex].isLocked {
            for clipIndex in project.timeline.tracks[trackIndex].clips.indices where ids.contains(project.timeline.tracks[trackIndex].clips[clipIndex].id) {
                body(&project.timeline.tracks[trackIndex].clips[clipIndex])
            }
        }
        project.recalculateDuration()
        notify(audioChanged: audioChanged)
    }

    private func moveSelectedClips(deltaTime: TimeInterval, trackDelta: Int, actionName: String) {
        guard requireAllMediaOnline() else { return }
        let selected = selectedEditableClipLocations()
        guard !selected.isEmpty else { return }
        let minStart = selected.map { project.timeline.tracks[$0.track].clips[$0.clip].timelineStart }.min() ?? 0
        guard deltaTime.isFinite else { return }
        let maxEnd = selected.map { project.timeline.tracks[$0.track].clips[$0.clip].timelineStart + project.timeline.tracks[$0.track].clips[$0.clip].duration }.max() ?? 0
        let safeDelta = min(TimelineViewState.maximumTimelineTime - maxEnd, max(deltaTime, -minStart))
        let canMove = selected.allSatisfy { location in
            let targetTrack = location.track + trackDelta
            return targetTrack >= 0 && targetTrack < project.timeline.tracks.count && !project.timeline.tracks[targetTrack].isLocked
        }
        guard canMove else {
            showLockedTrackError()
            return
        }
        registerUndo(actionName)
        let movedIDs = Set(selected.map { project.timeline.tracks[$0.track].clips[$0.clip].id })
        if trackDelta == 0 {
            for location in selected {
                project.timeline.tracks[location.track].clips[location.clip].timelineStart = max(0, project.timeline.tracks[location.track].clips[location.clip].timelineStart + safeDelta)
            }
        } else {
            var moving: [(target: Int, clip: Clip)] = []
            for trackIndex in project.timeline.tracks.indices {
                project.timeline.tracks[trackIndex].clips.removeAll { clip in
                    if movedIDs.contains(clip.id) {
                        var moved = clip
                        moved.timelineStart = max(0, moved.timelineStart + safeDelta)
                        moving.append((trackIndex + trackDelta, moved))
                        return true
                    }
                    return false
                }
            }
            for item in moving {
                project.timeline.tracks[item.target].clips.append(item.clip)
            }
        }
        updateAutomaticCrossfadesIfNeeded(involving: movedIDs)
        sanitizeCrossfades()
        project.recalculateDuration()
        notify(audioChanged: true)
    }

    private func createCrossfade(between firstID: UUID, and secondID: UUID, curve: CrossfadeCurve, actionName: String?) -> Bool {
        guard let crossfade = crossfadeBetween(firstID, secondID, curve: curve),
              let firstLocation = locateClip(firstID),
              !project.timeline.tracks[firstLocation.track].isLocked else {
            return false
        }
        guard !crossfadeConflictsWithExisting(crossfade) else {
            return false
        }
        if let actionName = actionName {
            registerUndo(actionName)
        }
        if actionName != nil || !project.timeline.crossfades.contains(where: { sameClipPair($0, crossfade) && $0.isPartial }) {
            upsertCrossfade(crossfade)
        }
        sanitizeCrossfades()
        notify(audioChanged: true)
        return true
    }

    private func crossfadeBetween(_ firstID: UUID, _ secondID: UUID, curve: CrossfadeCurve) -> Crossfade? {
        guard firstID != secondID,
              let firstLocation = locateClip(firstID),
              let secondLocation = locateClip(secondID),
              firstLocation.track == secondLocation.track else {
            return nil
        }
        let first = project.timeline.tracks[firstLocation.track].clips[firstLocation.clip]
        let second = project.timeline.tracks[secondLocation.track].clips[secondLocation.clip]
        let overlapStart = max(first.timelineStart, second.timelineStart)
        let overlapEnd = min(first.timelineStart + first.duration, second.timelineStart + second.duration)
        guard overlapEnd > overlapStart + 0.001 else { return nil }

        let leading = first.timelineStart <= second.timelineStart ? first : second
        let trailing = leading.id == first.id ? second : first
        return Crossfade(
            leadingClipID: leading.id,
            trailingClipID: trailing.id,
            startTime: overlapStart,
            duration: overlapEnd - overlapStart,
            curve: curve
        )
    }

    private func upsertCrossfade(_ crossfade: Crossfade) {
        if let index = project.timeline.crossfades.firstIndex(where: { sameClipPair($0, crossfade) }) {
            var replacement = crossfade
            replacement.id = project.timeline.crossfades[index].id
            project.timeline.crossfades[index] = replacement
        } else {
            project.timeline.crossfades.append(crossfade)
        }
    }

    private func bestOverlappingClipID(for clipID: UUID) -> UUID? {
        guard let location = locateClip(clipID) else { return nil }
        let clip = project.timeline.tracks[location.track].clips[location.clip]
        let clipStart = clip.timelineStart
        let clipEnd = clip.timelineStart + clip.duration
        return project.timeline.tracks[location.track].clips
            .filter { other in
                guard other.id != clipID else { return false }
                return min(clipEnd, other.timelineStart + other.duration) > max(clipStart, other.timelineStart) + 0.001
            }
            .max { left, right in
                let leftOverlap = min(clipEnd, left.timelineStart + left.duration) - max(clipStart, left.timelineStart)
                let rightOverlap = min(clipEnd, right.timelineStart + right.duration) - max(clipStart, right.timelineStart)
                return leftOverlap < rightOverlap
            }?
            .id
    }

    @discardableResult
    private func sanitizeCrossfades() -> Bool {
        var candidates: [Crossfade] = []
        var seenPairs = Set<String>()
        for crossfade in project.timeline.crossfades {
            let adjusted: Crossfade
            if crossfade.isPartial {
                guard crossfade.leadingClipID != crossfade.trailingClipID,
                      let leading = locateClip(crossfade.leadingClipID), let trailing = locateClip(crossfade.trailingClipID),
                      leading.track == trailing.track else { continue }
                let first = project.timeline.tracks[leading.track].clips[leading.clip]
                let second = project.timeline.tracks[trailing.track].clips[trailing.clip]
                let start = max(first.timelineStart, second.timelineStart)
                let end = min(first.timelineStart + first.duration, second.timelineStart + second.duration)
                guard end > start else { continue }
                var partial = crossfade
                partial.startTime = start; partial.duration = end - start
                adjusted = partial // Keep roles: a split can put the outgoing half after the incoming clip.
            } else {
                guard let full = crossfadeBetween(crossfade.leadingClipID, crossfade.trailingClipID, curve: crossfade.curve) else { continue }
                adjusted = full
            }
            let key = pairKey(adjusted.leadingClipID, adjusted.trailingClipID)
            guard !seenPairs.contains(key) else { continue }
            seenPairs.insert(key)
            var preserved = adjusted
            preserved.id = crossfade.id
            candidates.append(preserved)
        }

        // A clip may participate in separate crossfades at different times, but never two
        // simultaneous ones. Otherwise equal-power envelopes would be multiplied together.
        var sanitized: [Crossfade] = []
        for candidate in candidates.sorted(by: { lhs, rhs in
            if abs(lhs.startTime - rhs.startTime) > 0.0001 {
                return lhs.startTime < rhs.startTime
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }) {
            guard !sanitized.contains(where: { crossfadesConflict(candidate, $0) }) else { continue }
            sanitized.append(candidate)
        }
        let changed = sanitized != project.timeline.crossfades
        project.timeline.crossfades = sanitized.sorted { $0.startTime < $1.startTime }
        return changed
    }

    private func crossfadeConflictsWithExisting(_ candidate: Crossfade) -> Bool {
        project.timeline.crossfades.contains { existing in
            guard !sameClipPair(existing, candidate) else { return false }
            return crossfadesConflict(existing, candidate)
        }
    }

    private func crossfadesConflict(_ first: Crossfade, _ second: Crossfade) -> Bool {
        let sharesClip = first.leadingClipID == second.leadingClipID ||
            first.leadingClipID == second.trailingClipID ||
            first.trailingClipID == second.leadingClipID ||
            first.trailingClipID == second.trailingClipID
        guard sharesClip else { return false }
        let overlapStart = max(first.startTime, second.startTime)
        let overlapEnd = min(first.startTime + first.duration, second.startTime + second.duration)
        return overlapEnd > overlapStart + 0.0001
    }

    private func updateAutomaticCrossfadesIfNeeded(involving clipIDs: Set<UUID>) {
        guard EditorPreferences.automaticallyCreateCrossfades else { return }
        for clipID in clipIDs {
            guard let location = locateClip(clipID), !project.timeline.tracks[location.track].isLocked else { continue }
            let clip = project.timeline.tracks[location.track].clips[location.clip]
            for other in project.timeline.tracks[location.track].clips where other.id != clipID {
                let overlapStart = max(clip.timelineStart, other.timelineStart)
                let overlapEnd = min(clip.timelineStart + clip.duration, other.timelineStart + other.duration)
                guard overlapEnd > overlapStart + 0.001 else { continue }
                _ = createCrossfade(between: clipID, and: other.id, curve: .equalPower, actionName: nil)
            }
        }
    }

    private func removeCrossfades(involving clipIDs: Set<UUID>) {
        project.timeline.crossfades.removeAll {
            clipIDs.contains($0.leadingClipID) || clipIDs.contains($0.trailingClipID)
        }
    }

    private func sameClipPair(_ left: Crossfade, _ right: Crossfade) -> Bool {
        pairKey(left.leadingClipID, left.trailingClipID) == pairKey(right.leadingClipID, right.trailingClipID)
    }

    private func pairKey(_ first: UUID, _ second: UUID) -> String {
        [first.uuidString, second.uuidString].sorted().joined(separator: ":")
    }

    private func copiedClip(from original: Clip, timelineOffset: TimeInterval = 0) -> Clip {
        var copy = original
        copy.id = UUID()
        copy.timelineStart = max(0, copy.timelineStart + timelineOffset)
        copy.volumeAutomationKeyframes = copy.volumeAutomationKeyframes.map { keyframe in
            var copiedKeyframe = keyframe
            copiedKeyframe.id = UUID()
            return copiedKeyframe
        }
        copy.panAutomationKeyframes = copy.panAutomationKeyframes.map { keyframe in
            var copiedKeyframe = keyframe
            copiedKeyframe.id = UUID()
            return copiedKeyframe
        }
        copy.effects = copy.effects.map { effect in
            var copiedEffect = effect
            copiedEffect.id = UUID()
            return copiedEffect
        }
        return copy
    }

    private func crossfadesContained(in clipIDs: Set<UUID>) -> [Crossfade] {
        project.timeline.crossfades.filter {
            clipIDs.contains($0.leadingClipID) && clipIDs.contains($0.trailingClipID)
        }
    }

    private func appendCopiedCrossfades(
        _ sourceCrossfades: [Crossfade],
        using copiedIDs: [UUID: UUID],
        timelineOffset: TimeInterval = 0
    ) {
        for crossfade in sourceCrossfades {
            guard let leadingID = copiedIDs[crossfade.leadingClipID],
                  let trailingID = copiedIDs[crossfade.trailingClipID] else {
                continue
            }
            project.timeline.crossfades.append(
                Crossfade(
                    leadingClipID: leadingID,
                    trailingClipID: trailingID,
                    startTime: max(0, crossfade.startTime + timelineOffset),
                    duration: crossfade.duration,
                    curve: crossfade.curve,
                    startProgress: crossfade.startProgress,
                    endProgress: crossfade.endProgress
                )
            )
        }
    }

    private func selectedClipLocations() -> [(track: Int, clip: Int)] {
        var result: [(track: Int, clip: Int)] = []
        for trackIndex in project.timeline.tracks.indices {
            for clipIndex in project.timeline.tracks[trackIndex].clips.indices where selectedClipIDs.contains(project.timeline.tracks[trackIndex].clips[clipIndex].id) {
                result.append((trackIndex, clipIndex))
            }
        }
        return result
    }

    private func selectedEditableClipLocations() -> [(track: Int, clip: Int)] {
        selectedClipLocations().filter { !project.timeline.tracks[$0.track].isLocked }
    }

    private func selectedEditableClipIDs() -> Set<UUID> {
        Set(selectedEditableClipLocations().map { project.timeline.tracks[$0.track].clips[$0.clip].id })
    }

    private func startSourceVerifications() {
        for asset in project.assets where asset.isVerifyingSource && sourceVerificationTasks[asset.id] == nil {
            let url = resolver.resolvedURL(for: asset, projectURL: projectURL)
            let generation = projectGeneration, expected = asset.metadata.checksum
            let token = ExportCancellationToken()
            sourceVerificationTasks[asset.id] = token
            sourceVerificationQueue.async { [weak self] in
                let result = Result { try FileMetadataHasher.verifiedFullChecksum(for: url, cancellation: token) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, !token.isCancelled, self.projectGeneration == generation,
                          self.sourceVerificationTasks[asset.id] === token else { return }
                    self.sourceVerificationTasks.removeValue(forKey: asset.id)
                    guard let index = self.project.assets.firstIndex(where: { $0.id == asset.id }),
                          self.project.assets[index].metadata.checksum == expected,
                          self.resolver.resolvedURL(for: self.project.assets[index], projectURL: self.projectURL) == url else { return }
                    switch result {
                    case .success:
                        _ = self.refreshMediaAvailability()
                        let current = self.project.assets[index]
                        if current.isMissing && !current.isVerifyingSource {
                            self.delegate?.projectController(self, didFindMissingAssets: [current])
                        }
                    case .failure(let error):
                        self.project.assets[index].isVerifyingSource = false
                        self.project.assets[index].isMissing = true
                        self.notify()
                        self.delegate?.projectController(self, didFailWith: error)
                    }
                }
            }
        }
    }

    private func cancelWaveformGeneration(for assetID: UUID) {
        waveformJobs.removeValue(forKey: assetID)?.cancel()
        waveformGenerationIDs.remove(assetID)
    }

    private func enforceWaveformBudget() {
        let total = waveformData.values.reduce(0) { $0 + $1.peaks.count }
        let budget = 24 * 1024 * 1024 / MemoryLayout<WaveformPeak>.stride
        guard total > budget else { return }
        let perAsset = max(1, budget / max(1, waveformData.count))
        for id in Array(waveformData.keys) {
            guard var data = waveformData[id], data.peaks.count > perAsset else { continue }
            let groupSize = Int(ceil(Double(data.peaks.count) / Double(perAsset)))
            var peaks: [WaveformPeak] = []
            for start in stride(from: 0, to: data.peaks.count, by: groupSize) {
                let group = data.peaks[start..<min(start + groupSize, data.peaks.count)]
                peaks.append(WaveformPeak(min: group.map(\.min).min() ?? 0, max: group.map(\.max).max() ?? 0))
            }
            data.peaks = peaks
            waveformData[id] = data
        }
    }

    private func prepareAvailableAssets() {
        _ = refreshMediaAvailability()
        for asset in project.assets where !asset.isMissing {
            prepareAsset(asset.id)
        }
    }

    private func prepareAsset(_ assetID: UUID) {
        guard let asset = project.assets.first(where: { $0.id == assetID }) else { return }
        if asset.requiresAudioPreparation {
            startProxyGeneration(for: assetID)
        } else {
            startWaveformGeneration(for: assetID)
        }
    }

    private func invalidateAssetPreparation() {
        mediaCacheGeneration &+= 1
        waveformData.removeAll()
        waveformJobs.values.forEach { $0.cancel() }; waveformJobs.removeAll()
        waveformGenerationIDs.removeAll()
        let tasks = Array(proxyGenerationTasks.values)
        proxyGenerationTasks.removeAll()
        proxyGenerationRequestIDs.removeAll()
        tasks.forEach { $0.cancel() }
    }

    private func cancelProxyGeneration(for assetID: UUID) {
        proxyGenerationRequestIDs.removeValue(forKey: assetID)
        let task = proxyGenerationTasks.removeValue(forKey: assetID)
        task?.cancel()
    }

    private func resetTransientProjectState() {
        sourceVerificationTasks.values.forEach { $0.cancel() }; sourceVerificationTasks.removeAll()
        projectGeneration &+= 1
        importingMediaPaths.removeAll()
        clipClipboard = nil
        continuousUndoSession = nil
        continuousEditMediaAvailability = nil
        invalidateAssetPreparation()
    }

    @discardableResult
    private func applyRelinkResult(_ result: RelinkResult, to assetID: UUID, allowingMetadataWarnings: Bool = false) -> RelinkResult {
        guard let index = project.assets.firstIndex(where: { $0.id == assetID }),
              let updatedAsset = result.updatedAsset,
              result.accepted else {
            return result
        }
        var candidate = project
        candidate.assets[index] = updatedAsset
        do { try fileService.validateForRendering(candidate) }
        catch { return RelinkResult(accepted: false, reason: error.localizedDescription, updatedAsset: nil) }
        guard allowingMetadataWarnings || !result.requiresConfirmation else {
            return result
        }

        registerUndo("Relink Media")
        sourceVerificationTasks.removeValue(forKey: assetID)?.cancel()
        cancelProxyGeneration(for: assetID)
        waveformGenerationIDs.remove(assetID)
        cancelWaveformGeneration(for: assetID)
        waveformData.removeValue(forKey: assetID)
        var updated = updatedAsset
        updated.waveformStatus = updated.requiresAudioPreparation ? .notGenerated : .generating
        updated.waveformFailureReason = nil
        updated.proxyStatus = updated.requiresAudioPreparation ? .generating : .none
        project.assets[index] = updated
        notify(audioChanged: true)
        prepareAsset(updated.id)
        return result
    }

    private func startProxyGeneration(for assetID: UUID) {
        guard let index = project.assets.firstIndex(where: { $0.id == assetID }) else { return }
        var asset = project.assets[index]
        guard !asset.isMissing else {
            project.assets[index].proxyStatus = .missing
            project.assets[index].waveformStatus = .missing
            notify()
            return
        }
        guard asset.requiresAudioPreparation else {
            startWaveformGeneration(for: assetID)
            return
        }
        guard proxyGenerationTasks[assetID] == nil else { return }

        asset.proxyStatus = .generating
        asset.proxyFailureReason = nil
        asset.waveformFailureReason = nil
        project.assets[index] = asset
        notify()

        let cacheGeneration = mediaCacheGeneration
        let requestID = UUID()

        let task = proxyService.prepareProxy(for: asset) { [weak self] result in
            guard let self = self else { return }
            guard cacheGeneration == self.mediaCacheGeneration else { return }
            guard self.proxyGenerationRequestIDs[assetID] == requestID else { return }
            self.proxyGenerationRequestIDs.removeValue(forKey: assetID)
            self.proxyGenerationTasks.removeValue(forKey: assetID)
            guard let currentIndex = self.project.assets.firstIndex(where: { $0.id == assetID }) else { return }
            guard !self.project.assets[currentIndex].isMissing else {
                self.project.assets[currentIndex].proxyStatus = .missing
                self.project.assets[currentIndex].waveformStatus = .missing
                self.waveformData.removeValue(forKey: assetID)
                self.notify()
                return
            }
            switch result {
            case .success(let updated):
                self.project.assets[currentIndex].metadata = updated.metadata
                self.project.assets[currentIndex].proxyPath = updated.proxyPath
                self.project.assets[currentIndex].proxyCacheKey = updated.proxyCacheKey
                self.project.assets[currentIndex].proxyStatus = .ready
                self.project.assets[currentIndex].proxyFailureReason = nil
                self.project.assets[currentIndex].waveformStatus = .generating
                self.project.assets[currentIndex].waveformFailureReason = nil
                self.notify()
                self.startWaveformGeneration(for: assetID)
            case .failure(let error):
                self.project.assets[currentIndex].proxyStatus = .failed
                self.project.assets[currentIndex].proxyFailureReason = error.localizedDescription
                self.project.assets[currentIndex].waveformStatus = .failed
                self.project.assets[currentIndex].waveformFailureReason = L10n.format("Audio proxy generation failed: %@", error.localizedDescription)
                self.waveformData.removeValue(forKey: assetID)
                self.notify()
            }
        }
        proxyGenerationRequestIDs[assetID] = requestID
        proxyGenerationTasks[assetID] = task
    }

    private func startWaveformGeneration(for assetID: UUID) {
        guard let index = project.assets.firstIndex(where: { $0.id == assetID }) else { return }
        var asset = project.assets[index]
        guard !asset.isMissing else {
            project.assets[index].waveformStatus = .missing
            notify()
            return
        }
        guard !asset.requiresAudioPreparation || asset.proxyStatus == .ready else { return }
        guard !waveformGenerationIDs.contains(assetID) else { return }

        asset.waveformStatus = .generating
        asset.waveformFailureReason = nil
        project.assets[index] = asset
        notify()
        waveformGenerationIDs.insert(assetID)

        let cacheGeneration = mediaCacheGeneration
        waveformJobs[assetID] = waveformService.loadOrGenerateWaveform(for: asset) { [weak self] result in
            guard let self = self else { return }
            guard cacheGeneration == self.mediaCacheGeneration else { return }
            self.waveformJobs.removeValue(forKey: assetID)
            self.waveformGenerationIDs.remove(assetID)
            guard let currentIndex = self.project.assets.firstIndex(where: { $0.id == assetID }) else { return }
            guard !self.project.assets[currentIndex].isMissing else {
                self.waveformData.removeValue(forKey: assetID)
                self.project.assets[currentIndex].waveformStatus = .missing
                self.notify()
                return
            }
            switch result {
            case .success(let data):
                self.waveformData[assetID] = data
                self.enforceWaveformBudget()
                self.project.assets[currentIndex].waveformCacheKey = data.cacheKey
                self.project.assets[currentIndex].waveformStatus = .ready
                self.project.assets[currentIndex].waveformFailureReason = nil
            case .failure(let error):
                self.waveformData.removeValue(forKey: assetID)
                self.project.assets[currentIndex].waveformStatus = .failed
                self.project.assets[currentIndex].waveformFailureReason = error.localizedDescription
            }
            self.notify()
        }
    }

    private func updateTrack(_ trackID: UUID, actionName: String, audioChanged: Bool = false, _ body: (inout Track) -> Void) {
        guard requireAllMediaOnline() else { return }
        guard let index = project.timeline.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        registerUndo(actionName)
        body(&project.timeline.tracks[index])
        notify(audioChanged: audioChanged)
    }

    private func clipIsEditable(_ clipID: UUID) -> Bool {
        guard let location = locateClip(clipID) else { return false }
        guard !project.timeline.tracks[location.track].isLocked else {
            showLockedTrackError()
            return false
        }
        return true
    }

    private func showLockedTrackError() {
        let error = NSError(
            domain: "LightAudio",
            code: 22,
            userInfo: [NSLocalizedDescriptionKey: L10n.tr("Unlock the track before editing clips on it.")]
        )
        delegate?.projectController(self, didFailWith: error)
    }

    private func requireAllMediaOnline() -> Bool {
        if let availability = continuousEditMediaAvailability {
            return availability
        }
        return validateAllMediaOnline()
    }

    private func validateAllMediaOnline() -> Bool {
        let missingAssets = refreshMediaAvailability()
        if missingAssets.contains(where: { $0.isVerifyingSource }) {
            delegate?.projectController(self, didFailWith: NSError(domain: "LightAudio", code: 21, userInfo: [NSLocalizedDescriptionKey: L10n.tr("Source verification is in progress. Try again when it finishes.")]))
            return false
        }
        guard missingAssets.isEmpty else {
            let names = missingAssets.map { $0.metadata.fileName }.joined(separator: "\n")
            let error = NSError(
                domain: "LightAudio",
                code: 21,
                userInfo: [NSLocalizedDescriptionKey: L10n.format("Relink missing media before editing this project:\n%@", names)]
            )
            delegate?.projectController(self, didFailWith: error)
            return false
        }
        return true
    }

    private func locateClip(_ id: UUID) -> (track: Int, clip: Int)? {
        for trackIndex in project.timeline.tracks.indices {
            if let clipIndex = project.timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == id }) {
                return (trackIndex, clipIndex)
            }
        }
        return nil
    }

    private func splitVolumeAutomation(
        _ keyframes: [ClipVolumeAutomationKeyframe],
        at offset: TimeInterval,
        leftDuration: TimeInterval,
        rightDuration: TimeInterval,
        valueAtSplit: Double
    ) -> (left: [ClipVolumeAutomationKeyframe], right: [ClipVolumeAutomationKeyframe]) {
        guard !keyframes.isEmpty else { return ([], []) }
        let epsilon = 0.000_001
        var left = keyframes.filter { $0.time <= offset + epsilon }
        if !left.contains(where: { abs($0.time - offset) <= epsilon }) {
            left.append(ClipVolumeAutomationKeyframe(time: offset, gainDB: valueAtSplit))
        }

        var right = keyframes
            .filter { $0.time >= offset - epsilon }
            .map { ClipVolumeAutomationKeyframe(id: UUID(), time: max(0, $0.time - offset), gainDB: $0.gainDB) }
        if !right.contains(where: { abs($0.time) <= epsilon }) {
            right.append(ClipVolumeAutomationKeyframe(time: 0, gainDB: valueAtSplit))
        }

        return (
            left.map { $0.clamped(maxTime: leftDuration) }.sorted { $0.time < $1.time },
            right.map { $0.clamped(maxTime: rightDuration) }.sorted { $0.time < $1.time }
        )
    }

    private func splitPanAutomation(
        _ keyframes: [ClipPanAutomationKeyframe],
        at offset: TimeInterval,
        leftDuration: TimeInterval,
        rightDuration: TimeInterval,
        valueAtSplit: Double
    ) -> (left: [ClipPanAutomationKeyframe], right: [ClipPanAutomationKeyframe]) {
        guard !keyframes.isEmpty else { return ([], []) }
        let epsilon = 0.000_001
        var left = keyframes.filter { $0.time <= offset + epsilon }
        if !left.contains(where: { abs($0.time - offset) <= epsilon }) {
            left.append(ClipPanAutomationKeyframe(time: offset, pan: valueAtSplit))
        }

        var right = keyframes
            .filter { $0.time >= offset - epsilon }
            .map { ClipPanAutomationKeyframe(id: UUID(), time: max(0, $0.time - offset), pan: $0.pan) }
        if !right.contains(where: { abs($0.time) <= epsilon }) {
            right.append(ClipPanAutomationKeyframe(time: 0, pan: valueAtSplit))
        }

        return (
            left.map { $0.clamped(maxTime: leftDuration) }.sorted { $0.time < $1.time },
            right.map { $0.clamped(maxTime: rightDuration) }.sorted { $0.time < $1.time }
        )
    }

    private func registerUndo(_ name: String) {
        if var session = continuousUndoSession {
            guard !session.hasRegisteredUndo else { return }
            session.hasRegisteredUndo = true
            continuousUndoSession = session
            registerUndoSnapshot(session.actionName)
            return
        }
        registerUndoSnapshot(name)
    }

    private func registerUndoSnapshot(_ name: String) {
        let oldProject = project
        let oldSelected = selectedClipIDs
        let oldPlayhead = playheadTime
        isDirty = true
        guard let undoManager = undoManagerProvider() else { return }
        let ownsGroup = !undoManager.groupsByEvent && undoManager.groupingLevel == 0
        if ownsGroup { undoManager.beginUndoGrouping() }
        defer { if ownsGroup { undoManager.endUndoGrouping() } }
        undoManager.registerUndo(withTarget: self) { target in
            target.registerUndo(name)
            target.project = oldProject
            target.selectedClipIDs = oldSelected
            target.playheadTime = oldPlayhead
            target.updateDirtyStateFromSaveCheckpoint()
            target.recoveryService.updateProjectURL(target.projectURL)
            target.resetTransientProjectState()
            target.notify(audioChanged: true)
            target.prepareAvailableAssets()
        }
        undoManager.setActionName(L10n.tr(name))
    }

    private func captureSaveCheckpoint() {
        savedEditableFingerprint = editableProjectFingerprint(project)
        savedProjectURLPath = normalizedProjectURLPath(projectURL)
        // Encoding should not fail for a valid project, but a failed checkpoint must never
        // make unsaved work appear clean.
        isDirty = savedEditableFingerprint == nil
    }

    private func clearSaveCheckpoint() {
        savedEditableFingerprint = nil
        savedProjectURLPath = nil
    }

    private func updateDirtyStateFromSaveCheckpoint() {
        guard let savedEditableFingerprint,
              normalizedProjectURLPath(projectURL) == savedProjectURLPath,
              let currentFingerprint = editableProjectFingerprint(project) else {
            isDirty = true
            return
        }
        isDirty = currentFingerprint != savedEditableFingerprint
    }

    private func editableProjectFingerprint(_ value: Project) -> Data? {
        ProjectFileService.editableProjectFingerprint(value)
    }

    private func normalizedProjectURLPath(_ url: URL?) -> String? {
        url?.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func notify(audioChanged: Bool = false) {
        if audioChanged {
            audioRenderRevision &+= 1
        }
        delegate?.projectDidChange(project)
    }
}
