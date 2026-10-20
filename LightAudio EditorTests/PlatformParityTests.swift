import XCTest
import AVFoundation
import AppKit
@testable import LightAudio_Editor

final class PlatformParityTests: XCTestCase {
    private var root: URL!
    private var recovery: AutosaveRecoveryService!
    private var controller: ProjectController!
    private var history: UndoManager!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LAE-Parity-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        recovery = AutosaveRecoveryService(recoveryDirectory: root.appendingPathComponent("Recovery"))
        history = UndoManager(); history.groupsByEvent = false
        controller = ProjectController(recoveryService: recovery,
            proxyService: MediaProxyService(proxyDirectory: root.appendingPathComponent("Proxies")),
            undoManagerProvider: { [weak self] in self?.history })
    }
    override func tearDownWithError() throws {
        controller.newProject(); recovery.stop(); controller = nil; recovery = nil
        try? FileManager.default.removeItem(at: root)
    }
    private func finalAuditPCM(_ name: String = "tone.caf", frames: Int = 44100, rate: Double = 44100,
                               channels: UInt32 = 2, sample: (Int, Int) -> Float = { _, _ in 0.2 }) throws -> URL {
        let url = root.appendingPathComponent(name)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames)))
        buffer.frameLength = UInt32(frames)
        for c in 0..<Int(channels) { for f in 0..<frames { buffer.floatChannelData![c][f] = sample(c, f) } }
        try file.write(from: buffer)
        return url
    }
    private func pcm(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length)))
        try file.read(into: buffer); return buffer
    }
    private func project(_ url: URL) throws -> Project {
        let metadata = try MediaImportService().metadata(for: url)
        let asset = MediaAsset(displayName: url.lastPathComponent, originalPath: url.path, relativePath: nil,
            kind: .audio, metadata: metadata, waveformCacheKey: nil)
        var p = Project.empty(name: "Parity")
        p.assets = [asset]
        p.timeline.tracks[0].clips = [Clip(sourceAssetID: asset.id, timelineStart: 0, sourceStart: 0, sourceEnd: metadata.duration)]
        p.recalculateDuration(); return p
    }
    private func load(_ p: Project) {
        XCTAssertTrue(controller.restore(snapshot: .init(createdAt: Date(), originalProjectURL: nil, project: p)))
        history.removeAllActions()
    }
    private func render(_ p: Project, rate: Double = 44100, channels: UInt32 = 2) throws -> AVAudioPCMBuffer {
        let output = root.appendingPathComponent("\(UUID()).wav")
        _ = try NativeAudioExportBackend().export(project: p, settings: .init(format: .wav, sampleRate: rate,
            channelCount: Int(channels), bitrate: nil, outputURL: output), cancellationToken: .init(), progress: { _ in })
        return try pcm(output)
    }
    private func assertSamplesEqual(_ a: AVAudioPCMBuffer, _ b: AVAudioPCMBuffer, tolerance: Float = 0.000002,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.frameLength, b.frameLength, file: file, line: line)
        var error: Float = 0
        for c in 0..<Int(min(a.format.channelCount, b.format.channelCount)) {
            for f in 0..<Int(min(a.frameLength, b.frameLength)) {
                error = max(error, abs(a.floatChannelData![c][f] - b.floatChannelData![c][f]))
            }
        }
        XCTAssertLessThanOrEqual(error, tolerance, file: file, line: line)
    }
    private func waitForPreparation() {
        wait(for: [expectation(for: NSPredicate { _, _ in
            !self.controller.project.assets.contains { $0.isVerifyingSource || ($0.requiresAudioPreparation && $0.proxyStatus != .ready) }
        }, evaluatedWith: nil)], timeout: 20)
    }

    func testMonoExportIsFoldDownOfPannedStereoWithAutomation() throws {
        for count: UInt32 in [1, 2] {
            var p = try project(finalAuditPCM("\(count).caf", channels: count) { c, _ in c == 0 ? 0.4 : 0.2 })
            p.timeline.tracks[0].pan = 0.15
            p.timeline.tracks[0].clips[0].pan = 0.25
            p.timeline.tracks[0].clips[0].panAutomationKeyframes = [.init(time: 0, pan: -80), .init(time: 1, pan: 60)]
            let stereo = try render(p), mono = try render(p, channels: 1)
            var error: Float = 0
            for f in 0..<Int(mono.frameLength) {
                error = max(error, abs(mono.floatChannelData![0][f] -
                    (stereo.floatChannelData![0][f] + stereo.floatChannelData![1][f]) * 0.5))
            }
            XCTAssertLessThan(error, 0.000002)
        }
    }

    func testResampledSplitsPreserveSignalInBothRateDirections() throws {
        for (sourceRate, outputRate) in [(44100.0, 48000.0), (48000.0, 44100.0)] {
            let url = try finalAuditPCM("\(sourceRate).caf", frames: Int(sourceRate), rate: sourceRate) { _, frame in
                Float(0.3 * sin(Double(frame) * 0.14))
            }
            let p = try project(url), before = try render(p, rate: outputRate)
            load(p)
            controller.splitClip(p.timeline.tracks[0].clips[0].id, at: 0.137)
            controller.splitClip(try XCTUnwrap(controller.selectedClipID), at: 0.619)
            assertSamplesEqual(before, try render(controller.project, rate: outputRate))
        }
    }

    func testSplitInsideEveryFadeCurveRoundTripsAndUndoes() throws {
        let base = try project(finalAuditPCM())
        for curve in FadeCurve.allCases {
            var p = base
            p.timeline.tracks[0].clips[0].fadeIn = Fade(duration: 0.8, curve: curve)
            p.timeline.tracks[0].clips[0].fadeOut = Fade(duration: 0.7, curve: curve)
            load(p); let before = try render(p)
            controller.splitClip(p.timeline.tracks[0].clips[0].id, at: 0.37)
            XCTAssertEqual(controller.project.requiredFormatVersion, 2)
            assertSamplesEqual(before, try render(controller.project))
            let url = root.appendingPathComponent("\(curve.rawValue).liau")
            XCTAssertTrue(controller.save(to: url))
            let reopened = try ProjectFileService().load(from: url).0
            XCTAssertEqual(reopened.formatVersion, 2)
            assertSamplesEqual(before, try render(reopened))
            history.undo(); XCTAssertEqual(controller.project.timeline.tracks[0].clips.count, 1)
            assertSamplesEqual(before, try render(controller.project))
            history.redo(); assertSamplesEqual(before, try render(controller.project))
        }
    }

    func testSplitCrossfadePreservesMixAndVersionThree() throws {
        var p = try project(finalAuditPCM())
        let first = p.timeline.tracks[0].clips[0]
        let second = Clip(sourceAssetID: first.sourceAssetID, timelineStart: 0.4, sourceStart: 0, sourceEnd: 1)
        p.timeline.tracks[0].clips.append(second)
        p.timeline.crossfades = [.init(leadingClipID: first.id, trailingClipID: second.id, startTime: 0.4, duration: 0.6)]
        p.recalculateDuration(); load(p)
        let before = try render(p)
        controller.splitClip(first.id, at: 0.65)
        XCTAssertEqual(controller.project.requiredFormatVersion, 3)
        assertSamplesEqual(before, try render(controller.project))
        let url = root.appendingPathComponent("crossfade.liau")
        XCTAssertTrue(controller.save(to: url))
        let reopened = try ProjectFileService().load(from: url).0
        XCTAssertEqual(reopened.formatVersion, 3)
        assertSamplesEqual(before, try render(reopened))
    }

    func testMinimumNormalizationAndCancellationPreserveSamplesAndUndo() throws {
        let p = try project(finalAuditPCM())
        load(p); let id = p.timeline.tracks[0].clips[0].id
        let done = expectation(description: "Normalize -60 dBFS")
        controller.normalizeClip(clipID: id, targetPeakDB: -60) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(controller.project.timeline.tracks[0].clips[0].gain, 0.005, accuracy: 0.000001)
        let normalized = try render(controller.project)
        withExtendedLifetime(normalized) {
            XCTAssertEqual(normalized.floatChannelData![0][100], 0.001, accuracy: 0.000001)
        }
        history.undo(); XCTAssertEqual(controller.project.timeline.tracks[0].clips[0].gain, 1)
        let token = ExportCancellationToken(); token.cancel()
        let cancelled = expectation(description: "Cancelled normalization")
        controller.normalizeClip(clipID: id, targetPeakDB: -6, cancellationToken: token) { result in
            if case .success = result { XCTFail("Cancellation published an edit") }; cancelled.fulfill()
        }
        wait(for: [cancelled], timeout: 10)
        XCTAssertEqual(controller.project.timeline.tracks[0].clips[0].gain, 1)
    }

    func testDeferredAndFailedRecoveryRetainSnapshotUntilSuccessfulRestore() throws {
        let document = root.appendingPathComponent("recovery.liau")
        var p = Project.empty(); try ProjectFileService().save(p, to: document)
        p.name = "Unsaved edits"
        let snapshot = ProjectRecoverySnapshot(createdAt: Date(), sessionID: UUID(), originalProjectURL: document, project: p)
        let url = root.appendingPathComponent("Recovery/pending.recovery.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ProjectFileService().encodeRecovery(snapshot, to: url)
        recovery.markSnapshotPending(url: url, snapshot: snapshot)
        let flow = CrashRecoveryController(recoveryService: recovery)
        XCTAssertFalse(flow.resolve(.cancel, url: url, snapshot: snapshot, openSaved: { _ in XCTFail(); return true }, restore: { _ in XCTFail(); return true }))
        XCTAssertFalse(flow.resolve(.restore, url: url, snapshot: snapshot, openSaved: { _ in false }, restore: { _ in false }))
        XCTAssertFalse(flow.resolve(.lastSaved, url: url, snapshot: snapshot, openSaved: { _ in false }, restore: { _ in true }))
        recovery.markSessionStarted(); recovery.markCleanShutdown()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(recovery.latestRecoverableSnapshot())
        XCTAssertTrue(flow.resolve(.restore, url: url, snapshot: snapshot, openSaved: { _ in false }, restore: {
            self.controller.restore(snapshot: $0) && self.controller.save(to: document)
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try ProjectFileService().load(from: document).0.name, "Unsaved edits")
    }

    func testLoopChunksRepeatExactlyIncludingSilenceAndTinyRanges() throws {
        let p = try project(finalAuditPCM() { _, f in f < 22050 ? 0.1 : 0.2 })
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let range = (start: 0.8, end: 1.2)
        let renderer = try LoopPCMRenderer(project: p, track: p.timeline.tracks[0], format: format, from: 0.9, range: range)
        let output = try renderer.render(frameCount: 44100)
        for f in 0..<44100 {
            let frame = 35280 + (4410 + f) % 17640
            XCTAssertEqual(output.floatChannelData![0][f], frame < 44100 ? 0.2 : 0, accuracy: 0.000001)
        }
        let chunks = try LoopPCMRenderer(project: p, track: p.timeline.tracks[0], format: format, from: 0.9, range: range)
        var offset = 0
        while offset < 44100 {
            let count = min(997, 44100 - offset), buffer = try chunks.render(frameCount: UInt32(count))
            for f in 0..<count { XCTAssertEqual(buffer.floatChannelData![0][f], output.floatChannelData![0][offset + f]) }
            offset += count
        }
        let tiny = try LoopPCMRenderer(project: p, track: p.timeline.tracks[0], format: format, from: 0, range: (0, 1 / 44100))
        let repeated = try tiny.render(frameCount: 16000)
        XCTAssertEqual(tiny.cachedFrameCount, 1)
        XCTAssertEqual(repeated.floatChannelData![0][15999], 0.1)
    }

    func testLoopPlaybackDoesNotRestartAtBoundaries() throws {
        let p = try project(finalAuditPCM() { _, _ in 0.01 })
        let engine = AudioPlaybackEngine()
        defer { engine.stop() }
        engine.onPlaybackBoundary = { _ in XCTFail("Continuous loop reached stop/restart callback") }
        let started = expectation(description: "Loop playback")
        engine.playLoop(project: p, from: 0, range: (0, 0.02)) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }; started.fulfill()
        }
        wait(for: [started], timeout: 10)
        let running = expectation(description: "Several loop periods")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertTrue(engine.isPlaying)
            XCTAssertGreaterThanOrEqual(engine.currentTime, 0); XCTAssertLessThan(engine.currentTime, 0.02)
            running.fulfill()
        }
        wait(for: [running], timeout: 2)
    }

    func testAutomationEditsUndoLocksAndSaveReopen() throws {
        let p = try project(finalAuditPCM()); load(p)
        let clip = p.timeline.tracks[0].clips[0].id, track = p.timeline.tracks[0].id
        controller.addPanKeyframe(clipID: clip, time: 0, pan: -100)
        controller.addPanKeyframe(clipID: clip, time: 1, pan: 100)
        controller.addTrackVolumeKeyframe(trackID: track, time: 0, gainDB: -12)
        XCTAssertEqual(controller.project.timeline.tracks[0].volumeAutomationKeyframes.count, 1)
        history.undo(); XCTAssertTrue(controller.project.timeline.tracks[0].volumeAutomationKeyframes.isEmpty)
        history.redo()
        let before = try render(controller.project)
        controller.toggleLock(trackID: track)
        controller.clearPanAutomation(clipID: clip); controller.clearTrackVolumeAutomation(trackID: track)
        XCTAssertEqual(controller.project.timeline.tracks[0].clips[0].panAutomationKeyframes.count, 2)
        XCTAssertEqual(controller.project.timeline.tracks[0].volumeAutomationKeyframes.count, 1)
        let url = root.appendingPathComponent("automation.liau")
        XCTAssertTrue(controller.save(to: url))
        assertSamplesEqual(before, try render(ProjectFileService().load(from: url).0))
    }

    func testIndependentCopyOwnsUnusedMediaAndGetsNewIdentity() throws {
        let source = try finalAuditPCM()
        var p = try project(source)
        let unused = try project(finalAuditPCM("unused.caf") { _, _ in 0.1 }).assets[0]
        p.assets.append(unused)
        let bytes = try Data(contentsOf: source)
        let url = try controller.saveIndependentCopy(snapshot: .init(project: p, projectURL: nil), to: root, name: "Independent")
        let copied = try ProjectFileService().load(from: url).0
        XCTAssertNotEqual(copied.id, p.id)
        XCTAssertEqual(copied.assets.count, 2)
        XCTAssertEqual(copied.assets.map(\.id), p.assets.map(\.id))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.removeItem(at: XCTUnwrap(unused.resolvedURL))
        let reopened = try ProjectFileService().load(from: url)
        XCTAssertTrue(reopened.1.isEmpty)
        let rendered = try render(reopened.0)
        withExtendedLifetime(rendered) {
            XCTAssertEqual(rendered.floatChannelData![0][100], 0.2, accuracy: 0.000001)
        }
    }

    func testImportDeduplicatesIdenticalContentAcrossPaths() throws {
        let a = try finalAuditPCM(), b = root.appendingPathComponent("copy.caf")
        try FileManager.default.copyItem(at: a, to: b)
        let first = expectation(description: "First import")
        controller.importMediaToLibrary(url: a) { result in
            guard case .imported = result else { XCTFail(); first.fulfill(); return }; first.fulfill()
        }
        wait(for: [first], timeout: 10)
        let second = expectation(description: "Duplicate import")
        controller.importMediaToLibrary(url: b) { result in
            guard case .duplicate = result else { XCTFail(); second.fulfill(); return }; second.fulfill()
        }
        wait(for: [second], timeout: 10)
        XCTAssertEqual(controller.project.assets.count, 1)
    }

    func testColdOpenVerifiesInBackgroundAndRejectsChangedSource() throws {
        let p = try project(finalAuditPCM()), url = root.appendingPathComponent("cold.liau")
        try ProjectFileService().save(p, to: url); FileMetadataHasher.clearVerificationCache()
        XCTAssertTrue(controller.open(url: url))
        XCTAssertTrue(controller.project.assets[0].isVerifyingSource)
        waitForPreparation()
        XCTAssertFalse(controller.project.hasMissingAssets)
        XCTAssertFalse(controller.isDirty)
        _ = try finalAuditPCM() { _, _ in 0.3 }
        _ = controller.refreshMediaAvailability()
        wait(for: [expectation(for: NSPredicate { _, _ in !self.controller.project.assets[0].isVerifyingSource }, evaluatedWith: nil)], timeout: 10)
        XCTAssertTrue(controller.project.assets[0].isMissing)
    }

    func testCustomExportRangeRejectsInvalidValues() {
        XCTAssertEqual(ExportRange.parsedTimeRange(start: "0,125", end: "0.5", projectDuration: 1), .timeRange(start: 0.125, end: 0.5))
        for (a, b) in [("-1", "1"), ("0", "NaN"), ("1", "0"), ("0", "1.5"), ("", "1")] {
            XCTAssertNil(ExportRange.parsedTimeRange(start: a, end: b, projectDuration: 1))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testAutomationPanelNumericEditingAndLockState() throws {
        let p = try project(finalAuditPCM()); load(p)
        let id = p.timeline.tracks[0].clips[0].id
        for target in [AutomationTarget.clipPan(id), .trackVolume(p.timeline.tracks[0].id)] {
            let panel = AutomationEditorController(controller: controller, target: target)
            defer { panel.close() }
            let content = try XCTUnwrap(panel.window?.contentView)
            content.layoutSubtreeIfNeeded()
            let views = descendants(content)
            let time = try XCTUnwrap(views.first { $0.identifier?.rawValue == "automation.time" } as? NSTextField)
            let value = try XCTUnwrap(views.first { $0.identifier?.rawValue == "automation.value" } as? NSTextField)
            let add = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == L10n.tr("Add Point") })
            time.stringValue = "0.25"; value.stringValue = target.isPan ? "-50" : "-6"
            add.performClick(nil)
            if target.isPan {
                XCTAssertEqual(controller.project.timeline.tracks[0].clips[0].panAutomationKeyframes.first?.pan, -50)
            } else {
                XCTAssertEqual(controller.project.timeline.tracks[0].volumeAutomationKeyframes.first?.gainDB, -6)
            }
            XCTAssertGreaterThan(time.frame.width, 0)
            let graph = try XCTUnwrap(views.first { $0.identifier?.rawValue == "automation.graph" })
            XCTAssertGreaterThan(graph.frame.height, 150)
            controller.toggleLock(trackID: p.timeline.tracks[0].id); panel.refresh()
            XCTAssertFalse(add.isEnabled)
            controller.toggleLock(trackID: p.timeline.tracks[0].id)
        }
    }

    func testExportPanelCustomRangeControlsValidateAndSubmit() throws {
        let p = try project(finalAuditPCM())
        let parent = NSWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        var submitted: ExportSettings?
        ExportPanelController.show(window: parent, project: p) { submitted = $0 }
        let sheet = try XCTUnwrap(parent.attachedSheet), content = try XCTUnwrap(sheet.contentView)
        defer { if sheet.sheetParent != nil { parent.endSheet(sheet) } }
        content.layoutSubtreeIfNeeded()
        let views = descendants(content)
        let popup = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains(L10n.tr("Custom Range")) })
        let start = try XCTUnwrap(views.first { $0.identifier?.rawValue == "export.start" } as? NSTextField)
        let end = try XCTUnwrap(views.first { $0.identifier?.rawValue == "export.end" } as? NSTextField)
        let export = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == L10n.tr("Export") })
        XCTAssertFalse(start.isEnabled)
        popup.selectItem(at: 2); NSApp.sendAction(try XCTUnwrap(popup.action), to: popup.target, from: popup)
        XCTAssertTrue(start.isEnabled); XCTAssertTrue(end.isEnabled)
        start.stringValue = "0.75"; end.stringValue = "0.25"
        start.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: start))
        XCTAssertFalse(export.isEnabled)
        start.stringValue = "0.25"; end.stringValue = "0.75"
        end.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: end))
        XCTAssertTrue(export.isEnabled)
        export.performClick(nil)
        XCTAssertEqual(submitted?.range, .timeRange(start: 0.25, end: 0.75))
    }
}

