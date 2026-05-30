import AppKit

final class MainWindowController: NSWindowController, ProjectControllerDelegate, NSWindowDelegate {
    private let projectController: ProjectController
    private let playbackEngine = AudioPlaybackEngine()
    private let exportService = ExportService()

    private let mediaBin = MediaBinViewController()
    private let timelineView = TimelineView()
    private let inspector = InspectorViewController()
    private let timeLabel = NSTextField(string: "00:00:00.000")
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let masterVolumeSlider = NSSlider(value: 0, minValue: -60, maxValue: 6, target: nil, action: nil)
    private let masterVolumeLabel = NSTextField(labelWithString: "0 dB")
    private let masterMeterView = LevelMeterView()
    private let clipIndicator = NSButton(title: "CLIP", target: nil, action: nil)
    private var playbackTimer: Timer?
    private var exportProgressController: ExportProgressController?
    private var displayedTrackLevels: [UUID: Double] = [:]
    private var displayedMasterLevel: Double = 0
    private var clippingActive = false
    private weak var mainSplitView: NSSplitView?
    private weak var timelineInspectorSplitView: NSSplitView?
    private weak var timelineScrollView: NSScrollView?
    private var regeneratingWaveformIDs: Set<UUID> = []
    private var regeneratingProxyIDs: Set<UUID> = []

