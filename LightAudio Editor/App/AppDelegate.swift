import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let recoveryService = AutosaveRecoveryService()
    private var projectController: ProjectController?
    private var mainWindowController: MainWindowController?
    private var mainWindow: NSWindow?
    private var crashRecoveryController: CrashRecoveryController?
    private var preferencesWindowController: PreferencesWindowController?
    private var hasCheckedForRecovery = false
    private var recoverySessionStarted = false
    private var terminationReplyPending = false
    private var hasFinishedLaunching = false
    private var pendingProjectURL: URL?
    private var recoveryCheckInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        NSApp.setActivationPolicy(.regular)
        hasFinishedLaunching = true
        showMainWindow()
        checkForRecoveryThenOpenPendingProject()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.ensureMainWindowVisible()
        }
    }

    private func showMainWindow() {
        let projectController = self.projectController ?? ProjectController(recoveryService: recoveryService)
        self.projectController = projectController

        let controller = mainWindowController ?? MainWindowController(projectController: projectController)
        mainWindowController = controller
        mainWindow = controller.window
        crashRecoveryController = crashRecoveryController ?? CrashRecoveryController(recoveryService: recoveryService)
        controller.showWindow(self)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(self)
        controller.window?.orderFrontRegardless()
        if !recoverySessionStarted {
            recoverySessionStarted = true
            recoveryService.markSessionStarted()
        }
    }

    private func ensureMainWindowVisible() {
        guard mainWindowController?.window?.isVisible != true else { return }
        showMainWindow()
        mainWindowController?.window?.makeKeyAndOrderFront(self)
        mainWindowController?.window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if recoverySessionStarted {
            recoveryService.markCleanShutdown()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationReplyPending else { return .terminateLater }
        guard let controller = mainWindowController, controller.hasUnsavedChanges else {
            return .terminateNow
        }

        terminationReplyPending = true
        controller.confirmTermination { [weak self, weak sender] shouldTerminate in
            DispatchQueue.main.async {
                guard let self else { return }
                self.terminationReplyPending = false
                sender?.reply(toApplicationShouldTerminate: shouldTerminate)
            }
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let projectURLs = filenames
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { $0.pathExtension.lowercased() == "liau" }
        guard let projectURL = projectURLs.first else {
            sender.reply(toOpenOrPrint: .failure)
            return
        }

        pendingProjectURL = projectURL
        sender.reply(toOpenOrPrint: projectURLs.count == filenames.count ? .success : .failure)
        if hasFinishedLaunching {
            showMainWindow()
            openPendingProjectIfNeeded()
        }
    }

    private func checkForRecoveryThenOpenPendingProject() {
        guard !hasCheckedForRecovery else {
            openPendingProjectIfNeeded()
            return
        }
        hasCheckedForRecovery = true
        guard let controller = projectController,
              let recoveryController = crashRecoveryController else {
            openPendingProjectIfNeeded()
            return
        }
        recoveryCheckInProgress = true
        recoveryController.checkForRecovery(
            presenter: mainWindowController?.window,
            openSaved: { url in controller.open(url: url) },
            restore: { snapshot in controller.restore(snapshot: snapshot) },
            completion: { [weak self] in
                self?.recoveryCheckInProgress = false
                self?.openPendingProjectIfNeeded()
            }
        )
    }

    private func openPendingProjectIfNeeded() {
        guard hasFinishedLaunching, !recoveryCheckInProgress, let url = pendingProjectURL else { return }
        pendingProjectURL = nil
        mainWindowController?.openProject(at: url)
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        let aboutItem = appMenu.addItem(
            withTitle: "About LightAudio Editor",
            action: #selector(showAbout(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(.separator())
        let preferencesItem = appMenu.addItem(withTitle: "Preferences...", action: #selector(showPreferences(_:)), keyEquivalent: ",")
        preferencesItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit LightAudio Editor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        addMenuItem(to: fileMenu, title: "New", action: #selector(newProject(_:)), keyEquivalent: "n")
        addMenuItem(to: fileMenu, title: "Open...", action: #selector(openProject(_:)), keyEquivalent: "o")
        addMenuItem(to: fileMenu, title: "Save", action: #selector(saveProject(_:)), keyEquivalent: "s")
        addMenuItem(to: fileMenu, title: "Save As...", action: #selector(saveProjectAs(_:)), keyEquivalent: "S")
        fileMenu.addItem(.separator())
        addMenuItem(to: fileMenu, title: "Import...", action: #selector(importMedia(_:)), keyEquivalent: "i")
        addMenuItem(to: fileMenu, title: "Export...", action: #selector(exportTimeline(_:)), keyEquivalent: "e")
        fileMenu.addItem(.separator())
        addMenuItem(to: fileMenu, title: "Collect Project Media...", action: #selector(collectProjectMedia(_:)), keyEquivalent: "")
        fileItem.submenu = fileMenu

        let projectItem = NSMenuItem()
        mainMenu.addItem(projectItem)
        let projectMenu = NSMenu(title: "Project")
        addMenuItem(to: projectMenu, title: "Relink Missing Media...", action: #selector(relinkMissingMedia(_:)), keyEquivalent: "")
        addMenuItem(to: projectMenu, title: "Locate Folder for Missing Media...", action: #selector(locateMissingMediaFolder(_:)), keyEquivalent: "")
        projectMenu.addItem(.separator())
        addMenuItem(to: projectMenu, title: "Remove Unused Media", action: #selector(removeUnusedMedia(_:)), keyEquivalent: "")
        projectMenu.addItem(.separator())
        addMenuItem(to: projectMenu, title: "Regenerate All Waveforms", action: #selector(regenerateAllWaveforms(_:)), keyEquivalent: "")
        addMenuItem(to: projectMenu, title: "Regenerate Failed Waveforms", action: #selector(regenerateFailedWaveforms(_:)), keyEquivalent: "")
        addMenuItem(to: projectMenu, title: "Regenerate All Video Proxies", action: #selector(regenerateAllVideoProxies(_:)), keyEquivalent: "")
        projectItem.submenu = projectMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        addMenuItem(to: editMenu, title: "Copy", action: #selector(copySelectedClips(_:)), keyEquivalent: "c")
        addMenuItem(to: editMenu, title: "Cut", action: #selector(cutSelectedClips(_:)), keyEquivalent: "x")
        addMenuItem(to: editMenu, title: "Paste", action: #selector(pasteClips(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        addMenuItem(to: editMenu, title: "Delete", action: #selector(deleteSelectedClip(_:)), keyEquivalent: "\u{8}")
        addMenuItem(to: editMenu, title: "Ripple Delete", action: #selector(rippleDeleteSelectedClips(_:)), keyEquivalent: "")
        addMenuItem(to: editMenu, title: "Duplicate", action: #selector(duplicateSelectedClip(_:)), keyEquivalent: "d")
        addMenuItem(to: editMenu, title: "Split/Razor Tool", action: #selector(toggleRazorTool(_:)), keyEquivalent: "b")
        editMenu.addItem(.separator())
        addMenuItem(to: editMenu, title: "Apply Fade In...", action: #selector(applyFadeIn(_:)), keyEquivalent: "")
        addMenuItem(to: editMenu, title: "Apply Fade Out...", action: #selector(applyFadeOut(_:)), keyEquivalent: "")
        let crossfadeItem = addMenuItem(to: editMenu, title: "Apply Crossfade", action: #selector(applyCrossfade(_:)), keyEquivalent: "f")
        crossfadeItem.keyEquivalentModifierMask = [.command, .shift]
        addMenuItem(to: editMenu, title: "Remove Fades", action: #selector(removeFades(_:)), keyEquivalent: "")
        addMenuItem(to: editMenu, title: "Remove Crossfades", action: #selector(removeCrossfades(_:)), keyEquivalent: "")
        editMenu.addItem(.separator())
        addMenuItem(to: editMenu, title: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "=")
        addMenuItem(to: editMenu, title: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        addMenuItem(to: editMenu, title: "Toggle Snapping", action: #selector(toggleSnapping(_:)), keyEquivalent: "n")
        addMenuItem(to: editMenu, title: "Follow Playhead", action: #selector(toggleFollowPlayhead(_:)), keyEquivalent: "")
        addMenuItem(to: editMenu, title: "Loop Range", action: #selector(toggleLoopRange(_:)), keyEquivalent: "")
        editMenu.addItem(.separator())
        addMenuItem(to: editMenu, title: "Set In Point", action: #selector(setInPoint(_:)), keyEquivalent: "")
        addMenuItem(to: editMenu, title: "Set Out Point", action: #selector(setOutPoint(_:)), keyEquivalent: "")
        addMenuItem(to: editMenu, title: "Clear In/Out Range", action: #selector(clearInOutRange(_:)), keyEquivalent: "")
        addMenuItem(to: editMenu, title: "Add Marker", action: #selector(addMarker(_:)), keyEquivalent: "m")
        addMenuItem(to: editMenu, title: "Previous Marker", action: #selector(jumpToPreviousMarker(_:)), keyEquivalent: "")
        addMenuItem(to: editMenu, title: "Next Marker", action: #selector(jumpToNextMarker(_:)), keyEquivalent: "")
        addMenuItem(to: editMenu, title: "Previous Clip Edge", action: #selector(jumpToPreviousClipEdge(_:)), keyEquivalent: "")
        addMenuItem(to: editMenu, title: "Next Clip Edge", action: #selector(jumpToNextClipEdge(_:)), keyEquivalent: "")
        addMenuItem(to: editMenu, title: "Jump to Project Start", action: #selector(jumpToProjectStart(_:)), keyEquivalent: "")
        addMenuItem(to: editMenu, title: "Jump to Project End", action: #selector(jumpToProjectEnd(_:)), keyEquivalent: "")
        addMenuItem(to: editMenu, title: "Nudge Left", action: #selector(nudgeLeft(_:)), keyEquivalent: "\u{F702}")
        addMenuItem(to: editMenu, title: "Nudge Right", action: #selector(nudgeRight(_:)), keyEquivalent: "\u{F703}")
        editItem.submenu = editMenu

        let trackItem = NSMenuItem()
        mainMenu.addItem(trackItem)
        let trackMenu = NSMenu(title: "Track")
        addMenuItem(to: trackMenu, title: "Add Track", action: #selector(addTrack(_:)), keyEquivalent: "t")
        trackItem.submenu = trackMenu

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        addMenuItem(to: viewMenu, title: "Reset Window Layout", action: #selector(resetWindowLayout(_:)), keyEquivalent: "0")
        addMenuItem(to: viewMenu, title: "Zoom to Fit Project", action: #selector(zoomToFitProject(_:)), keyEquivalent: "")
        addMenuItem(to: viewMenu, title: "Increase Track Height", action: #selector(increaseTrackHeight(_:)), keyEquivalent: "")
        addMenuItem(to: viewMenu, title: "Decrease Track Height", action: #selector(decreaseTrackHeight(_:)), keyEquivalent: "")
        addMenuItem(to: viewMenu, title: "Reset Track Height", action: #selector(resetTrackHeight(_:)), keyEquivalent: "")
        viewItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }

    @discardableResult
    private func addMenuItem(to menu: NSMenu, title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func newProject(_ sender: Any?) { mainWindowController?.newProject(sender) }
    @objc private func openProject(_ sender: Any?) { mainWindowController?.openProject(sender) }
    @objc private func saveProject(_ sender: Any?) { mainWindowController?.saveProject(sender) }
    @objc private func saveProjectAs(_ sender: Any?) { mainWindowController?.saveProjectAs(sender) }
    @objc private func importMedia(_ sender: Any?) { mainWindowController?.importMedia(sender) }
    @objc private func exportTimeline(_ sender: Any?) { mainWindowController?.exportTimeline(sender) }
    @objc private func collectProjectMedia(_ sender: Any?) { mainWindowController?.collectProjectMedia(sender) }
    @objc private func relinkMissingMedia(_ sender: Any?) { mainWindowController?.relinkMissingMedia(sender) }
    @objc private func locateMissingMediaFolder(_ sender: Any?) { mainWindowController?.locateMissingMediaFolder(sender) }
    @objc private func removeUnusedMedia(_ sender: Any?) { mainWindowController?.removeUnusedMedia(sender) }
    @objc private func regenerateAllWaveforms(_ sender: Any?) { mainWindowController?.regenerateAllWaveforms(sender) }
    @objc private func regenerateFailedWaveforms(_ sender: Any?) { mainWindowController?.regenerateFailedWaveforms(sender) }
    @objc private func regenerateAllVideoProxies(_ sender: Any?) { mainWindowController?.regenerateAllVideoProxies(sender) }
    @objc private func deleteSelectedClip(_ sender: Any?) { mainWindowController?.deleteSelectedClip(sender) }
    @objc private func rippleDeleteSelectedClips(_ sender: Any?) { mainWindowController?.rippleDeleteSelectedClips(sender) }
    @objc private func applyFadeIn(_ sender: Any?) { mainWindowController?.applyFadeIn(sender) }
    @objc private func applyFadeOut(_ sender: Any?) { mainWindowController?.applyFadeOut(sender) }
    @objc private func applyCrossfade(_ sender: Any?) { mainWindowController?.applyCrossfade(sender) }
    @objc private func removeFades(_ sender: Any?) { mainWindowController?.removeFades(sender) }
    @objc private func removeCrossfades(_ sender: Any?) { mainWindowController?.removeCrossfades(sender) }
    @objc private func copySelectedClips(_ sender: Any?) { mainWindowController?.copySelectedClips(sender) }
    @objc private func cutSelectedClips(_ sender: Any?) { mainWindowController?.cutSelectedClips(sender) }
    @objc private func pasteClips(_ sender: Any?) { mainWindowController?.pasteClips(sender) }
    @objc private func duplicateSelectedClip(_ sender: Any?) { mainWindowController?.duplicateSelectedClip(sender) }
    @objc private func toggleRazorTool(_ sender: Any?) { mainWindowController?.toggleRazorTool(sender) }
    @objc private func addTrack(_ sender: Any?) { mainWindowController?.addTrack(sender) }
    @objc private func zoomIn(_ sender: Any?) { mainWindowController?.zoomIn(sender) }
    @objc private func zoomOut(_ sender: Any?) { mainWindowController?.zoomOut(sender) }
    @objc private func toggleSnapping(_ sender: Any?) { mainWindowController?.toggleSnapping(sender) }
    @objc private func toggleFollowPlayhead(_ sender: Any?) { mainWindowController?.toggleFollowPlayhead(sender) }
    @objc private func toggleLoopRange(_ sender: Any?) { mainWindowController?.toggleLoopRange(sender) }
    @objc private func setInPoint(_ sender: Any?) { mainWindowController?.setInPoint(sender) }
    @objc private func setOutPoint(_ sender: Any?) { mainWindowController?.setOutPoint(sender) }
    @objc private func clearInOutRange(_ sender: Any?) { mainWindowController?.clearInOutRange(sender) }
    @objc private func addMarker(_ sender: Any?) { mainWindowController?.addMarker(sender) }
    @objc private func nudgeLeft(_ sender: Any?) { mainWindowController?.nudgeLeft(sender) }
    @objc private func nudgeRight(_ sender: Any?) { mainWindowController?.nudgeRight(sender) }
    @objc private func resetWindowLayout(_ sender: Any?) { mainWindowController?.resetWindowLayout(sender) }
    @objc private func zoomToFitProject(_ sender: Any?) { mainWindowController?.zoomToFitProject(sender) }
    @objc private func increaseTrackHeight(_ sender: Any?) { mainWindowController?.increaseTrackHeight(sender) }
    @objc private func decreaseTrackHeight(_ sender: Any?) { mainWindowController?.decreaseTrackHeight(sender) }
    @objc private func resetTrackHeight(_ sender: Any?) { mainWindowController?.resetTrackHeight(sender) }
    @objc private func jumpToProjectStart(_ sender: Any?) { mainWindowController?.jumpToProjectStart(sender) }
    @objc private func jumpToProjectEnd(_ sender: Any?) { mainWindowController?.jumpToProjectEnd(sender) }
    @objc private func jumpToPreviousMarker(_ sender: Any?) { mainWindowController?.jumpToPreviousMarker(sender) }
    @objc private func jumpToNextMarker(_ sender: Any?) { mainWindowController?.jumpToNextMarker(sender) }
    @objc private func jumpToPreviousClipEdge(_ sender: Any?) { mainWindowController?.jumpToPreviousClipEdge(sender) }
    @objc private func jumpToNextClipEdge(_ sender: Any?) { mainWindowController?.jumpToNextClipEdge(sender) }

    @objc private func showAbout(_ sender: Any?) {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info["CFBundleVersion"] as? String ?? "Unknown"
        let credits = NSAttributedString(
            string: "Lightweight, non-destructive multitrack audio editing for macOS.",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .version: "Version \(version) (\(build))",
            .credits: credits
        ])
    }

    @objc private func showPreferences(_ sender: Any?) {
        let controller = preferencesWindowController ?? PreferencesWindowController { [weak self] completion in
            guard let windowController = self?.mainWindowController else {
                completion(.failure(NSError(domain: "LightAudio", code: 70, userInfo: [NSLocalizedDescriptionKey: "The main window is not available."])))
                return
            }
            windowController.clearApplicationCaches(completion: completion)
        }
        preferencesWindowController = controller
        controller.showWindow(sender)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}
