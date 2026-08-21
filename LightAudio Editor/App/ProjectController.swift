import AppKit
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
    private var proxyGenerationTasks: [UUID: MediaProxyService.ProxyGenerationHandle] = [:]
    private var proxyGenerationRequestIDs: [UUID: UUID] = [:]
    private var mediaCacheGeneration = 0
    private var projectGeneration = 0
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
        let previouslyMissingIDs = Set(project.missingAssets.map(\.id))
        let missing = resolver.markMissingAssets(in: &project, projectURL: projectURL)
        let currentlyMissingIDs = Set(project.missingAssets.map(\.id))

        guard previouslyMissingIDs != currentlyMissingIDs else { return missing }

        for id in currentlyMissingIDs {
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
        undoManagerProvider: @escaping () -> UndoManager? = { NSApp.mainWindow?.undoManager }
    ) {
        self.recoveryService = recoveryService
        self.proxyService = proxyService
        self.undoManagerProvider = undoManagerProvider
        recoveryService.projectProvider = { [weak self] in self?.project }
        recoveryService.isDirtyProvider = { [weak self] in self?.isDirty ?? false }
        recoveryService.start(projectURL: nil)
        captureSaveCheckpoint()
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

    func open(url: URL) {
        do {
            let (loaded, missing) = try fileService.load(from: url)
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
            if !missing.isEmpty {
                delegate?.projectController(self, didFindMissingAssets: missing)
            }
        } catch {
            delegate?.projectController(self, didFailWith: error)
        }
    }

    func restore(snapshot: ProjectRecoverySnapshot) {
        do {
            var recoveredProject = snapshot.project
            let missing = try fileService.prepareForOpening(&recoveredProject, projectURL: snapshot.originalProjectURL)
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
            if !missing.isEmpty {
                delegate?.projectController(self, didFindMissingAssets: missing)
            }
        } catch {
            delegate?.projectController(self, didFailWith: error)
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
            let error = NSError(domain: "LightAudio", code: 33, userInfo: [NSLocalizedDescriptionKey: "Missing media must be relinked before importing new media."])
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
                if let existing = self.existingAsset(for: url) {
                    completion?(.duplicate(existing))
                    return
                }
                self.registerUndo("Import Media")
                var asset = asset
                asset.waveformStatus = asset.kind == .videoAudio ? .notGenerated : .generating
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
            proxyIsPreparing: asset.kind == .videoAudio && asset.proxyStatus != .ready
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
                curve: crossfade.curve
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
            delegate?.projectController(self, didFailWith: NSError(domain: "LightAudio", code: 31, userInfo: [NSLocalizedDescriptionKey: "Only empty tracks can be deleted without confirmation."]))
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
        guard requireAllMediaOnline() else { return }
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
        guard requireAllMediaOnline() else { return }
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
        let value = max(0, time ?? playheadTime)
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
        let value = max(0, time ?? playheadTime)
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

    func trimClip(_ clipID: UUID, edge: TimelineView.TrimEdge, to timelineTime: TimeInterval) {
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

        // The new split boundary must not inherit the source clip's outer-edge fades.
        clip.fadeIn = Fade(duration: min(originalFadeIn.duration, clip.duration), curve: originalFadeIn.curve)
        clip.fadeOut = Fade()
        right.fadeIn = Fade()
        right.fadeOut = Fade(duration: min(originalFadeOut.duration, right.duration), curve: originalFadeOut.curve)

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
        removeCrossfades(involving: [clip.id])
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
            clip.fadeIn.duration = min(max(0, duration), clip.duration)
        }
    }

    func setClipFadeOut(_ duration: TimeInterval) {
        guard requireAllMediaOnline() else { return }
        updateSelectedClips(actionName: "Fade Out") { clip in
            clip.fadeOut.duration = min(max(0, duration), clip.duration)
        }
    }

    func setClipFade(clipID: UUID, edge: TimelineView.TrimEdge, duration: TimeInterval) {
        guard requireAllMediaOnline() else { return }
        updateClip(clipID, actionName: edge == .left ? "Fade In" : "Fade Out") { clip in
            switch edge {
            case .left:
                clip.fadeIn.duration = min(max(0, duration), clip.duration)
            case .right:
                clip.fadeOut.duration = min(max(0, duration), clip.duration)
            }
        }
    }

    func setClipFadeCurve(edge: TimelineView.TrimEdge, curve: FadeCurve) {
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

    func setClipFadeCurve(clipID: UUID, edge: TimelineView.TrimEdge, curve: FadeCurve) {
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

    func applyFadeToSelected(edge: TimelineView.TrimEdge, duration: TimeInterval, curve: FadeCurve) {
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

    func normalizeClip(clipID: UUID, targetPeakDB: Double, completion: @escaping (Result<Double, Error>) -> Void) {
        guard requireAllMediaOnline() else {
            completion(.failure(projectError(code: 56, message: "Relink missing media before editing this project.")))
            return
        }
        guard clipIsEditable(clipID), let location = locateClip(clipID) else {
            completion(.failure(projectError(code: 57, message: "Cannot normalize a clip on a locked or unavailable track.")))
            return
        }
        let clip = project.timeline.tracks[location.track].clips[location.clip]
        guard let asset = project.asset(id: clip.sourceAssetID), !asset.isMissing, let url = asset.audioSourceURL else {
            completion(.failure(projectError(code: 51, message: "Cannot normalize missing or unavailable media.")))
            return
        }
        let targetDB = min(0, max(-60, targetPeakDB))
        let projectGenerationAtStart = projectGeneration
        let analyzedSourcePath = url.standardizedFileURL.path
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let peak = try self.analyzePeak(for: clip, audioURL: url)
                guard peak > 0.000001 else {
                    throw self.projectError(code: 52, message: "Cannot normalize silent clip.")
                }
                let targetLinear = MixMath.linearGain(forDB: targetDB)
                let newGain = MixMath.clampClipGainLinear(targetLinear / peak)
                DispatchQueue.main.async {
                    guard self.requireAllMediaOnline() else {
                        completion(.failure(self.projectError(code: 56, message: "Relink missing media before editing this project.")))
                        return
                    }
                    guard self.projectGeneration == projectGenerationAtStart,
                          let current = self.locateClip(clipID) else {
                        completion(.failure(self.projectError(code: 58, message: "The project changed before normalization completed.")))
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
                        completion(.failure(self.projectError(code: 58, message: "The clip changed before normalization completed.")))
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
        registerUndo(selected.count == 1 ? "Duplicate Clip" : "Duplicate Clips")
        let originals = selected.map { (track: $0.track, clip: project.timeline.tracks[$0.track].clips[$0.clip]) }
        let originalIDs = Set(originals.map { $0.clip.id })
        let copiedCrossfades = crossfadesContained(in: originalIDs)
        let earliestStart = originals.map { $0.clip.timelineStart }.min() ?? 0
        let latestEnd = originals.map { $0.clip.timelineStart + $0.clip.duration }.max() ?? earliestStart
        let timelineOffset = max(0.05, latestEnd - earliestStart)
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
            return RelinkResult(accepted: false, reason: "Asset not found.", updatedAsset: nil)
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
        completion: @escaping (RelinkResult) -> Void
    ) {
        guard let asset = project.assets.first(where: { $0.id == assetID }) else {
            completion(RelinkResult(accepted: false, reason: "Asset not found.", updatedAsset: nil))
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
                    completion(RelinkResult(accepted: false, reason: "The project changed before media verification completed.", updatedAsset: nil))
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
                        result: RelinkResult(accepted: false, reason: "not found", updatedAsset: nil)
                    )
                }

                var latestResult = RelinkResult(accepted: false, reason: "No candidate matched closely enough.", updatedAsset: nil)
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
                        messages.append("\(attempt.fileName): removed before relinking")
                        continue
                    }
                    guard current.isMissing, current.originalPath == attempt.expectedOriginalPath else {
                        messages.append("\(attempt.fileName): already resolved")
                        continue
                    }
                    guard attempt.result.isSafeForAutomaticRelink else {
                        if attempt.result.requiresConfirmation {
                            messages.append("\(attempt.fileName): candidate needs manual confirmation (\(attempt.result.warnings.joined(separator: ", ")))")
                        } else {
                            messages.append("\(attempt.fileName): \(attempt.result.reason)")
                        }
                        continue
                    }
                    let applied = self.applyRelinkResult(attempt.result, to: attempt.assetID)
                    messages.append("\(attempt.fileName): \(applied.reason)")
                }
                completion(messages)
            }
        }
    }

    func regenerateWaveform(assetID: UUID) {
        guard let index = project.assets.firstIndex(where: { $0.id == assetID }) else { return }
        waveformService.invalidateCache(for: project.assets[index])
        waveformData.removeValue(forKey: assetID)
        project.assets[index].waveformFailureReason = nil
        guard !project.assets[index].isMissing else {
            project.assets[index].waveformStatus = .missing
            notify()
            return
        }
        if project.assets[index].kind == .videoAudio && project.assets[index].proxyStatus != .ready {
            prepareAsset(assetID)
            return
        }
        project.assets[index].waveformStatus = .generating
        notify()
        startWaveformGeneration(for: assetID)
    }

    func regenerateAudioProxy(assetID: UUID) {
        guard let index = project.assets.firstIndex(where: { $0.id == assetID }), project.assets[index].kind == .videoAudio else { return }
        cancelProxyGeneration(for: assetID)
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
              project.assets[index].kind == .videoAudio,
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
        guard requireAllMediaOnline() else { return }
        guard !project.timeline.tracks.contains(where: { track in track.clips.contains(where: { $0.sourceAssetID == assetID }) }) else {
            delegate?.projectController(self, didFailWith: NSError(domain: "LightAudio", code: 32, userInfo: [NSLocalizedDescriptionKey: "Remove clips that use this media before removing it from the project."]))
            return
        }
        guard let index = project.assets.firstIndex(where: { $0.id == assetID }) else { return }
        registerUndo("Remove Media")
        project.assets.remove(at: index)
        notify()
    }

    @discardableResult
    func removeUnusedMedia() -> Int {
        guard requireAllMediaOnline() else { return 0 }
        let used = usageCountsByAssetID()
        let unusedIDs = Set(project.assets.filter { used[$0.id, default: 0] == 0 }.map(\.id))
        guard !unusedIDs.isEmpty else { return 0 }
        registerUndo("Remove Unused Media")
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
        project.assets.filter { $0.kind == .videoAudio }.map(\.id).forEach { regenerateAudioProxy(assetID: $0) }
    }

    func clearApplicationCaches(completion: @escaping (Result<ApplicationCacheClearResult, Error>) -> Void) {
        recoveryService.setSnapshotWritesSuspended(true)
        invalidateAssetPreparation()

        for index in project.assets.indices {
            if project.assets[index].isMissing {
                project.assets[index].waveformStatus = .missing
                if project.assets[index].kind == .videoAudio {
                    project.assets[index].proxyStatus = .missing
                }
                continue
            }

            project.assets[index].waveformCacheKey = nil
            project.assets[index].waveformStatus = .notGenerated
            project.assets[index].waveformFailureReason = nil
            if project.assets[index].kind == .videoAudio {
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

    func makeProjectMediaCollectionSnapshot() -> ProjectMediaCollectionSnapshot {
        ProjectMediaCollectionSnapshot(project: project, projectURL: projectURL)
    }

    func collectProjectMedia(to destinationFolder: URL) throws -> URL {
        try collectProjectMedia(snapshot: makeProjectMediaCollectionSnapshot(), to: destinationFolder)
    }

    /// This method deliberately uses an immutable project snapshot so collection cannot observe
    /// a half-edited project while media files are being copied on a background queue.
    func collectProjectMedia(snapshot: ProjectMediaCollectionSnapshot, to destinationFolder: URL) throws -> URL {
        let project = snapshot.project
        let projectURL = snapshot.projectURL
        let usedIDs = Set(project.timeline.tracks.flatMap { $0.clips.map(\.sourceAssetID) })
        let usedAssets = project.assets.filter { usedIDs.contains($0.id) }
        let missing = usedAssets.filter { $0.isMissing || !FileManager.default.fileExists(atPath: resolver.resolvedURL(for: $0, projectURL: projectURL).path) }
        guard missing.isEmpty else {
            throw NSError(
                domain: "LightAudio",
                code: 41,
                userInfo: [NSLocalizedDescriptionKey: "Cannot collect project: \(missing.count) file\(missing.count == 1 ? "" : "s") are missing."]
            )
        }

        let manager = FileManager.default
        let packageURL = uniqueFolderURL(in: destinationFolder, baseName: "\(project.name) Collected")
        let mediaURL = packageURL.appendingPathComponent("Media", isDirectory: true)
        try manager.createDirectory(at: mediaURL, withIntermediateDirectories: true)

        var copiedPathsByAssetID: [UUID: URL] = [:]
        var usedFileNames = Set<String>()
        for asset in usedAssets {
            let sourceURL = resolver.resolvedURL(for: asset, projectURL: projectURL)
            let targetName = uniqueFileName(for: sourceURL.lastPathComponent, usedNames: &usedFileNames)
            let targetURL = mediaURL.appendingPathComponent(targetName)
            try manager.copyItem(at: sourceURL, to: targetURL)
            copiedPathsByAssetID[asset.id] = targetURL
        }

        var collectedProject = project
        let projectFileURL = packageURL.appendingPathComponent("\(safeFileName(project.name)).liau")
        collectedProject.assets.removeAll { !usedIDs.contains($0.id) }
        for index in collectedProject.assets.indices {
            guard let copiedURL = copiedPathsByAssetID[collectedProject.assets[index].id] else { continue }
            collectedProject.assets[index].originalPath = copiedURL.path
            collectedProject.assets[index].resolvedPath = copiedURL.path
            collectedProject.assets[index].relativePath = resolver.relativePath(for: copiedURL, projectURL: projectFileURL)
            collectedProject.assets[index].sourceModificationTimestamp = resolver.sourceModificationTimestamp(for: copiedURL)
            collectedProject.assets[index].isMissing = false
            collectedProject.assets[index].proxyPath = nil
            collectedProject.assets[index].proxyCacheKey = nil
            collectedProject.assets[index].proxyStatus = collectedProject.assets[index].kind == .videoAudio ? .generating : .none
            collectedProject.assets[index].waveformCacheKey = nil
            collectedProject.assets[index].waveformStatus = .notGenerated
            collectedProject.assets[index].waveformFailureReason = nil
        }
        try fileService.save(collectedProject, to: projectFileURL)
        return projectFileURL
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
        while usedNames.contains(candidate) {
            candidate = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            suffix += 1
        }
        usedNames.insert(candidate)
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
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
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
            guard values?.isRegularFile == true else { continue }
            result[url.lastPathComponent, default: []].append(url)
        }
        return result
    }

    private func analyzePeak(for clip: Clip, audioURL: URL) throws -> Double {
        let file = try AVAudioFile(forReading: audioURL)
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = max(0, AVAudioFramePosition(clip.sourceStart * sampleRate))
        let requestedFrames = max(0, AVAudioFramePosition(clip.duration * sampleRate))
        let availableFrames = max(0, file.length - startFrame)
        var remaining = min(requestedFrames, availableFrames)
        guard remaining > 0 else {
            throw projectError(code: 53, message: "The selected clip has no readable audio.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384) else {
            throw projectError(code: 54, message: "Could not allocate audio analysis buffer.")
        }
        file.framePosition = startFrame
        var peak = 0.0
        while remaining > 0 {
            let frames = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
            try file.read(into: buffer, frameCount: frames)
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { break }
            guard let channels = buffer.floatChannelData else {
                throw projectError(code: 55, message: "Unsupported audio sample format.")
            }
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<frameCount {
                    peak = max(peak, abs(Double(channels[channel][frame])))
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
        let safeDelta = max(deltaTime, -minStart)
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
        upsertCrossfade(crossfade)
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
            guard let adjusted = crossfadeBetween(crossfade.leadingClipID, crossfade.trailingClipID, curve: crossfade.curve) else {
                continue
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
                    curve: crossfade.curve
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

    private func prepareAvailableAssets() {
        for asset in project.assets where !asset.isMissing {
            prepareAsset(asset.id)
        }
    }

    private func prepareAsset(_ assetID: UUID) {
        guard let asset = project.assets.first(where: { $0.id == assetID }) else { return }
        if asset.kind == .videoAudio {
            startProxyGeneration(for: assetID)
        } else {
            startWaveformGeneration(for: assetID)
        }
    }

    private func invalidateAssetPreparation() {
        mediaCacheGeneration &+= 1
        waveformData.removeAll()
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
        guard allowingMetadataWarnings || !result.requiresConfirmation else {
            return result
        }

        registerUndo("Relink Media")
        var updated = updatedAsset
        updated.waveformStatus = updated.kind == .videoAudio ? .notGenerated : .generating
        updated.waveformFailureReason = nil
        updated.proxyStatus = updated.kind == .videoAudio ? .generating : .none
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
        guard asset.kind == .videoAudio else {
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
                self.project.assets[currentIndex].waveformFailureReason = "Audio proxy generation failed: \(error.localizedDescription)"
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
        guard asset.kind != .videoAudio || asset.proxyStatus == .ready else { return }
        guard !waveformGenerationIDs.contains(assetID) else { return }

        asset.waveformStatus = .generating
        asset.waveformFailureReason = nil
        project.assets[index] = asset
        notify()
        waveformGenerationIDs.insert(assetID)

        let cacheGeneration = mediaCacheGeneration
        waveformService.loadOrGenerateWaveform(for: asset) { [weak self] result in
            guard let self = self else { return }
            guard cacheGeneration == self.mediaCacheGeneration else { return }
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
            userInfo: [NSLocalizedDescriptionKey: "Unlock the track before editing clips on it."]
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
        guard missingAssets.isEmpty else {
            let names = missingAssets.map { $0.metadata.fileName }.joined(separator: "\n")
            let error = NSError(
                domain: "LightAudio",
                code: 21,
                userInfo: [NSLocalizedDescriptionKey: "Relink missing media before editing this project:\n\(names)"]
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
        undoManager.setActionName(name)
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
        var copy = value
        copy.lastSavedAt = nil
        copy.viewState.zoom = TimelineViewState.defaultZoom
        copy.viewState.horizontalScroll = 0
        for index in copy.assets.indices {
            copy.assets[index].resolvedPath = nil
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