    init(projectController: ProjectController) {
        self.projectController = projectController
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "LightAudio Editor"
        window.minSize = NSSize(width: 920, height: 560)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        projectController.delegate = self
        setupUI()
        projectDidChange(projectController.project)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func windowDidLoad() {
        super.windowDidLoad()
    }

    private func setupUI() {
        guard let window = window else { return }
        window.contentView = buildRootView()
        window.toolbar = buildToolbar()
        window.makeFirstResponder(timelineView)
        DispatchQueue.main.async { [weak self] in
            self?.resetWindowLayout(nil)
        }

        mediaBin.onAddAsset = { [weak self] id in self?.projectController.addAssetToTimeline(id) }
        mediaBin.onImportRequested = { [weak self] in self?.importMediaToLibrary() }
        mediaBin.onImportFolderRequested = { [weak self] in self?.importMediaFolderToLibrary() }
        mediaBin.onImportURLs = { [weak self] urls in self?.importDroppedMedia(urls) }
        mediaBin.onRelinkAsset = { [weak self] id in self?.chooseRelinkFile(assetID: id) }
        mediaBin.onRenameAsset = { [weak self] id in self?.renameMedia(assetID: id) }
        mediaBin.onRegenerateWaveform = { [weak self] id in
            self?.regeneratingWaveformIDs.insert(id)
            self?.projectController.regenerateWaveform(assetID: id)
            self?.showStatus("Regenerating waveform...")
        }
        mediaBin.onRegenerateProxy = { [weak self] id in
            self?.regeneratingProxyIDs.insert(id)
            self?.regeneratingWaveformIDs.insert(id)
            self?.projectController.regenerateAudioProxy(assetID: id)
            self?.showStatus("Regenerating audio proxy...")
        }
        mediaBin.onRemoveAsset = { [weak self] id in
            guard let self = self else { return }
            let isUsed = self.projectController.project.timeline.tracks.contains { track in
                track.clips.contains { $0.sourceAssetID == id }
            }
            if isUsed {
                self.showStatus("Cannot remove media that is used by timeline clips")
            }
            self.projectController.removeAssetIfUnused(assetID: id)
            if !isUsed {
                self.showStatus("Removed unused media")
            }
        }
        mediaBin.onShowInfo = { [weak self] id in self?.showMediaInfo(assetID: id) }
        inspector.onGainChanged = { [weak self] gain in self?.projectController.setClipGain(gain) }
        inspector.onPanChanged = { [weak self] pan in self?.projectController.setClipPan(pan) }
        inspector.onFadeInChanged = { [weak self] duration in self?.projectController.setClipFadeIn(duration) }
        inspector.onFadeOutChanged = { [weak self] duration in self?.projectController.setClipFadeOut(duration) }
        inspector.onFadeInCurveChanged = { [weak self] curve in
            self?.projectController.setClipFadeCurve(edge: .left, curve: curve)
            self?.showStatus("Fade in curve: \(curve.displayName)")
        }
        inspector.onFadeOutCurveChanged = { [weak self] curve in
            self?.projectController.setClipFadeCurve(edge: .right, curve: curve)
            self?.showStatus("Fade out curve: \(curve.displayName)")
        }
        inspector.onNameChanged = { [weak self] name in self?.projectController.renameSelectedClip(name) }
        inspector.onColorChanged = { [weak self] color in self?.projectController.setSelectedClipColor(color) }
        inspector.onAddVolumeKeyframe = { [weak self] in
            self?.projectController.addVolumeKeyframeToSelectedClip()
            self?.showStatus("Added volume keyframe")
        }
        inspector.onClearVolumeAutomation = { [weak self] in
            self?.projectController.clearSelectedClipVolumeAutomation()
            self?.showStatus("Cleared volume automation")
        }
        inspector.onNormalizeClip = { [weak self] in
            guard let id = self?.projectController.selectedClipID else { return }
            self?.normalizeClip(clipID: id)
        }
        timelineView.onSelectClip = { [weak self] id in self?.projectController.selectClip(id) }
        timelineView.onSelectClipWithModifiers = { [weak self] id, toggling, extending in self?.projectController.selectClip(id, toggling: toggling, extending: extending) }
        timelineView.onSelectClips = { [weak self] ids, adding in self?.projectController.selectClips(ids, adding: adding) }
        timelineView.onMoveClip = { [weak self] id, time, trackIndex in self?.projectController.moveClip(id, to: time, trackIndex: trackIndex) }
        timelineView.onTrimClip = { [weak self] id, edge, time in self?.projectController.trimClip(id, edge: edge, to: time) }
        timelineView.onSetClipFade = { [weak self] id, edge, duration in
            self?.projectController.setClipFade(clipID: id, edge: edge, duration: duration)
            self?.showStatus("\(edge == .left ? "Fade in" : "Fade out"): \(String(format: "%.2fs", duration))")
        }
        timelineView.onSplitClip = { [weak self] id, time in self?.projectController.splitClip(id, at: time) }
        timelineView.onSetPlayhead = { [weak self] time in
            self?.seekPlayback(to: time)
        }
        timelineView.onToggleTrackMute = { [weak self] id in self?.projectController.toggleMute(trackID: id) }
        timelineView.onToggleTrackSolo = { [weak self] id in self?.projectController.toggleSolo(trackID: id) }
        timelineView.onToggleTrackLock = { [weak self] id in self?.projectController.toggleLock(trackID: id) }
        timelineView.onSetTrackVolume = { [weak self] id, volumeDB in
            self?.projectController.setTrackVolume(trackID: id, volumeDB: volumeDB)
            self?.showStatus("Track volume changed")
        }
        timelineView.onSetTrackPan = { [weak self] id, pan in
            self?.projectController.setTrackPan(trackID: id, pan: pan)
            self?.showStatus("Track pan changed")
        }
        timelineView.onRenameTrack = { [weak self] id in self?.renameTrack(trackID: id) }
        timelineView.onAddTrack = { [weak self] in self?.projectController.addTrack() }
        timelineView.onAddTrackAbove = { [weak self] id in
            self?.projectController.addTrack(above: id)
            self?.showStatus("Added track above")
        }
        timelineView.onAddTrackBelow = { [weak self] id in
            self?.projectController.addTrack(below: id)
            self?.showStatus("Added track below")
        }
        timelineView.onDuplicateTrack = { [weak self] id in
            self?.projectController.duplicateTrack(id)
            self?.showStatus("Duplicated track")
        }
        timelineView.onToggleTrackCollapse = { [weak self] id in
            self?.projectController.toggleTrackCollapsed(trackID: id)
        }
        timelineView.onResetTrackHeight = { [weak self] in
            self?.projectController.resetTrackHeight()
            self?.showStatus("Track height reset")
        }
        timelineView.onReorderTrack = { [weak self] id, index in
            self?.projectController.moveTrack(id, to: index)
            self?.showStatus("Track reordered")
        }
        timelineView.onDropAsset = { [weak self] id, time, trackIndex in
            guard let self = self,
                  let result = self.projectController.addAssetToTimeline(id, at: time, trackIndex: trackIndex) else { return }
            self.showStatus(self.statusMessage(for: result))
        }
        timelineView.onAddMarker = { [weak self] in self?.projectController.addMarkerAtPlayhead() }
        timelineView.onDeleteMarker = { [weak self] id in self?.projectController.deleteMarker(id) }
        timelineView.onRenameMarker = { [weak self] id in self?.renameMarker(markerID: id) }
        timelineView.onRenameClip = { [weak self] id in self?.renameClip(clipID: id) }
        timelineView.onSetClipColor = { [weak self] id, color in
            self?.projectController.setClipColor(id, color: color)
            self?.showStatus("Clip color changed")
        }
        timelineView.onSetClipFadeCurve = { [weak self] id, edge, curve in
            self?.projectController.setClipFadeCurve(clipID: id, edge: edge, curve: curve)
            self?.showStatus("\(edge == .left ? "Fade in" : "Fade out") curve: \(curve.displayName)")
        }
        timelineView.onCreateCrossfade = { [weak self] id in
            guard let self = self else { return }
            if self.projectController.createCrossfade(involving: id) {
                self.showStatus("Created crossfade")
            } else {
                self.showStatus("Select two overlapping clips on the same track to create a crossfade.")
            }
        }
        timelineView.onSetCrossfadeCurve = { [weak self] id, curve in
            self?.projectController.setCrossfadeCurve(involving: id, curve: curve)
            self?.showStatus("Crossfade curve: \(curve.displayName)")
        }
        timelineView.onRemoveCrossfades = { [weak self] id in
            self?.projectController.removeCrossfades(involving: id)
            self?.showStatus("Removed crossfades")
        }
        timelineView.onAddVolumeKeyframe = { [weak self] id, time, gainDB in
            self?.projectController.addVolumeKeyframe(clipID: id, time: time, gainDB: gainDB)
            self?.showStatus("Added volume keyframe")
        }
        timelineView.onAddVolumeKeyframeAtPlayhead = { [weak self] id in
            self?.projectController.addVolumeKeyframeAtPlayhead(clipID: id)
            self?.showStatus("Added volume keyframe")
        }
        timelineView.onMoveVolumeKeyframe = { [weak self] id, keyframeID, time, gainDB in
            self?.projectController.moveVolumeKeyframe(clipID: id, keyframeID: keyframeID, time: time, gainDB: gainDB)
        }
        timelineView.onDeleteVolumeKeyframe = { [weak self] id, keyframeID in
            self?.projectController.deleteVolumeKeyframe(clipID: id, keyframeID: keyframeID)
            self?.showStatus("Deleted volume keyframe")
        }
        timelineView.onClearVolumeAutomation = { [weak self] id in
            self?.projectController.clearVolumeAutomation(clipID: id)
            self?.showStatus("Cleared volume automation")
        }
        timelineView.onNormalizeClip = { [weak self] id in
            self?.normalizeClip(clipID: id)
        }
        timelineView.onCopy = { [weak self] in self?.projectController.copySelectedClips() }
        timelineView.onCut = { [weak self] in self?.projectController.cutSelectedClips() }
        timelineView.onDuplicate = { [weak self] in self?.projectController.duplicateSelectedClip() }
        timelineView.onDuplicateSelectionForDrag = { [weak self] id in self?.projectController.duplicateSelectionForDrag(anchorID: id) }
        timelineView.onDelete = { [weak self] in self?.projectController.deleteSelectedClip() }
        timelineView.onDeleteTrack = { [weak self] id in self?.deleteTrackWithConfirmation(trackID: id) }
        timelineView.onRippleDelete = { [weak self] in self?.projectController.rippleDeleteSelectedClips() }
        timelineView.onStatusMessage = { [weak self] message in self?.showStatus(message) }
        timeLabel.target = self
        timeLabel.action = #selector(timeFieldChanged)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timeLabel.alignment = .right
        timeLabel.widthAnchor.constraint(equalToConstant: 102).isActive = true
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        masterVolumeSlider.target = self
        masterVolumeSlider.action = #selector(masterVolumeChanged)
        masterVolumeSlider.widthAnchor.constraint(equalToConstant: 96).isActive = true
        masterVolumeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        masterVolumeLabel.alignment = .right
        masterVolumeLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        masterMeterView.widthAnchor.constraint(equalToConstant: 78).isActive = true
        masterMeterView.heightAnchor.constraint(equalToConstant: 12).isActive = true
        clipIndicator.target = self
        clipIndicator.action = #selector(clearClippingIndicator)
        clipIndicator.isBordered = false
        clipIndicator.font = .systemFont(ofSize: 10, weight: .bold)
        clipIndicator.contentTintColor = .secondaryLabelColor
    }

    private func buildRootView() -> NSView {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        mainSplitView = split

        let left = NSView()
        let leftTitle = NSTextField(labelWithString: "Media")
        leftTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        leftTitle.translatesAutoresizingMaskIntoConstraints = false
        mediaBin.view.translatesAutoresizingMaskIntoConstraints = false
        left.addSubview(leftTitle)
        left.addSubview(mediaBin.view)
        NSLayoutConstraint.activate([
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),
            left.widthAnchor.constraint(lessThanOrEqualToConstant: 290),
            leftTitle.topAnchor.constraint(equalTo: left.topAnchor, constant: 10),
            leftTitle.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 12),
            mediaBin.view.topAnchor.constraint(equalTo: leftTitle.bottomAnchor, constant: 8),
            mediaBin.view.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            mediaBin.view.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            mediaBin.view.bottomAnchor.constraint(equalTo: left.bottomAnchor)
        ])

        let rightSplit = NSSplitView()
        rightSplit.isVertical = false
        rightSplit.dividerStyle = .thin
        timelineInspectorSplitView = rightSplit

        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        timelineView.frame = NSRect(x: 0, y: 0, width: 2200, height: 520)
        scroll.documentView = timelineView
        timelineScrollView = scroll

        rightSplit.addArrangedSubview(scroll)
        rightSplit.addArrangedSubview(inspector.view)

        split.addArrangedSubview(left)
        split.addArrangedSubview(rightSplit)