extension PlatformParityTests {
    func testPreparationBudgetAndCancelledJobsKeepTheirSlotsUntilFinished() throws {
        let scheduler = MediaPreparationScheduler(limit: 2)
        var releases: [() -> Void] = []
        let started = expectation(description: "Two active workers"); started.expectedFulfillmentCount = 2
        let job = scheduler.submit { _, finish in DispatchQueue.main.async { releases.append(finish); started.fulfill() } }
        scheduler.submit { _, finish in DispatchQueue.main.async { releases.append(finish); started.fulfill() } }
        wait(for: [started], timeout: 5)
        let cancelledRan = expectation(description: "Cancelled pending work never starts"); cancelledRan.isInverted = true
        let cancelled = scheduler.submit { _, finish in cancelledRan.fulfill(); finish() }
        cancelled.cancel()
        let next = expectation(description: "Next work starts after actual completion")
        scheduler.submit { _, finish in finish(); next.fulfill() }
        job.cancel()
        XCTAssertEqual(scheduler.counts.active, 2, "Cancellation must not oversubscribe still-running work")
        XCTAssertEqual(scheduler.counts.pending, 1)
        releases[0](); releases[0]() // Duplicate finish cannot free another worker's slot.
        wait(for: [next], timeout: 5)
        releases[1]()
        wait(for: [cancelledRan], timeout: 0.1)
        XCTAssertEqual(scheduler.counts.active, 0)
        XCTAssertEqual(scheduler.counts.peak, 2)
    }
    private func containerFixture(codec: AudioFormatID = kAudioFormatAppleLossless, rate: Double = 44100,
                                  kind: String = "gap", fileExtension: String = "m4a") throws -> URL {
        let id = UUID().uuidString
        let source = try finalAuditPCM("\(id).wav", frames: Int(rate), rate: rate) { _, frame in
            let t = Double(frame) / rate
            if kind == "slow" || kind == "fast" || kind == "normal" || kind == "retimed-gap" {
                return Float(0.3 * sin(2 * .pi * 400 * t))
            }
            return t < 0.4 ? 0.1 : t < 0.6 ? 0.8 : 0.4
        }
        let encoded = root.appendingPathComponent("\(id)-encoded.m4a")
        do {
            let file = try AVAudioFile(forWriting: encoded, settings: [AVFormatIDKey: codec,
                AVSampleRateKey: rate, AVNumberOfChannelsKey: 2], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: pcm(source))
        }
        let av = AVURLAsset(url: encoded, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        defer { withExtendedLifetime(av) {} }
        let original = try XCTUnwrap(av.tracks(withMediaType: .audio).first)
        let composition = AVMutableComposition()
        let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        func time(_ t: Double) -> CMTime { CMTime(seconds: t, preferredTimescale: Int32(rate)) }
        func insert(_ start: Double, _ duration: Double, _ at: Double, into target: AVMutableCompositionTrack) throws {
            try target.insertTimeRange(CMTimeRange(start: time(start), duration: time(duration)), of: original, at: time(at))
        }
        switch kind {
        case "trim": try insert(0.15, 0.2, 0, into: track)
        case "gap":
            try insert(0, 0.4, 0, into: track); try insert(0.6, 0.4, 0.7, into: track)
        case "retimed-gap":
            try insert(0.1, 0.2, 0.3, into: track)
            track.scaleTimeRange(CMTimeRange(start: time(0.3), duration: time(0.2)), toDuration: time(0.4))
            try insert(0.6, 0.2, 1, into: track)
            track.scaleTimeRange(CMTimeRange(start: time(1), duration: time(0.2)), toDuration: time(0.1))
        default:
            try insert(0, 1, kind == "delay" ? 0.3 : 0, into: track)
            if kind == "slow" || kind == "fast" {
                track.scaleTimeRange(CMTimeRange(start: .zero, duration: time(1)), toDuration: time(kind == "slow" ? 2 : 0.5))
            }
            if kind == "multi" {
                let second = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
                try insert(0, 1, 0.5, into: second)
            }
        }
        let url = root.appendingPathComponent("\(id).\(fileExtension)")
        let writer = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        writer.outputURL = url; writer.outputFileType = fileExtension == "mov" ? .mov : .mp4
        let done = expectation(description: "Container fixture")
        writer.exportAsynchronously { done.fulfill() }; wait(for: [done], timeout: 15)
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "Fixture", code: 1) }
        return url
    }
    private func containerReference(_ url: URL) throws -> AVAudioPCMBuffer {
        let asset = AVURLAsset(url: url), reader = try AVAssetReader(asset: asset)
        let tracks = asset.tracks(withMediaType: .audio)
        let rate = 44100.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let frames = UInt32((asset.duration.seconds * rate).rounded())
        let reference = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        reference.frameLength = frames
        for c in 0..<2 { reference.floatChannelData![c].initialize(repeating: 0, count: Int(frames)) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2]
        let output: AVAssetReaderOutput = tracks.count == 1
            ? AVAssetReaderTrackOutput(track: tracks[0], outputSettings: settings)
            : AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        reader.add(output); XCTAssertTrue(reader.startReading())
        while let sample = output.copyNextSampleBuffer() {
            let f = AVAudioFormat(cmAudioFormatDescription: try XCTUnwrap(CMSampleBufferGetFormatDescription(sample)))
            let count = CMSampleBufferGetNumSamples(sample)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: f, frameCapacity: UInt32(count)))
            buffer.frameLength = UInt32(count)
            XCTAssertEqual(CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList), noErr)
            let start = Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * rate).rounded())
            for i in 0..<count where start + i >= 0 && start + i < Int(frames) {
                for c in 0..<2 { reference.floatChannelData![c][start + i] = f.isInterleaved ? buffer.floatChannelData![0][i * 2 + c] : buffer.floatChannelData![c][i] }
            }
        }
        XCTAssertEqual(reader.status, .completed)
        return reference
    }

    private func prepare(_ asset: MediaAsset) throws -> MediaAsset {
        let done = expectation(description: "Prepare container")
        var result: Result<MediaAsset, Error>?
        MediaProxyService(proxyDirectory: root.appendingPathComponent("M4AProxies")).prepareProxy(for: asset) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(result).get()
    }
    func testM4AEditsGapsDelayAndMultipleTracksMatchIndependentDecoder() throws {
        for codec in [kAudioFormatAppleLossless, kAudioFormatMPEG4AAC] {
            for kind in ["trim", "gap", "delay", "multi"] {
                let source = try containerFixture(codec: codec, kind: kind)
                let bytes = try Data(contentsOf: source), expected = try containerReference(source)
                var p = try project(source)
                XCTAssertTrue(p.assets[0].requiresAudioPreparation)
                p.assets[0] = try prepare(p.assets[0])
                let decoded = try pcm(XCTUnwrap(p.assets[0].audioSourceURL))
                assertSamplesEqual(expected, decoded, tolerance: 0.00001)
                p.mixState.masterVolumeDB = -6
                let before = try render(p)
                load(p); waitForPreparation()
                let url = root.appendingPathComponent("container.liau")
                XCTAssertTrue(controller.save(to: url))
                XCTAssertTrue(controller.open(url: url)); waitForPreparation()
                assertSamplesEqual(before, try render(controller.project))
                XCTAssertEqual(try Data(contentsOf: source), bytes)
            }
        }
    }
    func testRetimedM4APreservesLeadingAndInternalGaps() throws {
        let source = try containerFixture(codec: kAudioFormatMPEG4AAC, kind: "retimed-gap")
        var p = try project(source); p.assets[0] = try prepare(p.assets[0])
        let output = try render(p)
        for (time, silent) in [(0.15, true), (0.5, false), (0.85, true), (1.05, false)] {
            let start = Int(time * 44100), count = 400
            let energy = (start..<min(start + count, Int(output.frameLength))).reduce(0.0) { $0 + pow(Double(output.floatChannelData![0][$1]), 2) }
            if silent { XCTAssertEqual(energy, 0, accuracy: 0.000001) }
            else { XCTAssertGreaterThan(energy / Double(count), 0.01) }
        }
    }
}