        let root = NSView()
        split.translatesAutoresizingMaskIntoConstraints = false
        let statusBar = NSView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(statusLabel)
        let masterLabel = NSTextField(labelWithString: "Master")
        masterLabel.font = .systemFont(ofSize: 11, weight: .medium)
        let masterStack = NSStackView(views: [masterLabel, masterVolumeSlider, masterVolumeLabel, masterMeterView, clipIndicator])
        masterStack.orientation = .horizontal
        masterStack.alignment = .centerY
        masterStack.spacing = 8
        masterStack.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(masterStack)
        root.addSubview(split)
        root.addSubview(statusBar)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: masterStack.leadingAnchor, constant: -12),
            masterStack.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            masterStack.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -10)
        ])
        return root
    }

    private func buildToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "mainToolbar")
        toolbar.displayMode = .iconAndLabel
        toolbar.delegate = self
        return toolbar
    }

    func projectDidChange(_ project: Project) {
        let usageCounts = projectController.usageCountsByAssetID()
        mediaBin.usageCounts = usageCounts
        mediaBin.usedAssetIDs = Set(usageCounts.filter { $0.value > 0 }.map(\.key))
        mediaBin.assets = project.assets
        timelineView.project = project
        timelineView.waveforms = projectController.waveforms
        timelineView.selectedClipIDs = projectController.selectedClipIDs
        timelineView.selectedClipID = projectController.selectedClipID
        timelineView.playheadTime = projectController.playheadTime
        timelineView.trackLevels = displayedTrackLevels
        inspector.update(project: project, selectedClipIDs: projectController.selectedClipIDs)
        timeLabel.stringValue = Timecode.string(projectController.playheadTime)
        masterVolumeSlider.doubleValue = project.mixState.masterVolumeDB
        masterVolumeLabel.stringValue = String(format: "%.0f dB", project.mixState.masterVolumeDB)
        updateRegenerationStatus(for: project)
        updateWindowTitle()
        updateToolbarLabels()
        resizeTimeline(for: project)
    }

    private func updateRegenerationStatus(for project: Project) {
        let proxyReady = regeneratingProxyIDs.filter { project.asset(id: $0)?.proxyStatus == .ready }
        if !proxyReady.isEmpty {
            regeneratingProxyIDs.subtract(proxyReady)
            showStatus("Audio proxy regenerated")
        }

        let waveformReady = regeneratingWaveformIDs.filter { project.asset(id: $0)?.waveformStatus == .ready }
        if !waveformReady.isEmpty {
            regeneratingWaveformIDs.subtract(waveformReady)
            showStatus("Waveform regenerated")
        }

        let waveformFailed = regeneratingWaveformIDs.filter { project.asset(id: $0)?.waveformStatus == .failed }
        if !waveformFailed.isEmpty {
            regeneratingWaveformIDs.subtract(waveformFailed)
            showStatus("Waveform generation failed")
        }

        let proxyFailed = regeneratingProxyIDs.filter { project.asset(id: $0)?.proxyStatus == .failed }
        if !proxyFailed.isEmpty {
            regeneratingProxyIDs.subtract(proxyFailed)
            showStatus("Audio proxy regeneration failed")
        }
    }

    private func statusMessage(for result: TimelinePlacementResult) -> String {
        var parts: [String] = []
        if result.createdTrackNames.count == 1, let name = result.createdTrackNames.first {
            parts.append("Added track \(name)")
        } else if let first = result.createdTrackNames.first, let last = result.createdTrackNames.last {
            parts.append("Added tracks \(first)-\(last)")
        }
        parts.append("Added clip to \(result.targetTrackName)")
        if result.wasTrackClamped {
            parts.append("track target limited")
        }
        if result.mediaWasMissing {
            parts.append("media placed offline")
        }
        if result.proxyIsPreparing {
            parts.append("preparing audio proxy")
        }
        return parts.joined(separator: "; ")
    }

    func projectController(_ controller: ProjectController, didFindMissingAssets assets: [MediaAsset]) {
        MissingMediaDialogController.show(missing: assets, window: window) { [weak self] action in
            switch action {
            case .relinkFirst(let id):
                self?.chooseRelinkFile(assetID: id)
            case .locateFolder:
                self?.chooseRelinkFolder()
            case .dismiss:
                break
            }
        }
    }

    func projectController(_ controller: ProjectController, didFailWith error: Error) {
        showError(error.localizedDescription)
    }

    @objc func newProject(_ sender: Any?) {
        confirmDiscardChanges { [weak self] in
            self?.playbackEngine.stop()
            self?.projectController.newProject()
            self?.showStatus("New project created")
        }
    }

    @objc func openProject(_ sender: Any?) {
        confirmDiscardChanges { [weak self] in
            guard let self = self else { return }
            let panel = NSOpenPanel()
            panel.allowedFileTypes = ["liau"]
            panel.beginSheetModal(for: self.window!) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.playbackEngine.stop()
                self?.projectController.open(url: url)
                self?.showStatus("Project opened")
            }
        }
    }

    @objc func saveProject(_ sender: Any?) {
        if !projectController.save() {
            saveProjectAs(sender)
        } else {
            showStatus("Project saved")
        }
    }

    @objc func saveProjectAs(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["liau"]
        panel.nameFieldStringValue = "\(projectController.project.name).liau"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            if self?.projectController.save(to: url) == true {
                self?.showStatus("Project saved")
            }
        }
    }

    @objc func importMedia(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = AudioFormatHelpers.audioExtensions + AudioFormatHelpers.videoExtensions
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK else { return }
            panel.urls.forEach { self?.projectController.importMedia(url: $0) }
            self?.showStatus("Importing \(panel.urls.count) file\(panel.urls.count == 1 ? "" : "s")")
        }
    }

    private func importMediaToLibrary() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = AudioFormatHelpers.audioExtensions + AudioFormatHelpers.videoExtensions
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK else { return }
            self?.importMediaFilesToLibrary(panel.urls, skippedCount: 0)
        }
    }

    private func importMediaFolderToLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK else { return }
            self?.importDroppedMedia(panel.urls)
        }
    }

    private func importDroppedMedia(_ urls: [URL]) {
        let result = supportedMediaFiles(from: urls)
        importMediaFilesToLibrary(result.supported, skippedCount: result.skipped)
    }

    private func importMediaFilesToLibrary(_ urls: [URL], skippedCount: Int) {
        let uniqueURLs = Array(Set(urls.map { $0.standardizedFileURL })).sorted { $0.path < $1.path }
        guard !uniqueURLs.isEmpty else {
            showStatus(skippedCount > 0 ? "Skipped unsupported file\(skippedCount == 1 ? "" : "s")" : "No supported media files found")
            return
        }

        var completed = 0
        var imported = 0
        var duplicates = 0
        var failed = 0
        showStatus("Importing \(uniqueURLs.count) file\(uniqueURLs.count == 1 ? "" : "s")")
        uniqueURLs.forEach { url in
            projectController.importMediaToLibrary(url: url) { [weak self] outcome in
                guard let self = self else { return }
                completed += 1
                switch outcome {
                case .imported(let asset):
                    imported += 1
                    self.showStatus(asset.kind == .videoAudio ? "Generating audio proxy..." : "Generating waveform...")
                case .duplicate(let asset):
                    duplicates += 1
                    self.mediaBin.selectAsset(id: asset.id)
                case .failed:
                    failed += 1
                }
                guard completed == uniqueURLs.count else { return }

                var parts: [String] = []
                if imported > 0 {
                    parts.append("Imported \(imported) file\(imported == 1 ? "" : "s")")
                }
                if duplicates > 0 {
                    parts.append("\(duplicates) already imported")
                }
                if skippedCount > 0 {
                    parts.append("skipped \(skippedCount) unsupported")
                }
                if failed > 0 {
                    parts.append("\(failed) failed")
                }
                self.showStatus(parts.isEmpty ? "No media imported" : parts.joined(separator: ", "))
            }
        }
    }

    private func supportedMediaFiles(from urls: [URL]) -> (supported: [URL], skipped: Int) {
        var supported: [URL] = []
        var skipped = 0
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let folderResult = supportedMediaFiles(in: url)
                supported.append(contentsOf: folderResult.supported)
                skipped += folderResult.skipped
            } else if AudioFormatHelpers.supportedImportExtension(url.pathExtension) {
                supported.append(url)
            } else {
                skipped += 1
            }
        }
        return (supported, skipped)
    }

    private func supportedMediaFiles(in folder: URL) -> (supported: [URL], skipped: Int) {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return ([], 1)
        }
        var supported: [URL] = []
        var skipped = 0
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                continue
            }
            if AudioFormatHelpers.supportedImportExtension(url.pathExtension) {
                supported.append(url)
            } else {
                skipped += 1
            }
        }
        return (supported, skipped)
    }

    @objc func exportTimeline(_ sender: Any?) {
        if projectController.project.hasMissingAssets {
            showMissingMediaBlockedMessage(action: "export")
            return
        }
        let unavailable = unavailableVideoProxyAssets()
        if !unavailable.isEmpty {
            showError("Finish audio proxy generation or relink failed video media before exporting:\n\(unavailable.map { $0.metadata.fileName }.joined(separator: "\n"))")
            return
        }
        ExportPanelController.show(window: window, project: projectController.project) { [weak self] settings in
            guard let self = self else { return }
            let progressController = ExportProgressController()
            progressController.onCancel = { [weak self] in self?.exportService.cancel() }
            self.exportProgressController = progressController
            if let window = self.window {
                window.beginSheet(progressController.window!, completionHandler: nil)
            }
            self.exportService.export(project: self.projectController.project, settings: settings, progress: { [weak self] value in
                self?.exportProgressController?.update(progress: value)
            }) { [weak self] result in
                guard let self = self else { return }
                if let sheet = self.exportProgressController?.window {
                    self.window?.endSheet(sheet)
                }
                self.exportProgressController = nil
                switch result {
                case .success(let exportResult):
                    if exportResult.clippingDetected {
                        self.setClippingIndicator(active: true)
                        self.showStatus("Export completed with clipping warning")
                        self.showInfo("Export completed, but clipping was detected. Consider lowering clip, track, or master volume.")
                    } else {
                        self.showStatus("Export completed")
                        self.showInfo("Export complete.")
                    }
                case .failure(let error):
                    self.showStatus("Export failed")
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    @objc func relinkMissingMedia(_ sender: Any?) {
        guard let first = projectController.project.missingAssets.first else {
            showStatus("No missing media")
            return
        }
        chooseRelinkFile(assetID: first.id)
    }

    @objc func locateMissingMediaFolder(_ sender: Any?) {
        chooseRelinkFolder()
    }

    @objc func removeUnusedMedia(_ sender: Any?) {
        let removed = projectController.removeUnusedMedia()
        showStatus(removed == 0 ? "No unused media to remove" : "Removed \(removed) unused media item\(removed == 1 ? "" : "s")")
    }

    @objc func regenerateAllWaveforms(_ sender: Any?) {
        projectController.regenerateAllWaveforms()
        showStatus("Regenerating waveforms...")
    }

    @objc func regenerateFailedWaveforms(_ sender: Any?) {
        projectController.regenerateFailedWaveforms()
        showStatus("Regenerating failed waveforms...")
    }

    @objc func regenerateAllVideoProxies(_ sender: Any?) {
        projectController.regenerateAllVideoProxies()
        showStatus("Regenerating audio proxies...")
    }

    @objc func collectProjectMedia(_ sender: Any?) {
        let missingCount = projectController.project.assets.filter { asset in
            projectController.usageCountsByAssetID()[asset.id, default: 0] > 0 && asset.isMissing
        }.count
        guard missingCount == 0 else {
            showError("Cannot collect project: \(missingCount) file\(missingCount == 1 ? "" : "s") are missing.")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Collect"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let folder = panel.url, let self = self else { return }
            self.showStatus("Collecting project media...")
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let projectURL = try self.projectController.collectProjectMedia(to: folder)
                    DispatchQueue.main.async {
                        self.showStatus("Collected project media")
                        self.showInfo("Collected project media:\n\(projectURL.path)")
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.showStatus("Collect project failed")
                        self.showError(error.localizedDescription)
                    }
                }
            }
        }
    }

    @objc func deleteSelectedClip(_ sender: Any?) {
        if timelineView.deleteSelectedAutomationKeyframe() {
            return
        }
        projectController.deleteSelectedClip()
    }

    @objc func rippleDeleteSelectedClips(_ sender: Any?) {
        projectController.rippleDeleteSelectedClips()
        showStatus("Ripple deleted selected clips")
    }

    @objc func applyFadeIn(_ sender: Any?) {
        promptForFade(title: "Apply Fade In") { [weak self] duration, curve in
            self?.projectController.applyFadeToSelected(edge: .left, duration: duration, curve: curve)
            self?.showStatus("Applied fade in")
        }
    }

    @objc func applyFadeOut(_ sender: Any?) {
        promptForFade(title: "Apply Fade Out") { [weak self] duration, curve in
            self?.projectController.applyFadeToSelected(edge: .right, duration: duration, curve: curve)
            self?.showStatus("Applied fade out")
        }
    }

    @objc func removeFades(_ sender: Any?) {
        projectController.removeFadesFromSelectedClips()
        showStatus("Removed fades")
    }

    @objc func applyCrossfade(_ sender: Any?) {
        if projectController.createCrossfadeForSelectedClips() {
            showStatus("Created crossfade")
        } else {
            showStatus("Select two overlapping clips on the same track to create a crossfade.")
        }
    }

    @objc func removeCrossfades(_ sender: Any?) {
        projectController.removeCrossfadesForSelectedClips()
        showStatus("Removed crossfades")
    }

    @objc func toggleRazorTool(_ sender: Any?) {
        timelineView.tool = timelineView.tool == .selection ? .razor : .selection
    }

    @objc func addTrack(_ sender: Any?) {
        projectController.addTrack()
    }

    @objc func duplicateSelectedClip(_ sender: Any?) {
        projectController.duplicateSelectedClip()
    }

    @objc func zoomIn(_ sender: Any?) {
        projectController.zoomTimeline(by: 1.25)
    }

    @objc func zoomOut(_ sender: Any?) {
        projectController.zoomTimeline(by: 0.8)
    }

    @objc func zoomToFitProject(_ sender: Any?) {
        let markerEnd = projectController.project.timeline.markers.map(\.time).max() ?? 0
        let projectEnd = max(projectController.project.duration, markerEnd)
        guard projectEnd > 0 else {
            projectController.setTimelineZoom(80)
            showStatus("Zoom reset")
            return
        }

        let visibleWidth = timelineScrollView?.contentView.bounds.width ?? timelineView.visibleRect.width
        let availableTimelineWidth = max(120, visibleWidth - 190)
        let targetZoom = Double(availableTimelineWidth) / max(projectEnd, 1)
        projectController.setTimelineZoom(targetZoom)
        if let clipView = timelineScrollView?.contentView {
            clipView.scroll(to: NSPoint(x: 0, y: clipView.bounds.origin.y))
            timelineScrollView?.reflectScrolledClipView(clipView)
        }
        showStatus("Zoomed to fit project")
    }

    @objc func nudgeLeft(_ sender: Any?) {
        projectController.nudgeSelectedClip(by: -0.1)
    }

    @objc func nudgeRight(_ sender: Any?) {
        projectController.nudgeSelectedClip(by: 0.1)
    }

    @objc func copySelectedClips(_ sender: Any?) {
        projectController.copySelectedClips()
    }

    @objc func cutSelectedClips(_ sender: Any?) {
        projectController.cutSelectedClips()
    }

    @objc func pasteClips(_ sender: Any?) {
        projectController.pasteClipsAtPlayhead()
    }

    @objc func addMarker(_ sender: Any?) {
        projectController.addMarkerAtPlayhead()
    }

    @objc func setInPoint(_ sender: Any?) {
        projectController.setInPoint()
        showStatus("Set In point")
    }

    @objc func setOutPoint(_ sender: Any?) {
        projectController.setOutPoint()
        showStatus("Set Out point")
    }

    @objc func clearInOutRange(_ sender: Any?) {
        projectController.clearInOutRange()
        showStatus("Cleared In/Out range")
    }

    @objc func toggleSnapping(_ sender: Any?) {
        projectController.toggleSnapping()
        showStatus(projectController.project.viewState.snappingEnabled ? "Snapping enabled" : "Snapping disabled")
    }

    @objc func toggleFollowPlayhead(_ sender: Any?) {
        projectController.toggleFollowPlayhead()
        showStatus(projectController.project.viewState.followPlayhead ? "Follow playhead enabled" : "Follow playhead disabled")
    }

    @objc func toggleLoopRange(_ sender: Any?) {
        projectController.toggleLoopRange()
        let enabled = projectController.project.viewState.loopRangeEnabled
        if enabled && projectController.project.viewState.validRange == nil {
            showStatus("Set In and Out points to loop a range.")
        } else {
            showStatus(enabled ? "Loop range enabled" : "Loop range disabled")
        }
    }

    @objc func increaseTrackHeight(_ sender: Any?) {
        projectController.increaseTrackHeight()
        showStatus("Track height increased")
    }

    @objc func decreaseTrackHeight(_ sender: Any?) {
        projectController.decreaseTrackHeight()
        showStatus("Track height decreased")
    }

    @objc func resetTrackHeight(_ sender: Any?) {
        projectController.resetTrackHeight()
        showStatus("Track height reset")
    }

    @objc func jumpToProjectStart(_ sender: Any?) {
        seekPlayback(to: 0)
        showStatus("Jumped to start")
    }

    @objc func jumpToProjectEnd(_ sender: Any?) {
        let markerEnd = projectController.project.timeline.markers.map(\.time).max() ?? 0
        seekPlayback(to: max(projectController.project.duration, markerEnd))
        showStatus("Jumped to end")
    }

    @objc func jumpToNextMarker(_ sender: Any?) {
        let current = projectController.playheadTime + 0.001
        guard let marker = projectController.project.timeline.markers.filter({ $0.time > current }).sorted(by: { $0.time < $1.time }).first else {
            showStatus("No next marker")
            return
        }
        seekPlayback(to: marker.time)
        showStatus("Next marker")
    }

    @objc func jumpToPreviousMarker(_ sender: Any?) {
        let current = projectController.playheadTime - 0.001
        guard let marker = projectController.project.timeline.markers.filter({ $0.time < current }).sorted(by: { $0.time > $1.time }).first else {
            showStatus("No previous marker")
            return
        }
        seekPlayback(to: marker.time)
        showStatus("Previous marker")
    }

    @objc func jumpToNextClipEdge(_ sender: Any?) {
        let current = projectController.playheadTime + 0.001
        let edges = clipEdges().filter { $0 > current }.sorted()
        guard let edge = edges.first else {
            showStatus("No next clip edge")
            return
        }
        seekPlayback(to: edge)
        showStatus("Next clip edge")
    }

    @objc func jumpToPreviousClipEdge(_ sender: Any?) {
        let current = projectController.playheadTime - 0.001
        let edges = clipEdges().filter { $0 < current }.sorted(by: >)
        guard let edge = edges.first else {
            showStatus("No previous clip edge")
            return
        }
        seekPlayback(to: edge)
        showStatus("Previous clip edge")
    }

    @objc func resetWindowLayout(_ sender: Any?) {
        guard let window = window,
              let mainSplitView = mainSplitView,
              let timelineInspectorSplitView = timelineInspectorSplitView else { return }
        window.layoutIfNeeded()
        let contentSize = window.contentView?.bounds.size ?? window.frame.size
        let mediaWidth = min(260, max(220, contentSize.width * 0.22))
        mainSplitView.setPosition(mediaWidth, ofDividerAt: 0)

        let timelineHeight = max(320, contentSize.height - 220)
        timelineInspectorSplitView.setPosition(timelineHeight, ofDividerAt: 0)
        showStatus("Window layout reset")
    }

    @objc private func masterVolumeChanged() {
        projectController.setMasterVolume(masterVolumeSlider.doubleValue)
        masterVolumeLabel.stringValue = String(format: "%.0f dB", masterVolumeSlider.doubleValue)
        showStatus("Master volume changed")
    }

    @objc private func clearClippingIndicator() {
        setClippingIndicator(active: false)
        showStatus("Clipping indicator reset")
    }

    func togglePlayback() {
        if playbackEngine.isPlaying {
            playbackEngine.pause()
            projectController.setPlayhead(playbackEngine.currentTime)
            playbackTimer?.invalidate()
            playbackTimer = nil
            showStatus("Playback paused")
        } else {
            startPlayback(from: projectController.playheadTime)
        }
    }

    private func startPlayback(from time: TimeInterval) {
        if projectController.project.hasMissingAssets {
            showMissingMediaBlockedMessage(action: "play")
            return
        }
        let unavailable = unavailableVideoProxyAssets()
        if !unavailable.isEmpty {
            showStatus("Playback blocked by unavailable audio proxies")
            showError("Finish audio proxy generation or relink failed video media before playback:\n\(unavailable.map { $0.metadata.fileName }.joined(separator: "\n"))")
            return
        }
        let playbackStart = loopAdjustedStartTime(from: time)
        do {
            try playbackEngine.play(project: projectController.project, from: playbackStart)
            projectController.setPlayhead(playbackStart)
            startPlaybackTimer()
            showStatus("Playing")
        } catch {
            showStatus("Playback failed")
            showError(error.localizedDescription)
        }
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if let range = self.activeLoopRange(), self.playbackEngine.currentTime >= range.end {
                self.playbackEngine.stop()
                self.resetMeters()
                self.startPlayback(from: range.start)
                return
            }
            self.projectController.playheadTime = self.playbackEngine.currentTime
            self.timelineView.playheadTime = self.projectController.playheadTime
            self.timeLabel.stringValue = Timecode.string(self.projectController.playheadTime)
            self.updateMeters(at: self.projectController.playheadTime)
            self.scrollTimelineToPlayheadIfNeeded()
        }
        playbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func loopAdjustedStartTime(from time: TimeInterval) -> TimeInterval {
        guard let range = activeLoopRange() else {
            if projectController.project.viewState.loopRangeEnabled {
                showStatus("Set In and Out points to loop a range.")
            }
            return time
        }
        if time < range.start || time >= range.end {
            return range.start
        }
        return time
    }

    private func activeLoopRange() -> (start: TimeInterval, end: TimeInterval)? {
        guard projectController.project.viewState.loopRangeEnabled else { return nil }
        return projectController.project.viewState.validRange
    }

    private func chooseRelinkFile(assetID: UUID) {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = AudioFormatHelpers.audioExtensions + AudioFormatHelpers.videoExtensions
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let result = self?.projectController.relink(assetID: assetID, replacementURL: url)
            if let result = result, !result.accepted {
                self?.showError(result.reason)
            } else {
                self?.showStatus("Media relinked")
            }
        }
    }

    private func chooseRelinkFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let messages = self?.projectController.locateMissingAssets(in: url).joined(separator: "\n") ?? ""
            self?.showStatus(messages.isEmpty ? "No missing media found" : "Relink scan completed")
            self?.showInfo(messages.isEmpty ? "No missing media found." : messages)
        }
    }

    private func showMediaInfo(assetID: UUID) {
        guard let asset = projectController.project.asset(id: assetID) else { return }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let fileSize = asset.metadata.fileSize.map { formatter.string(fromByteCount: $0) } ?? "Unknown"
        let mediaType = asset.kind == .videoAudio ? "Video-origin audio" : "Audio"
        let proxyStatus = asset.kind == .videoAudio ? "\nProxy status: \(asset.proxyStatus.rawValue)" : ""
        let relinkState = asset.isMissing ? "Missing" : "Available"
        let resolvedURL = FileReferenceResolver().resolvedURL(for: asset, projectURL: projectController.projectURL)
        let imported = asset.importedAt.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "Unknown"
        let usage = projectController.usageCountsByAssetID()[asset.id, default: 0]
        let message = """
        Display name: \(asset.displayName)
        Original file name: \(asset.metadata.fileName)
        Original path: \(asset.originalPath)
        Resolved path: \(resolvedURL.path)
        Media type: \(mediaType)
        Duration: \(Timecode.string(asset.metadata.duration))
        Sample rate: \(Int(asset.metadata.sampleRate)) Hz
        Channels: \(asset.metadata.channelCount)
        File size: \(fileSize)
        Date imported: \(imported)
        Usage count: \(usage)
        Waveform status: \(asset.waveformStatus.rawValue)\(proxyStatus)
        State: \(relinkState)
        """
        showInfo(message)
    }

    private func renameMedia(assetID: UUID) {
        guard let asset = projectController.project.asset(id: assetID) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Media"
        alert.informativeText = "This changes only the project display name. The original file on disk is not renamed."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = asset.displayName
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.projectController.renameMedia(assetID: assetID, name: field.stringValue)
            self?.showStatus("Renamed media")
        }
    }

    private func renameTrack(trackID: UUID) {
        guard let track = projectController.project.timeline.tracks.first(where: { $0.id == trackID }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Track"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = track.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.projectController.renameTrack(trackID: trackID, name: field.stringValue)
        }
    }

    private func deleteTrackWithConfirmation(trackID: UUID) {
        guard let track = projectController.project.timeline.tracks.first(where: { $0.id == trackID }) else { return }
        guard !track.clips.isEmpty else {
            projectController.deleteTrack(trackID)
            showStatus("Deleted track")
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Track?"
        alert.informativeText = "This will remove \(track.name) and all clips on it."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.projectController.deleteTrack(trackID, allowNonEmpty: true)
            self?.showStatus("Deleted track")
        }
    }

    private func renameMarker(markerID: UUID) {
        guard let marker = projectController.project.timeline.markers.first(where: { $0.id == markerID }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Marker"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = marker.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.projectController.renameMarker(markerID, name: field.stringValue)
        }
    }

    private func renameClip(clipID: UUID) {
        guard let clip = projectController.project.timeline.tracks.flatMap({ $0.clips }).first(where: { $0.id == clipID }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Clip"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = clip.customName ?? ""
        field.placeholderString = projectController.project.asset(id: clip.sourceAssetID)?.displayName ?? "Clip"
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.projectController.renameClip(clipID, name: field.stringValue)
                self?.showStatus("Renamed clip")
            case .alertSecondButtonReturn:
                self?.projectController.renameClip(clipID, name: nil)
                self?.showStatus("Cleared clip name")
            default:
                break
            }
        }
    }

    private func normalizeClip(clipID: UUID) {
        guard projectController.project.timeline.tracks.flatMap({ $0.clips }).contains(where: { $0.id == clipID }) else { return }
        let alert = NSAlert()
        alert.messageText = "Analyze and Normalize Clip"
        alert.informativeText = "Sets clip gain so the visible trimmed region peaks at the target level. Source media is not modified."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        field.stringValue = "-1.0"
        field.alignment = .right
        field.formatter = DecimalNumberFormatter()
        let label = NSTextField(labelWithString: "Target peak dB")
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        alert.accessoryView = row
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            self.showStatus("Analyzing clip peak...")
            self.projectController.normalizeClip(clipID: clipID, targetPeakDB: field.doubleValue) { [weak self] result in
                switch result {
                case .success(let gainDB):
                    self?.showStatus("Normalized clip to \(String(format: "%.1f dB", gainDB)) gain")
                case .failure(let error):
                    self?.showStatus(error.localizedDescription)
                    self?.showError(error.localizedDescription)
                }
            }
        }
    }

    @objc private func timeFieldChanged() {
        guard let seconds = Timecode.seconds(timeLabel.stringValue) else {
            timeLabel.stringValue = Timecode.string(projectController.playheadTime)
            return
        }
        seekPlayback(to: seconds)
    }

    private func seekPlayback(to time: TimeInterval) {
        let wasPlaying = playbackEngine.isPlaying
        playbackEngine.seek(to: time)
        playbackTimer?.invalidate()
        playbackTimer = nil
        projectController.setPlayhead(time)
        if wasPlaying {
            startPlayback(from: time)
        }
    }

    private func scrollTimelineToPlayheadIfNeeded() {
        guard projectController.project.viewState.followPlayhead,
              let scrollView = timelineView.enclosingScrollView else {
            return
        }
        let visible = scrollView.documentVisibleRect
        let playheadX = timelineView.xPosition(for: projectController.playheadTime)
        let margin: CGFloat = 120
        guard playheadX > visible.maxX - margin || playheadX < visible.minX + margin else { return }
        let targetX = max(0, playheadX - visible.width * 0.45)
        scrollView.contentView.scroll(to: NSPoint(x: targetX, y: visible.origin.y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func updateMeters(at time: TimeInterval) {
        let raw = meterLevels(at: time)
        var decayed: [UUID: Double] = [:]
        for track in projectController.project.timeline.tracks {
            let old = displayedTrackLevels[track.id] ?? 0
            decayed[track.id] = max(raw.tracks[track.id] ?? 0, old * 0.84)
        }
        displayedTrackLevels = decayed
        displayedMasterLevel = max(raw.master, displayedMasterLevel * 0.84)
        timelineView.trackLevels = displayedTrackLevels
        masterMeterView.level = displayedMasterLevel
        if raw.clipping {
            let wasClipping = clippingActive
            setClippingIndicator(active: true)
            if !wasClipping {
                showStatus("Playback clipping detected")
            }
        }
    }

    private func resetMeters() {
        displayedTrackLevels = [:]
        displayedMasterLevel = 0
        timelineView.trackLevels = [:]
        masterMeterView.level = 0
    }

    private func meterLevels(at time: TimeInterval) -> (tracks: [UUID: Double], master: Double, clipping: Bool) {
        let project = projectController.project
        let soloedTrackIDs = Set(project.timeline.tracks.filter { $0.isSolo }.map { $0.id })
        var trackPeaks: [UUID: Double] = [:]
        var masterPeak = 0.0
        for track in project.timeline.tracks {
            guard !track.isMuted, soloedTrackIDs.isEmpty || soloedTrackIDs.contains(track.id) else {
                trackPeaks[track.id] = 0
                continue
            }
            var trackPeak = 0.0
            for clip in track.clips where clip.timelineStart <= time && time <= clip.timelineStart + clip.duration {
                guard let waveform = projectController.waveforms[clip.sourceAssetID], waveform.duration > 0, !waveform.peaks.isEmpty else { continue }
                let sourceTime = clip.sourceStart + (time - clip.timelineStart)
                guard sourceTime >= clip.sourceStart && sourceTime <= clip.sourceEnd else { continue }
                let fraction = min(1, max(0, sourceTime / waveform.duration))
                let index = min(waveform.peaks.count - 1, max(0, Int(fraction * Double(waveform.peaks.count - 1))))
                let peak = max(abs(Double(waveform.peaks[index].min)), abs(Double(waveform.peaks[index].max)))
                let fade = FadeMath.edgeFadeGain(for: clip, timelineTime: time)
                let crossfade = FadeMath.crossfadeGain(for: clip.id, timelineTime: time, timeline: project.timeline)
                let clipTime = time - clip.timelineStart
                let automation = AutomationMath.volumeAutomationGain(for: clip, atClipTime: clipTime)
                trackPeak += peak * MixMath.clampClipGainLinear(clip.gain) * automation * fade * crossfade
            }
            trackPeak *= MixMath.linearGain(forDB: track.volumeDB)
            trackPeak *= AutomationMath.trackVolumeAutomationGain(for: track, atTimelineTime: time)
            trackPeaks[track.id] = trackPeak
            masterPeak += trackPeak
        }
        masterPeak *= MixMath.linearGain(forDB: project.mixState.masterVolumeDB)
        return (trackPeaks, masterPeak, masterPeak >= 1)
    }

    private func clipEdges() -> [TimeInterval] {
        projectController.project.timeline.tracks.flatMap { track in
            track.clips.flatMap { clip in
                [clip.timelineStart, clip.timelineStart + clip.duration]
            }
        }
    }

    private func setClippingIndicator(active: Bool) {
        clippingActive = active
        clipIndicator.contentTintColor = active ? .systemRed : .secondaryLabelColor
        masterMeterView.clipping = active
    }

    private func showMissingMediaBlockedMessage(action: String) {
        let names = projectController.project.missingAssets.map { $0.metadata.fileName }.joined(separator: "\n")
        showStatus("Missing media must be relinked before \(action)")
        showError("Relink missing media before you \(action) this project:\n\(names)")
    }

    private func unavailableVideoProxyAssets() -> [MediaAsset] {
        projectController.project.assets.filter { $0.kind == .videoAudio && $0.proxyStatus != .ready }
    }

    private func resizeTimeline(for project: Project) {
        let rangeEnd = max(project.viewState.outPoint ?? 0, project.viewState.inPoint ?? 0)
        let markerEnd = project.timeline.markers.map(\.time).max() ?? 0
        let width = max(2200, CGFloat(max(project.duration, markerEnd, rangeEnd, 20) * project.viewState.zoom + 160))
        let height = timelineView.preferredContentHeight()
        timelineView.setFrameSize(NSSize(width: width, height: height))
    }

    private func updateWindowTitle() {
        window?.title = projectController.isDirty ? "LightAudio Editor - \(projectController.project.name) *" : "LightAudio Editor - \(projectController.project.name)"
    }

    private func updateToolbarLabels() {
        window?.toolbar?.items.forEach { item in
            switch item.itemIdentifier {
            case .snapToggle:
                item.label = projectController.project.viewState.snappingEnabled ? "Snap On" : "Snap Off"
                item.toolTip = item.label
                item.view?.toolTip = item.label
            case .followPlayhead:
                item.label = projectController.project.viewState.followPlayhead ? "Follow On" : "Follow Off"
                item.toolTip = item.label
                item.view?.toolTip = item.label
            case .loopRange:
                item.label = projectController.project.viewState.loopRangeEnabled ? "Loop On" : "Loop Off"
                item.toolTip = item.label
                item.view?.toolTip = item.label
            default:
                break
            }
        }
    }

    private func confirmDiscardChanges(_ proceed: @escaping () -> Void) {
        guard projectController.isDirty else {
            proceed()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Save changes to this project?"
        alert.informativeText = "Your unsaved timeline edits will be lost if you continue without saving."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                if self?.saveProjectSynchronously() == true { proceed() }
            case .alertSecondButtonReturn:
                proceed()
            default:
                break
            }
        }
    }

    private func saveProjectSynchronously() -> Bool {
        if projectController.projectURL != nil {
            return projectController.save()
        }
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["liau"]
        panel.nameFieldStringValue = "\(projectController.project.name).liau"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return projectController.save(to: url)
    }

    private func promptForFade(title: String, completion: @escaping (TimeInterval, FadeCurve) -> Void) {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Choose a fade duration and curve for the selected clips."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")

        let durationField = NSTextField(string: "1.00")
        durationField.formatter = DecimalNumberFormatter()
        let curvePopup = NSPopUpButton()
        FadeCurve.allCases.forEach { curvePopup.addItem(withTitle: $0.displayName) }
        curvePopup.selectItem(at: FadeCurve.allCases.firstIndex(of: .linear) ?? 0)

        let durationLabel = NSTextField(labelWithString: "Duration")
        let curveLabel = NSTextField(labelWithString: "Curve")
        let grid = NSGridView(views: [
            [durationLabel, durationField],
            [curveLabel, curvePopup]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 140
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.frame = NSRect(x: 0, y: 0, width: 250, height: 58)
        alert.accessoryView = grid

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let duration = max(0, durationField.doubleValue)
            let curveIndex = max(0, min(FadeCurve.allCases.count - 1, curvePopup.indexOfSelectedItem))
            completion(duration, FadeCurve.allCases[curveIndex])
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard projectController.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes before closing?"
        alert.informativeText = "Your unsaved timeline edits will be lost if you close without saving."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveProjectSynchronously()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    private func showError(_ message: String) {
        showStatus(message.components(separatedBy: .newlines).first ?? "Error")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "LightAudio Editor"
        alert.informativeText = message
        alert.beginSheetModal(for: window!)
    }

    private func showInfo(_ message: String) {
        showStatus(message.components(separatedBy: .newlines).first ?? "Done")
        let alert = NSAlert()
        alert.messageText = "LightAudio Editor"
        alert.informativeText = message
        alert.beginSheetModal(for: window!)
    }

    private func showStatus(_ message: String) {
        statusLabel.stringValue = message
    }
}

extension MainWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.newProject, .openProject, .saveProject, .importMedia, .addTrack, .snapToggle, .followPlayhead, .loopRange, .zoomOut, .zoomIn, .exportTimeline, .playPause, .flexibleSpace, .timeDisplay]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.importMedia, .addTrack, .snapToggle, .followPlayhead, .loopRange, .zoomOut, .zoomIn, .saveProject, .exportTimeline, .flexibleSpace, .playPause, .timeDisplay]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case .newProject:
            configureButtonItem(item, label: "New", imageName: NSImage.addTemplateName, action: #selector(newProject(_:)))
        case .openProject:
            configureButtonItem(item, label: "Open", imageName: NSImage.folderName, action: #selector(openProject(_:)))
        case .saveProject:
            configureButtonItem(item, label: "Save", imageName: NSImage.touchBarDownloadTemplateName, action: #selector(saveProject(_:)))
        case .importMedia:
            configureButtonItem(item, label: "Import", imageName: NSImage.shareTemplateName, action: #selector(importMedia(_:)))
        case .addTrack:
            configureButtonItem(item, label: "Add Track", imageName: NSImage.addTemplateName, action: #selector(addTrack(_:)))
        case .snapToggle:
            configureButtonItem(item, label: projectController.project.viewState.snappingEnabled ? "Snap On" : "Snap Off", imageName: NSImage.statusAvailableName, action: #selector(toggleSnapping(_:)))
        case .followPlayhead:
            configureButtonItem(item, label: projectController.project.viewState.followPlayhead ? "Follow On" : "Follow Off", imageName: NSImage.followLinkFreestandingTemplateName, action: #selector(toggleFollowPlayhead(_:)))
        case .loopRange:
            configureButtonItem(item, label: projectController.project.viewState.loopRangeEnabled ? "Loop On" : "Loop Off", imageName: NSImage.touchBarRefreshTemplateName, action: #selector(toggleLoopRange(_:)))
        case .zoomOut:
            configureButtonItem(item, label: "Zoom Out", imageName: NSImage.removeTemplateName, action: #selector(zoomOut(_:)))
        case .zoomIn:
            configureButtonItem(item, label: "Zoom In", imageName: NSImage.addTemplateName, action: #selector(zoomIn(_:)))
        case .exportTimeline:
            configureButtonItem(item, label: "Export", imageName: NSImage.actionTemplateName, action: #selector(exportTimeline(_:)))
        case .playPause:
            configureButtonItem(item, label: "Play", imageName: NSImage.touchBarPlayTemplateName, action: #selector(playPause(_:)))
        case .timeDisplay:
            item.view = timeLabel
            timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        default:
            return nil
        }
        return item
    }

    private func configureButtonItem(_ item: NSToolbarItem, label: String, imageName: String, action: Selector) {
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        let button = RoundToolbarButton(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
        button.image = NSImage(named: imageName)
        button.target = self
        button.action = action
        button.toolTip = label
        item.view = button
        item.minSize = button.frame.size
        item.maxSize = button.frame.size
    }

    @objc private func playPause(_ sender: Any?) {
        togglePlayback()
    }
}

final class RoundToolbarButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        bezelStyle = .regularSquare
        wantsLayer = true
        frame.size = NSSize(width: 34, height: 34)
        layer?.cornerRadius = 17
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.clear.cgColor
        layer?.backgroundColor = NSColor.clear.cgColor
        contentTintColor = .labelColor
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = 17
        layer?.borderColor = NSColor.clear.cgColor
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.selectedControlColor.withAlphaComponent(0.18).cgColor
        super.mouseDown(with: event)
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

final class LevelMeterView: NSView {
    var level: Double = 0 {
        didSet { needsDisplay = true }
    }

    var clipping: Bool = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()

        let clamped = min(1.2, max(0, level))
        let meterWidth = bounds.width * CGFloat(min(1, clamped))
        let meterColor: NSColor
        if clipping || clamped >= 1 {
            meterColor = .systemRed
        } else if clamped > 0.75 {
            meterColor = .systemYellow
        } else {
            meterColor = .systemGreen
        }

        meterColor.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: meterWidth, height: bounds.height), xRadius: 3, yRadius: 3).fill()
    }
}

private extension NSToolbarItem.Identifier {
    static let newProject = NSToolbarItem.Identifier("newProject")
    static let openProject = NSToolbarItem.Identifier("openProject")
    static let saveProject = NSToolbarItem.Identifier("saveProject")
    static let importMedia = NSToolbarItem.Identifier("importMedia")
    static let addTrack = NSToolbarItem.Identifier("addTrack")
    static let snapToggle = NSToolbarItem.Identifier("snapToggle")
    static let followPlayhead = NSToolbarItem.Identifier("followPlayhead")
    static let loopRange = NSToolbarItem.Identifier("loopRange")
    static let zoomOut = NSToolbarItem.Identifier("zoomOut")
    static let zoomIn = NSToolbarItem.Identifier("zoomIn")
    static let exportTimeline = NSToolbarItem.Identifier("exportTimeline")
    static let playPause = NSToolbarItem.Identifier("playPause")
    static let timeDisplay = NSToolbarItem.Identifier("timeDisplay")
}

final class KeyWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            (windowController as? MainWindowController)?.togglePlayback()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            (windowController as? MainWindowController)?.deleteSelectedClip(nil)
            return
        }
        if let key = event.charactersIgnoringModifiers?.lowercased(), key == "s", !event.modifierFlags.contains(.command) {
            (windowController as? MainWindowController)?.toggleRazorTool(nil)
            return
        }
        if let key = event.charactersIgnoringModifiers?.lowercased(), key == "d", event.modifierFlags.contains(.command) {
            (windowController as? MainWindowController)?.duplicateSelectedClip(nil)
            return
        }
        if let key = event.charactersIgnoringModifiers?.lowercased(), key == "c", event.modifierFlags.contains(.command) {
            (windowController as? MainWindowController)?.copySelectedClips(nil)
            return
        }
        if let key = event.charactersIgnoringModifiers?.lowercased(), key == "x", event.modifierFlags.contains(.command) {
            (windowController as? MainWindowController)?.cutSelectedClips(nil)
            return
        }
        if let key = event.charactersIgnoringModifiers?.lowercased(), key == "v", event.modifierFlags.contains(.command) {
            (windowController as? MainWindowController)?.pasteClips(nil)
            return
        }
        if let key = event.charactersIgnoringModifiers?.lowercased(), key == "i", !event.modifierFlags.contains(.command) {
            (windowController as? MainWindowController)?.setInPoint(nil)
            return
        }
        if let key = event.charactersIgnoringModifiers?.lowercased(), key == "o", !event.modifierFlags.contains(.command) {
            (windowController as? MainWindowController)?.setOutPoint(nil)
            return
        }
        if let key = event.charactersIgnoringModifiers?.lowercased(), key == "x", event.modifierFlags.contains(.option), !event.modifierFlags.contains(.command) {
            (windowController as? MainWindowController)?.clearInOutRange(nil)
            return
        }
        if let key = event.charactersIgnoringModifiers?.lowercased(), key == "l", !event.modifierFlags.contains(.command) {
            (windowController as? MainWindowController)?.toggleLoopRange(nil)
            return
        }
        if let key = event.charactersIgnoringModifiers?.lowercased(), key == "m", !event.modifierFlags.contains(.command) {
            if event.modifierFlags.contains(.shift), event.modifierFlags.contains(.option) {
                (windowController as? MainWindowController)?.jumpToPreviousMarker(nil)
                return
            }
            if event.modifierFlags.contains(.shift) {
                (windowController as? MainWindowController)?.jumpToNextMarker(nil)
                return
            }
            (windowController as? MainWindowController)?.addMarker(nil)
            return
        }
        if let key = event.charactersIgnoringModifiers?.lowercased(), key == "n", !event.modifierFlags.contains(.command) {
            (windowController as? MainWindowController)?.toggleSnapping(nil)
            return
        }
        if event.charactersIgnoringModifiers == "=", event.modifierFlags.contains(.command) {
            if event.modifierFlags.contains(.option) {
                (windowController as? MainWindowController)?.increaseTrackHeight(nil)
                return
            }
            (windowController as? MainWindowController)?.zoomIn(nil)
            return
        }
        if event.charactersIgnoringModifiers == "-", event.modifierFlags.contains(.command) {
            if event.modifierFlags.contains(.option) {
                (windowController as? MainWindowController)?.decreaseTrackHeight(nil)
                return
            }
            (windowController as? MainWindowController)?.zoomOut(nil)
            return
        }
        if event.keyCode == 115 {
            (windowController as? MainWindowController)?.jumpToProjectStart(nil)
            return
        }
        if event.keyCode == 119 {
            (windowController as? MainWindowController)?.jumpToProjectEnd(nil)
            return
        }
        if event.keyCode == 123 {
            if event.modifierFlags.contains(.option) {
                (windowController as? MainWindowController)?.jumpToPreviousClipEdge(nil)
                return
            }
            (windowController as? MainWindowController)?.nudgeLeft(nil)
            return
        }
        if event.keyCode == 124 {
            if event.modifierFlags.contains(.option) {
                (windowController as? MainWindowController)?.jumpToNextClipEdge(nil)
                return
            }
            (windowController as? MainWindowController)?.nudgeRight(nil)
            return
        }
        super.keyDown(with: event)
    }
}
