import XCTest
import AVFoundation
@testable import LightAudio_Editor

final class P2RegressionTests: XCTestCase {
    func testPanAutomationInterpolatesAcrossTheClip() {
        let clip = Clip(
            sourceAssetID: UUID(),
            timelineStart: 0,
            sourceStart: 0,
            sourceEnd: 2,
            panAutomationKeyframes: [
                ClipPanAutomationKeyframe(time: 0, pan: -100),
                ClipPanAutomationKeyframe(time: 2, pan: 100)
            ]
        )

        XCTAssertEqual(AutomationMath.panAutomation(for: clip, atClipTime: 0), -100, accuracy: 0.001)
        XCTAssertEqual(AutomationMath.panAutomation(for: clip, atClipTime: 0.5), -50, accuracy: 0.001)
        XCTAssertEqual(AutomationMath.panAutomation(for: clip, atClipTime: 1), 0, accuracy: 0.001)
        XCTAssertEqual(AutomationMath.panAutomation(for: clip, atClipTime: 1.5), 50, accuracy: 0.001)
        XCTAssertEqual(AutomationMath.panAutomation(for: clip, atClipTime: 2), 100, accuracy: 0.001)
    }

    func testNudgingMultipleSelectedClipsMovesTheGroup() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 1)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let recoveryService = AutosaveRecoveryService()
        defer { recoveryService.stop() }
        let controller = ProjectController(recoveryService: recoveryService)
        let imported = expectation(description: "Import source media")
        controller.importMediaToLibrary(url: sourceURL) { outcome in
            switch outcome {
            case .imported:
                break
            case .duplicate:
                XCTFail("The first import should not be treated as a duplicate.")
            case .alreadyImporting:
                XCTFail("The first import should not already be in progress.")
            case .failed(let error):
                XCTFail("Import failed: \(error.localizedDescription)")
            }
            imported.fulfill()
        }
        wait(for: [imported], timeout: 5)

        let asset = try XCTUnwrap(controller.project.assets.first)
        _ = controller.addAssetToTimeline(asset.id, at: 1, trackIndex: 0)
        let firstClipID = try XCTUnwrap(controller.project.timeline.tracks.first?.clips.first?.id)
        _ = controller.addAssetToTimeline(asset.id, at: 3, trackIndex: 0)
        let secondClipID = try XCTUnwrap(controller.project.timeline.tracks.first?.clips.last?.id)

        controller.selectClips([firstClipID, secondClipID], adding: false)
        controller.nudgeSelectedClip(by: 0.25)

        let starts = controller.project.timeline.tracks[0].clips
            .filter { [firstClipID, secondClipID].contains($0.id) }
            .map(\.timelineStart)
            .sorted()
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts[0], 1.25, accuracy: 0.0001)
        XCTAssertEqual(starts[1], 3.25, accuracy: 0.0001)
    }

    func testConcurrentImportOfTheSameFileAddsOneAsset() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 1)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let recoveryService = AutosaveRecoveryService()
        defer { recoveryService.stop() }
        let controller = ProjectController(recoveryService: recoveryService)
        let firstImport = expectation(description: "First import completes")
        let secondImport = expectation(description: "Second import is rejected while in flight")

        controller.importMediaToLibrary(url: sourceURL) { outcome in
            switch outcome {
            case .imported:
                break
            case .duplicate, .alreadyImporting:
                XCTFail("The first import should own the import operation.")
            case .failed(let error):
                XCTFail("Import failed: \(error.localizedDescription)")
            }
            firstImport.fulfill()
        }
        controller.importMediaToLibrary(url: sourceURL) { outcome in
            switch outcome {
            case .alreadyImporting:
                break
            case .imported, .duplicate:
                XCTFail("The second import should be held while the first one is in progress.")
            case .failed(let error):
                XCTFail("Import failed: \(error.localizedDescription)")
            }
            secondImport.fulfill()
        }

        wait(for: [firstImport, secondImport], timeout: 5)
        XCTAssertEqual(controller.project.assets.count, 1)
    }

    func testOnlyAudioEditsAdvanceRenderRevision() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 1)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let recoveryService = AutosaveRecoveryService()
        defer { recoveryService.stop() }
        let controller = ProjectController(recoveryService: recoveryService)
        let imported = expectation(description: "Import source media")
        controller.importMediaToLibrary(url: sourceURL) { outcome in
            if case .failed(let error) = outcome {
                XCTFail("Import failed: \(error.localizedDescription)")
            }
            imported.fulfill()
        }
        wait(for: [imported], timeout: 5)

        let asset = try XCTUnwrap(controller.project.assets.first)
        _ = controller.addAssetToTimeline(asset.id, at: 0, trackIndex: 0)
        let clipID = try XCTUnwrap(controller.project.timeline.tracks.first?.clips.first?.id)
        let revisionAfterPlacement = controller.audioRenderRevision

        controller.selectClip(clipID)
        controller.setPlayhead(0.25)
        XCTAssertEqual(controller.audioRenderRevision, revisionAfterPlacement)

        controller.setClipGain(0.5)
        XCTAssertEqual(controller.audioRenderRevision, revisionAfterPlacement + 1)
    }

    func testProjectLoadRejectsTrimOutsideSourceDuration() throws {
        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-Invalid-\(UUID().uuidString).liau")
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let asset = MediaAsset(
            displayName: "Short Source",
            originalPath: "/tmp/missing-short-source.wav",
            relativePath: nil,
            resolvedPath: nil,
            kind: .audio,
            metadata: MediaFileMetadata(fileName: "missing-short-source.wav", fileSize: nil, duration: 1, sampleRate: 44_100, channelCount: 1, checksum: nil),
            waveformCacheKey: nil
        )
        let invalidClip = Clip(sourceAssetID: asset.id, timelineStart: 0, sourceStart: 0, sourceEnd: 1.5)
        let project = Project(
            name: "Invalid Trim",
            sampleRate: 44_100,
            duration: 1.5,
            assets: [asset],
            timeline: Timeline(tracks: [Track(name: "A1", clips: [invalidClip])]),
            viewState: TimelineViewState(),
            lastSavedAt: nil
        )

        let fileService = ProjectFileService()
        try fileService.save(project, to: projectURL)
        XCTAssertThrowsError(try fileService.load(from: projectURL))
    }

    func testProjectSaveWritesCurrentFormatVersion() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LightAudio-Versioned-\(UUID().uuidString).liau")
        defer { try? FileManager.default.removeItem(at: projectURL) }

        try ProjectFileService().save(Project.empty(), to: projectURL)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: projectURL)) as? [String: Any]
        )

        XCTAssertEqual(object["formatVersion"] as? Int, Project.currentFormatVersion)
    }

    func testLegacyUnversionedProjectMigratesToFormatVersionOne() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LightAudio-Legacy-\(UUID().uuidString).liau")
        defer { try? FileManager.default.removeItem(at: projectURL) }

        try ProjectFileService().save(Project.empty(), to: projectURL)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: projectURL)) as? [String: Any]
        )
        object.removeValue(forKey: "formatVersion")
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: projectURL, options: .atomic)

        let (loaded, missing) = try ProjectFileService().load(from: projectURL)
        XCTAssertEqual(loaded.formatVersion, Project.currentFormatVersion)
        XCTAssertTrue(missing.isEmpty)
    }

    func testProjectLoadRejectsNewerFormatVersion() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LightAudio-Future-\(UUID().uuidString).liau")
        defer { try? FileManager.default.removeItem(at: projectURL) }

        try ProjectFileService().save(Project.empty(), to: projectURL)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: projectURL)) as? [String: Any]
        )
        object["formatVersion"] = Project.currentFormatVersion + 1
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: projectURL, options: .atomic)

        XCTAssertThrowsError(try ProjectFileService().load(from: projectURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("newer version"))
        }
    }

    func testTimelineRendererAppliesClipPanAutomation() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 1)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let clip = Clip(
            sourceAssetID: UUID(),
            timelineStart: 0,
            sourceStart: 0,
            sourceEnd: 1,
            panAutomationKeyframes: [
                ClipPanAutomationKeyframe(time: 0, pan: -100),
                ClipPanAutomationKeyframe(time: 1, pan: 100)
            ]
        )
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false))
        let source = try TimelineAudioSource(url: sourceURL)
        let buffer = try XCTUnwrap(source.renderClip(
            clip: clip,
            track: Track(name: "A1"),
            project: Project.empty(),
            timelineStart: 0,
            frameCount: 128,
            outputFormat: format
        ))
        let data = try XCTUnwrap(buffer.floatChannelData)

        XCTAssertGreaterThan(data[0][0], 0.45)
        XCTAssertLessThan(abs(data[1][0]), 0.001)
    }

    func testNativeExportAppliesMasterGainAfterTrackMix() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 1)
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-Export-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        let asset = MediaAsset(
            displayName: "Tone",
            originalPath: sourceURL.path,
            relativePath: nil,
            resolvedPath: sourceURL.path,
            kind: .audio,
            metadata: MediaFileMetadata(fileName: sourceURL.lastPathComponent, fileSize: nil, duration: 1, sampleRate: 44_100, channelCount: 1, checksum: nil),
            waveformCacheKey: nil
        )
        let clip = Clip(sourceAssetID: asset.id, timelineStart: 0, sourceStart: 0, sourceEnd: 1)
        let track = Track(name: "A1", clips: [clip])
        let project = Project(
            name: "Export Test",
            sampleRate: 44_100,
            duration: 1,
            assets: [asset],
            timeline: Timeline(tracks: [track]),
            mixState: MixState(masterVolumeDB: -6),
            viewState: TimelineViewState(),
            lastSavedAt: nil
        )
        let settings = ExportSettings(
            format: .wav,
            sampleRate: 44_100,
            channelCount: 2,
            bitrate: nil,
            outputURL: outputURL,
            range: .entireProject
        )

        _ = try NativeAudioExportBackend().export(
            project: project,
            settings: settings,
            cancellationToken: ExportCancellationToken(),
            progress: { _ in }
        )

        let output = try AVAudioFile(forReading: outputURL)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 1_024))
        try output.read(into: buffer, frameCount: 1_024)
        let data = try XCTUnwrap(buffer.floatChannelData)
        let expectedPeak = Float(0.5 * cos(Double.pi / 4) * MixMath.linearGain(forDB: -6))

        XCTAssertEqual(data[0][0], expectedPeak, accuracy: 0.02)
        XCTAssertEqual(data[1][0], expectedPeak, accuracy: 0.02)
    }

    func testNativeExportRefusesExistingOutputWithoutExplicitApproval() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 0.1)
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-Existing-\(UUID().uuidString).wav")
        let originalOutput = Data("Keep this export".utf8)
        try originalOutput.write(to: outputURL)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        let asset = MediaAsset(
            displayName: "Tone",
            originalPath: sourceURL.path,
            relativePath: nil,
            resolvedPath: sourceURL.path,
            kind: .audio,
            metadata: MediaFileMetadata(fileName: sourceURL.lastPathComponent, fileSize: nil, duration: 0.1, sampleRate: 44_100, channelCount: 1, checksum: nil),
            waveformCacheKey: nil
        )
        let clip = Clip(sourceAssetID: asset.id, timelineStart: 0, sourceStart: 0, sourceEnd: 0.1)
        let project = Project(
            name: "Existing Output",
            sampleRate: 44_100,
            duration: 0.1,
            assets: [asset],
            timeline: Timeline(tracks: [Track(name: "A1", clips: [clip])]),
            viewState: TimelineViewState(),
            lastSavedAt: nil
        )
        let settings = ExportSettings(
            format: .wav,
            sampleRate: 44_100,
            channelCount: 2,
            bitrate: nil,
            outputURL: outputURL
        )

        XCTAssertThrowsError(
            try NativeAudioExportBackend().export(
                project: project,
                settings: settings,
                cancellationToken: ExportCancellationToken(),
                progress: { _ in }
            )
        ) { error in
            XCTAssertEqual((error as NSError).domain, "LightAudioExport")
        }
        XCTAssertEqual(try Data(contentsOf: outputURL), originalOutput)

        let approvedSettings = ExportSettings(
            format: .wav,
            sampleRate: 44_100,
            channelCount: 2,
            bitrate: nil,
            outputURL: outputURL,
            overwriteExisting: true
        )
        _ = try NativeAudioExportBackend().export(
            project: project,
            settings: approvedSettings,
            cancellationToken: ExportCancellationToken(),
            progress: { _ in }
        )
        XCTAssertNotEqual(try Data(contentsOf: outputURL), originalOutput)
        XCTAssertNoThrow(try AVAudioFile(forReading: outputURL))
    }

    func testNativeExportRefusesToOverwriteImportedSourceEvenWhenApproved() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 0.1)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let asset = MediaAsset(
            displayName: "Tone",
            originalPath: sourceURL.path,
            relativePath: nil,
            resolvedPath: sourceURL.path,
            kind: .audio,
            metadata: MediaFileMetadata(fileName: sourceURL.lastPathComponent, fileSize: nil, duration: 0.1, sampleRate: 44_100, channelCount: 1, checksum: nil),
            waveformCacheKey: nil
        )
        let clip = Clip(sourceAssetID: asset.id, timelineStart: 0, sourceStart: 0, sourceEnd: 0.1)
        let project = Project(
            name: "Protected Source",
            sampleRate: 44_100,
            duration: 0.1,
            assets: [asset],
            timeline: Timeline(tracks: [Track(name: "A1", clips: [clip])]),
            viewState: TimelineViewState(),
            lastSavedAt: nil
        )
        let settings = ExportSettings(
            format: .wav,
            sampleRate: 44_100,
            channelCount: 2,
            bitrate: nil,
            outputURL: sourceURL,
            overwriteExisting: true
        )

        XCTAssertThrowsError(
            try NativeAudioExportBackend().export(
                project: project,
                settings: settings,
                cancellationToken: ExportCancellationToken(),
                progress: { _ in }
            )
        ) { error in
            let exportError = error as NSError
            XCTAssertEqual(exportError.domain, "LightAudioExport")
            XCTAssertEqual(exportError.code, 41)
        }

        let source = try AVAudioFile(forReading: sourceURL)
        XCTAssertGreaterThan(source.length, 0)
    }

    func testSplitClipKeepsFadesOnOriginalOuterEdges() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 2)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let recoveryService = AutosaveRecoveryService()
        defer { recoveryService.stop() }
        let controller = ProjectController(recoveryService: recoveryService)
        let imported = expectation(description: "Import source media")
        controller.importMediaToLibrary(url: sourceURL) { outcome in
            if case .failed(let error) = outcome {
                XCTFail("Import failed: \(error.localizedDescription)")
            }
            imported.fulfill()
        }
        wait(for: [imported], timeout: 5)

        let asset = try XCTUnwrap(controller.project.assets.first)
        _ = controller.addAssetToTimeline(asset.id, at: 0, trackIndex: 0)
        let clipID = try XCTUnwrap(controller.project.timeline.tracks.first?.clips.first?.id)
        controller.selectClip(clipID)
        controller.setClipFadeIn(0.4)
        controller.setClipFadeOut(0.5)

        controller.splitClip(clipID, at: 1)

        let clips = controller.project.timeline.tracks[0].clips.sorted { $0.timelineStart < $1.timelineStart }
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].fadeIn.duration, 0.4, accuracy: 0.0001)
        XCTAssertEqual(clips[0].fadeOut.duration, 0, accuracy: 0.0001)
        XCTAssertEqual(clips[1].fadeIn.duration, 0, accuracy: 0.0001)
        XCTAssertEqual(clips[1].fadeOut.duration, 0.5, accuracy: 0.0001)
    }

    func testDuplicatingTrackCopiesCrossfadesForDuplicatedClips() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 2)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let recoveryService = AutosaveRecoveryService()
        defer { recoveryService.stop() }
        let controller = ProjectController(recoveryService: recoveryService)
        let imported = expectation(description: "Import source media")
        controller.importMediaToLibrary(url: sourceURL) { outcome in
            if case .failed(let error) = outcome {
                XCTFail("Import failed: \(error.localizedDescription)")
            }
            imported.fulfill()
        }
        wait(for: [imported], timeout: 5)

        let asset = try XCTUnwrap(controller.project.assets.first)
        _ = controller.addAssetToTimeline(asset.id, at: 0, trackIndex: 0)
        let firstID = try XCTUnwrap(controller.project.timeline.tracks[0].clips.first?.id)
        _ = controller.addAssetToTimeline(asset.id, at: 1, trackIndex: 0)
        let secondID = try XCTUnwrap(controller.project.timeline.tracks[0].clips.last?.id)
        controller.selectClips([firstID, secondID], adding: false)
        XCTAssertTrue(controller.createCrossfadeForSelectedClips())

        let originalTrackID = controller.project.timeline.tracks[0].id
        let originalCrossfade = try XCTUnwrap(controller.project.timeline.crossfades.first)
        controller.duplicateTrack(originalTrackID)

        XCTAssertEqual(controller.project.timeline.tracks.count, 2)
        XCTAssertEqual(controller.project.timeline.crossfades.count, 2)
        let copiedTrack = controller.project.timeline.tracks[1]
        let copiedIDs = Set(copiedTrack.clips.map(\.id))
        let copiedCrossfade = try XCTUnwrap(controller.project.timeline.crossfades.first {
            copiedIDs.contains($0.leadingClipID) && copiedIDs.contains($0.trailingClipID)
        })
        XCTAssertEqual(copiedCrossfade.startTime, originalCrossfade.startTime, accuracy: 0.0001)
        XCTAssertEqual(copiedCrossfade.duration, originalCrossfade.duration, accuracy: 0.0001)
        XCTAssertEqual(copiedCrossfade.curve, originalCrossfade.curve)
    }

    func testRemovingCrossfadeAdvancesAudioRenderRevision() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 2)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let recoveryService = AutosaveRecoveryService()
        defer { recoveryService.stop() }
        let controller = ProjectController(recoveryService: recoveryService)
        let imported = expectation(description: "Import source media")
        controller.importMediaToLibrary(url: sourceURL) { outcome in
            if case .failed(let error) = outcome {
                XCTFail("Import failed: \(error.localizedDescription)")
            }
            imported.fulfill()
        }
        wait(for: [imported], timeout: 5)

        let asset = try XCTUnwrap(controller.project.assets.first)
        _ = controller.addAssetToTimeline(asset.id, at: 0, trackIndex: 0)
        let firstID = try XCTUnwrap(controller.project.timeline.tracks[0].clips.first?.id)
        _ = controller.addAssetToTimeline(asset.id, at: 1, trackIndex: 0)
        let secondID = try XCTUnwrap(controller.project.timeline.tracks[0].clips.last?.id)
        controller.selectClips([firstID, secondID], adding: false)
        XCTAssertTrue(controller.createCrossfadeForSelectedClips())

        let revisionBeforeRemoval = controller.audioRenderRevision
        controller.removeCrossfadesForSelectedClips()

        XCTAssertTrue(controller.project.timeline.crossfades.isEmpty)
        XCTAssertEqual(controller.audioRenderRevision, revisionBeforeRemoval + 1)
    }

    func testRecoveryIgnoresSnapshotFromEarlierSession() throws {
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-Recovery-\(UUID().uuidString)", isDirectory: true)
        let recoveryURL = workspaceURL.appendingPathComponent("Recovery", isDirectory: true)
        let savedProjectURL = workspaceURL.appendingPathComponent("Saved.liau")
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try Data("saved project".utf8).write(to: savedProjectURL)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let originalSession = AutosaveRecoveryService(recoveryDirectory: recoveryURL)
        originalSession.projectProvider = { Project.empty(name: "Old Project") }
        originalSession.isDirtyProvider = { true }
        originalSession.start(projectURL: savedProjectURL, interval: 3_600)
        originalSession.markSessionStarted()
        originalSession.writeSnapshot()
        originalSession.stop()

        // A later session is the one that ended unexpectedly. Its recovery check must not surface old state.
        let laterSession = AutosaveRecoveryService(recoveryDirectory: recoveryURL)
        laterSession.markSessionStarted()
        laterSession.stop()

        let recoveryCheck = AutosaveRecoveryService(recoveryDirectory: recoveryURL)
        XCTAssertNil(recoveryCheck.latestRecoverableSnapshot())
    }

    func testPendingRecoverySnapshotSurvivesASecondCleanShutdown() throws {
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-PendingRecovery-\(UUID().uuidString)", isDirectory: true)
        let recoveryURL = workspaceURL.appendingPathComponent("Recovery", isDirectory: true)
        let savedProjectURL = workspaceURL.appendingPathComponent("Saved.liau")
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        var project = Project.empty(name: "Pending Recovery")
        project.lastSavedAt = Date(timeIntervalSinceNow: -120)
        try ProjectFileService().save(project, to: savedProjectURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: savedProjectURL.path)

        let crashedSession = AutosaveRecoveryService(recoveryDirectory: recoveryURL)
        crashedSession.projectProvider = { project }
        crashedSession.isDirtyProvider = { true }
        crashedSession.start(projectURL: savedProjectURL, interval: 3_600)
        crashedSession.markSessionStarted()
        crashedSession.writeSnapshot()
        crashedSession.stop()

        // Simulate the next launch displaying its recovery sheet, then quitting before the user
        // responds. The original snapshot must remain recoverable on a later launch.
        let promptSession = AutosaveRecoveryService(recoveryDirectory: recoveryURL)
        let pending = try XCTUnwrap(promptSession.latestRecoverableSnapshot())
        promptSession.markSnapshotPending(url: pending.0, snapshot: pending.1)
        promptSession.markSessionStarted()
        promptSession.markCleanShutdown()

        let nextLaunch = AutosaveRecoveryService(recoveryDirectory: recoveryURL)
        let recovered = try XCTUnwrap(nextLaunch.latestRecoverableSnapshot())
        XCTAssertEqual(recovered.1.project.id, project.id)
    }

    func testExportServiceTracksActiveExportUntilCompletion() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 5)
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-ActiveExport-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        let asset = MediaAsset(
            displayName: "Active Export",
            originalPath: sourceURL.path,
            relativePath: nil,
            resolvedPath: sourceURL.path,
            kind: .audio,
            metadata: MediaFileMetadata(fileName: sourceURL.lastPathComponent, fileSize: nil, duration: 5, sampleRate: 44_100, channelCount: 1, checksum: nil),
            waveformCacheKey: nil
        )
        let clip = Clip(sourceAssetID: asset.id, timelineStart: 0, sourceStart: 0, sourceEnd: 5)
        let project = Project(
            name: "Active Export",
            sampleRate: 44_100,
            duration: 5,
            assets: [asset],
            timeline: Timeline(tracks: [Track(name: "A1", clips: [clip])]),
            viewState: TimelineViewState(),
            lastSavedAt: nil
        )
        let exportService = ExportService()
        let finished = expectation(description: "Export finishes after cancellation")
        exportService.export(
            project: project,
            settings: ExportSettings(format: .wav, sampleRate: 44_100, channelCount: 2, bitrate: nil, outputURL: outputURL),
            progress: { _ in },
            completion: { _ in finished.fulfill() }
        )

        XCTAssertTrue(exportService.isExporting)
        exportService.cancel()
        wait(for: [finished], timeout: 10)
        XCTAssertFalse(exportService.isExporting)
    }

    func testEncoderProbeOnlyReportsAudioEncoderEntries() throws {
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-FFmpeg-Probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        let script = "#!/bin/sh\nprintf ' V..... h264\\n A..... aac\\n A..... flac\\n'\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let encoders = try XCTUnwrap(ExternalEncoderSettings.audioEncoderNames(path: scriptURL.path))
        XCTAssertEqual(encoders, Set(["aac", "flac"]))
    }

    func testEncoderProbeTimesOutForAStalledBinary() throws {
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-FFmpeg-Stall-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        try "#!/bin/sh\nsleep 10\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let startedAt = Date()
        XCTAssertNil(ExternalEncoderSettings.audioEncoderNames(path: scriptURL.path))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 4.5)
    }

    func testExternalEncoderCancellationForcesAStalledProcessToFinish() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 0.1)
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-Cancelled-\(UUID().uuidString).m4a")
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-FFmpeg-Cancel-\(UUID().uuidString)")
        let startedURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-FFmpeg-Cancel-Started-\(UUID().uuidString)")
        let previousFFmpegPath = ExternalEncoderSettings.ffmpegPath
        defer {
            ExternalEncoderSettings.ffmpegPath = previousFFmpegPath
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: startedURL)
        }

        let script = """
        #!/bin/sh
        if [ "$1" = "-hide_banner" ]; then
            printf ' A..... aac\\n'
            exit 0
        fi
        printf started > '\(startedURL.path)'
        trap '' TERM
        exec /bin/sleep 30
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        ExternalEncoderSettings.ffmpegPath = scriptURL.path

        let asset = MediaAsset(
            displayName: "Tone",
            originalPath: sourceURL.path,
            relativePath: nil,
            resolvedPath: sourceURL.path,
            kind: .audio,
            metadata: MediaFileMetadata(fileName: sourceURL.lastPathComponent, fileSize: nil, duration: 0.1, sampleRate: 44_100, channelCount: 1, checksum: nil),
            waveformCacheKey: nil
        )
        let clip = Clip(sourceAssetID: asset.id, timelineStart: 0, sourceStart: 0, sourceEnd: 0.1)
        let project = Project(
            name: "Cancelled External Export",
            sampleRate: 44_100,
            duration: 0.1,
            assets: [asset],
            timeline: Timeline(tracks: [Track(name: "A1", clips: [clip])]),
            viewState: TimelineViewState(),
            lastSavedAt: nil
        )
        let settings = ExportSettings(
            format: .m4a,
            sampleRate: 44_100,
            channelCount: 2,
            bitrate: 128,
            outputURL: outputURL
        )
        let cancellationToken = ExportCancellationToken()
        let completed = expectation(description: "Stalled encoder is cancelled")
        let resultLock = NSLock()
        var receivedError: Error?

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try ExternalEncoderExportBackend().export(
                    project: project,
                    settings: settings,
                    cancellationToken: cancellationToken,
                    progress: { _ in }
                )
            } catch {
                resultLock.lock()
                receivedError = error
                resultLock.unlock()
            }
            completed.fulfill()
        }

        let startDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: startedURL.path), Date() < startDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: startedURL.path), "The test encoder did not begin its stalled encode phase.")

        let cancellationStartedAt = Date()
        cancellationToken.cancel()
        wait(for: [completed], timeout: 3)
        XCTAssertLessThan(Date().timeIntervalSince(cancellationStartedAt), 2)

        resultLock.lock()
        let error = receivedError
        resultLock.unlock()
        let cancellationError = try XCTUnwrap(error as NSError?)
        XCTAssertEqual(cancellationError.domain, "LightAudio")
        XCTAssertEqual(cancellationError.code, 11)
    }

    func testRippleDeleteRecalculatesSurvivingCrossfadeTiming() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 1)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let recoveryService = AutosaveRecoveryService()
        defer { recoveryService.stop() }
        let controller = ProjectController(recoveryService: recoveryService)
        let asset = try importAsset(from: sourceURL, into: controller)

        _ = controller.addAssetToTimeline(asset.id, at: 0, trackIndex: 0)
        let removedClipID = try XCTUnwrap(controller.project.timeline.tracks[0].clips.last?.id)
        _ = controller.addAssetToTimeline(asset.id, at: 2, trackIndex: 0)
        let leadingClipID = try XCTUnwrap(controller.project.timeline.tracks[0].clips.last?.id)
        _ = controller.addAssetToTimeline(asset.id, at: 2.5, trackIndex: 0)
        let trailingClipID = try XCTUnwrap(controller.project.timeline.tracks[0].clips.last?.id)

        controller.selectClips([leadingClipID, trailingClipID], adding: false)
        XCTAssertTrue(controller.createCrossfadeForSelectedClips())
        XCTAssertEqual(try XCTUnwrap(controller.project.timeline.crossfades.first).startTime, 2.5, accuracy: 0.0001)

        controller.selectClip(removedClipID)
        controller.rippleDeleteSelectedClips()

        let crossfade = try XCTUnwrap(controller.project.timeline.crossfades.first)
        XCTAssertEqual(crossfade.startTime, 1.5, accuracy: 0.0001)
        XCTAssertEqual(crossfade.duration, 0.5, accuracy: 0.0001)
    }

    func testPastingCrossfadedClipsPreservesTrackAndRelationship() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 2)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let recoveryService = AutosaveRecoveryService()
        defer { recoveryService.stop() }
        let controller = ProjectController(recoveryService: recoveryService)
        let asset = try importAsset(from: sourceURL, into: controller)

        _ = controller.addAssetToTimeline(asset.id, at: 0, trackIndex: 2)
        let firstClipID = try XCTUnwrap(controller.project.timeline.tracks[2].clips.last?.id)
        _ = controller.addAssetToTimeline(asset.id, at: 1, trackIndex: 2)
        let secondClipID = try XCTUnwrap(controller.project.timeline.tracks[2].clips.last?.id)
        controller.selectClips([firstClipID, secondClipID], adding: false)
        XCTAssertTrue(controller.createCrossfadeForSelectedClips())

        controller.copySelectedClips()
        controller.setPlayhead(4)
        controller.pasteClipsAtPlayhead()

        XCTAssertEqual(controller.project.timeline.tracks.count, 3)
        XCTAssertTrue(controller.project.timeline.tracks[0].clips.isEmpty)
        let copiedClips = controller.project.timeline.tracks[2].clips.filter {
            $0.id != firstClipID && $0.id != secondClipID
        }
        XCTAssertEqual(copiedClips.count, 2)
        XCTAssertEqual(copiedClips.map(\.timelineStart).sorted(), [4, 5])

        let copiedIDs = Set(copiedClips.map(\.id))
        let copiedCrossfade = try XCTUnwrap(controller.project.timeline.crossfades.first {
            copiedIDs.contains($0.leadingClipID) && copiedIDs.contains($0.trailingClipID)
        })
        XCTAssertEqual(copiedCrossfade.startTime, 5, accuracy: 0.0001)
        XCTAssertEqual(copiedCrossfade.duration, 1, accuracy: 0.0001)
    }

    func testDuplicatingSelectionPreservesInternalCrossfade() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 1)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let recoveryService = AutosaveRecoveryService()
        defer { recoveryService.stop() }
        let controller = ProjectController(recoveryService: recoveryService)
        let asset = try importAsset(from: sourceURL, into: controller)

        _ = controller.addAssetToTimeline(asset.id, at: 0, trackIndex: 0)
        let firstClipID = try XCTUnwrap(controller.project.timeline.tracks[0].clips.last?.id)
        _ = controller.addAssetToTimeline(asset.id, at: 0.5, trackIndex: 0)
        let secondClipID = try XCTUnwrap(controller.project.timeline.tracks[0].clips.last?.id)
        controller.selectClips([firstClipID, secondClipID], adding: false)
        XCTAssertTrue(controller.createCrossfadeForSelectedClips())

        controller.duplicateSelectedClip()

        let duplicatedIDs = controller.selectedClipIDs
        XCTAssertEqual(duplicatedIDs.count, 2)
        let duplicatedCrossfade = try XCTUnwrap(controller.project.timeline.crossfades.first {
            duplicatedIDs.contains($0.leadingClipID) && duplicatedIDs.contains($0.trailingClipID)
        })
        XCTAssertEqual(duplicatedCrossfade.startTime, 2, accuracy: 0.0001)
        XCTAssertEqual(duplicatedCrossfade.duration, 0.5, accuracy: 0.0001)
    }

    func testOptionDragDuplicationPreservesInternalCrossfade() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 1)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let recoveryService = AutosaveRecoveryService()
        defer { recoveryService.stop() }
        let controller = ProjectController(recoveryService: recoveryService)
        let asset = try importAsset(from: sourceURL, into: controller)

        _ = controller.addAssetToTimeline(asset.id, at: 0, trackIndex: 0)
        let firstClipID = try XCTUnwrap(controller.project.timeline.tracks[0].clips.last?.id)
        _ = controller.addAssetToTimeline(asset.id, at: 0.5, trackIndex: 0)
        let secondClipID = try XCTUnwrap(controller.project.timeline.tracks[0].clips.last?.id)
        controller.selectClips([firstClipID, secondClipID], adding: false)
        XCTAssertTrue(controller.createCrossfadeForSelectedClips())

        controller.beginContinuousEdit(actionName: "Option-Drag Duplicate")
        XCTAssertNotNil(controller.duplicateSelectionForDrag(anchorID: firstClipID))
        controller.endContinuousEdit()

        let duplicatedIDs = controller.selectedClipIDs
        let duplicatedCrossfade = try XCTUnwrap(controller.project.timeline.crossfades.first {
            duplicatedIDs.contains($0.leadingClipID) && duplicatedIDs.contains($0.trailingClipID)
        })
        XCTAssertEqual(duplicatedCrossfade.startTime, 0.5, accuracy: 0.0001)
        XCTAssertEqual(duplicatedCrossfade.duration, 0.5, accuracy: 0.0001)
    }

    func testLoopPlaybackCanExtendPastProjectDuration() {
        XCTAssertEqual(
            AudioPlaybackEngine.playbackEnd(projectDuration: 2, from: 0, requestedEnd: 5),
            5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioPlaybackEngine.playbackEnd(projectDuration: 2, from: 0, requestedEnd: nil),
            2,
            accuracy: 0.0001
        )
    }

    func testTimelineRendererResamplesWithAVFoundationConverter() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 1, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let source = try TimelineAudioSource(url: sourceURL)
        let outputFormat = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)
        )
        let clip = Clip(sourceAssetID: UUID(), timelineStart: 0, sourceStart: 0, sourceEnd: 1)
        let buffer = try XCTUnwrap(source.renderClip(
            clip: clip,
            track: Track(name: "A1"),
            project: Project.empty(),
            timelineStart: 0,
            frameCount: 1_024,
            outputFormat: outputFormat
        ))
        let data = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertEqual(buffer.frameLength, 1_024)
        XCTAssertGreaterThan(data[0][256], 0.1)
    }

    func testTimelineRendererKeepsResamplingContinuousAcrossChunks() throws {
        let sourceURL = try makeSineSourceFile(frequency: 10_000, duration: 1, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let outputFormat = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)
        )
        let clip = Clip(sourceAssetID: UUID(), timelineStart: 0, sourceStart: 0, sourceEnd: 1)
        let track = Track(name: "A1")
        let project = Project.empty()
        let chunkFrames: AVAudioFrameCount = 4_096

        let referenceSource = try TimelineAudioSource(url: sourceURL)
        let reference = try XCTUnwrap(referenceSource.renderClip(
            clip: clip,
            track: track,
            project: project,
            timelineStart: 0,
            frameCount: chunkFrames * 2,
            outputFormat: outputFormat
        ))

        let chunkedSource = try TimelineAudioSource(url: sourceURL)
        let first = try XCTUnwrap(chunkedSource.renderClip(
            clip: clip,
            track: track,
            project: project,
            timelineStart: 0,
            frameCount: chunkFrames,
            outputFormat: outputFormat
        ))
        let second = try XCTUnwrap(chunkedSource.renderClip(
            clip: clip,
            track: track,
            project: project,
            timelineStart: Double(chunkFrames) / outputFormat.sampleRate,
            frameCount: chunkFrames,
            outputFormat: outputFormat
        ))

        let referenceData = try XCTUnwrap(reference.floatChannelData)[0]
        let firstData = try XCTUnwrap(first.floatChannelData)[0]
        let secondData = try XCTUnwrap(second.floatChannelData)[0]
        var maximumDifference: Float = 0
        for frame in 0..<Int(chunkFrames) {
            maximumDifference = max(maximumDifference, abs(firstData[frame] - referenceData[frame]))
            maximumDifference = max(maximumDifference, abs(secondData[frame] - referenceData[Int(chunkFrames) + frame]))
        }
        XCTAssertLessThan(maximumDifference, 0.002)
    }

    func testTimelineRendererUsesChannelLayoutWhenDownmixingSurroundAudio() throws {
        let sourceURL = try makeSurroundCenterSourceFile(sample: 0.5, duration: 0.1, sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let outputFormat = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)
        )
        let source = try TimelineAudioSource(url: sourceURL)
        let clip = Clip(sourceAssetID: UUID(), timelineStart: 0, sourceStart: 0, sourceEnd: 0.1)
        let buffer = try XCTUnwrap(source.renderClip(
            clip: clip,
            track: Track(name: "A1"),
            project: Project.empty(),
            timelineStart: 0,
            frameCount: 1_024,
            outputFormat: outputFormat
        ))
        let data = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertGreaterThan(data[0][256], 0.2)
        XCTAssertEqual(data[0][256], data[1][256], accuracy: 0.01)
    }

    func testClipboardDoesNotCrossProjectBoundaries() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 1)
        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-Clipboard-\(UUID().uuidString).liau")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: projectURL)
        }

        let recoveryService = AutosaveRecoveryService()
        defer { recoveryService.stop() }
        let controller = ProjectController(recoveryService: recoveryService)
        let asset = try importAsset(from: sourceURL, into: controller)
        _ = controller.addAssetToTimeline(asset.id, at: 0, trackIndex: 0)
        let clipID = try XCTUnwrap(controller.project.timeline.tracks[0].clips.first?.id)
        controller.selectClip(clipID)
        controller.copySelectedClips()

        controller.newProject()
        controller.pasteClipsAtPlayhead()

        XCTAssertTrue(controller.project.timeline.tracks.allSatisfy { $0.clips.isEmpty })
        try ProjectFileService().save(controller.project, to: projectURL)
        XCTAssertNoThrow(try ProjectFileService().load(from: projectURL))
    }

    func testRelinkWarningsRequireExplicitConfirmation() throws {
        let originalURL = try makeMonoSourceFile(sample: 0.5, duration: 1)
        let replacementURL = try makeMonoSourceFile(sample: 0.25, duration: 1)
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: replacementURL)
        }

        let recoveryService = AutosaveRecoveryService()
        defer { recoveryService.stop() }
        let controller = ProjectController(recoveryService: recoveryService)
        let asset = try importAsset(from: originalURL, into: controller)
        try FileManager.default.removeItem(at: originalURL)
        XCTAssertTrue(controller.refreshMediaAvailability().contains(where: { $0.id == asset.id }))

        let pending = controller.relink(assetID: asset.id, replacementURL: replacementURL)
        XCTAssertTrue(pending.accepted)
        XCTAssertTrue(pending.requiresConfirmation)
        XCTAssertTrue(pending.warnings.contains("audio checksum differs"))
        XCTAssertTrue(try XCTUnwrap(controller.project.asset(id: asset.id)).isMissing)
        XCTAssertEqual(try XCTUnwrap(controller.project.asset(id: asset.id)).originalPath, originalURL.path)

        let confirmed = controller.relink(assetID: asset.id, replacementURL: replacementURL, allowingMetadataWarnings: true)
        XCTAssertTrue(confirmed.accepted)
        let relinked = try XCTUnwrap(controller.project.asset(id: asset.id))
        XCTAssertFalse(relinked.isMissing)
        XCTAssertEqual(relinked.originalPath, replacementURL.path)
        XCTAssertNotNil(relinked.sourceModificationTimestamp)
    }

    func testFolderRelinkLeavesAmbiguousCandidateForManualConfirmation() throws {
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-FolderRelink-\(UUID().uuidString)", isDirectory: true)
        let originalFolderURL = workspaceURL.appendingPathComponent("Original", isDirectory: true)
        let replacementFolderURL = workspaceURL.appendingPathComponent("Replacement", isDirectory: true)
        let fileName = "Interview.caf"
        let originalURL = originalFolderURL.appendingPathComponent(fileName)
        let replacementURL = replacementFolderURL.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(at: originalFolderURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacementFolderURL, withIntermediateDirectories: true)
        try writeMonoSourceFile(to: originalURL, sample: 0.5, duration: 1)
        try writeMonoSourceFile(to: replacementURL, sample: 0.25, duration: 1)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let recoveryService = AutosaveRecoveryService()
        defer { recoveryService.stop() }
        let controller = ProjectController(recoveryService: recoveryService)
        let asset = try importAsset(from: originalURL, into: controller)
        try FileManager.default.removeItem(at: originalURL)
        _ = controller.refreshMediaAvailability()

        let scanCompleted = expectation(description: "Folder relink scan completes")
        var messages: [String] = []
        controller.locateMissingAssets(in: replacementFolderURL) { result in
            messages = result
            scanCompleted.fulfill()
        }
        wait(for: [scanCompleted], timeout: 5)

        XCTAssertTrue(try XCTUnwrap(controller.project.asset(id: asset.id)).isMissing)
        XCTAssertTrue(messages.joined(separator: "\n").contains("manual confirmation"))
    }

    func testSourceModificationIsMarkedUnavailableBeforeRendering() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 1)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let recoveryService = AutosaveRecoveryService()
        defer { recoveryService.stop() }
        let controller = ProjectController(recoveryService: recoveryService)
        let asset = try importAsset(from: sourceURL, into: controller)
        let timestamp = try XCTUnwrap(asset.sourceModificationTimestamp)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: timestamp + 60)],
            ofItemAtPath: sourceURL.path
        )

        let unavailable = controller.refreshMediaAvailability()
        XCTAssertTrue(unavailable.contains(where: { $0.id == asset.id }))
        XCTAssertTrue(try XCTUnwrap(controller.project.asset(id: asset.id)).isMissing)
    }

    func testSavingUpdatesControllerLastSavedTimestamp() throws {
        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-SaveTimestamp-\(UUID().uuidString).liau")
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let recoveryService = AutosaveRecoveryService()
        defer { recoveryService.stop() }
        let controller = ProjectController(recoveryService: recoveryService)

        XCTAssertTrue(controller.save(to: projectURL))
        let inMemoryTimestamp = try XCTUnwrap(controller.project.lastSavedAt)
        let loaded = try ProjectFileService().load(from: projectURL).0
        let persistedTimestamp = try XCTUnwrap(loaded.lastSavedAt)
        XCTAssertEqual(inMemoryTimestamp.timeIntervalSince1970, persistedTimestamp.timeIntervalSince1970, accuracy: 1)
    }

    func testRecoveryRetainsSnapshotWhenSavedProjectWasMovedOrDeleted() throws {
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-MovedRecovery-\(UUID().uuidString)", isDirectory: true)
        let recoveryURL = workspaceURL.appendingPathComponent("Recovery", isDirectory: true)
        let savedProjectURL = workspaceURL.appendingPathComponent("Saved.liau")
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        var project = Project.empty(name: "Moved Project")
        project.lastSavedAt = Date(timeIntervalSinceNow: -120)
        try ProjectFileService().save(project, to: savedProjectURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: savedProjectURL.path)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let crashedSession = AutosaveRecoveryService(recoveryDirectory: recoveryURL)
        crashedSession.projectProvider = { project }
        crashedSession.isDirtyProvider = { true }
        crashedSession.start(projectURL: savedProjectURL, interval: 3_600)
        crashedSession.markSessionStarted()
        crashedSession.writeSnapshot()
        crashedSession.stop()
        try FileManager.default.removeItem(at: savedProjectURL)

        let recoveryCheck = AutosaveRecoveryService(recoveryDirectory: recoveryURL)
        let recovered = try XCTUnwrap(recoveryCheck.latestRecoverableSnapshot())
        XCTAssertEqual(recovered.1.project.id, project.id)
        XCTAssertEqual(recovered.1.originalProjectURL, savedProjectURL)
    }

    func testRecoverySessionResumesAfterRecoveryCacheClear() throws {
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-ClearedRecovery-\(UUID().uuidString)", isDirectory: true)
        let recoveryURL = workspaceURL.appendingPathComponent("Recovery", isDirectory: true)
        let savedProjectURL = workspaceURL.appendingPathComponent("Saved.liau")
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        var project = Project.empty(name: "Cache Clear Project")
        project.lastSavedAt = Date(timeIntervalSinceNow: -120)
        try ProjectFileService().save(project, to: savedProjectURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: savedProjectURL.path)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let activeSession = AutosaveRecoveryService(recoveryDirectory: recoveryURL)
        activeSession.projectProvider = { project }
        activeSession.isDirtyProvider = { true }
        activeSession.start(projectURL: savedProjectURL, interval: 3_600)
        activeSession.markSessionStarted()
        try FileManager.default.removeItem(at: recoveryURL)
        activeSession.resumeSessionAfterRecoveryCacheClear()
        activeSession.writeSnapshot()
        activeSession.stop()

        let recoveryCheck = AutosaveRecoveryService(recoveryDirectory: recoveryURL)
        XCTAssertNotNil(recoveryCheck.latestRecoverableSnapshot())
    }

    func testNativeExportBackendIsolatedForConcurrentExports() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 0.2)
        let outputURLs = (0..<2).map { index in
            FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-Concurrent-\(UUID().uuidString)-\(index).wav")
        }
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            outputURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        }

        let asset = MediaAsset(
            displayName: "Concurrent Tone",
            originalPath: sourceURL.path,
            relativePath: nil,
            resolvedPath: sourceURL.path,
            kind: .audio,
            metadata: MediaFileMetadata(fileName: sourceURL.lastPathComponent, fileSize: nil, duration: 0.2, sampleRate: 44_100, channelCount: 1, checksum: nil),
            waveformCacheKey: nil
        )
        let clip = Clip(sourceAssetID: asset.id, timelineStart: 0, sourceStart: 0, sourceEnd: 0.2)
        let project = Project(
            name: "Concurrent Export",
            sampleRate: 44_100,
            duration: 0.2,
            assets: [asset],
            timeline: Timeline(tracks: [Track(name: "A1", clips: [clip])]),
            viewState: TimelineViewState(),
            lastSavedAt: nil
        )
        let backend = NativeAudioExportBackend()
        let lock = NSLock()
        var failures: [String] = []
        let completions = outputURLs.map { _ in expectation(description: "Concurrent native export completes") }

        for (index, outputURL) in outputURLs.enumerated() {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let settings = ExportSettings(
                        format: .wav,
                        sampleRate: 44_100,
                        channelCount: 2,
                        bitrate: nil,
                        outputURL: outputURL
                    )
                    _ = try backend.export(
                        project: project,
                        settings: settings,
                        cancellationToken: ExportCancellationToken(),
                        progress: { _ in }
                    )
                } catch {
                    lock.lock()
                    failures.append(error.localizedDescription)
                    lock.unlock()
                }
                completions[index].fulfill()
            }
        }

        wait(for: completions, timeout: 10)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        XCTAssertTrue(outputURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testUndoAfterSaveAsKeepsSaveDestinationAndMarksProjectDirty() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 1)
        let originalProjectURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-Original-\(UUID().uuidString).liau")
        let savedAsProjectURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-SavedAs-\(UUID().uuidString).liau")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: originalProjectURL)
            try? FileManager.default.removeItem(at: savedAsProjectURL)
        }

        let recoveryService = AutosaveRecoveryService()
        let undoManager = UndoManager()
        defer { recoveryService.stop() }
        let controller = ProjectController(recoveryService: recoveryService, undoManagerProvider: { undoManager })
        let asset = try importAsset(from: sourceURL, into: controller)
        _ = controller.addAssetToTimeline(asset.id, at: 0, trackIndex: 0)
        let clipID = try XCTUnwrap(controller.project.timeline.tracks[0].clips.first?.id)

        XCTAssertTrue(controller.save(to: originalProjectURL))
        // XCTest does not advance AppKit's event loop between these setup calls, so clear
        // setup actions before isolating the user-visible post-save edit being exercised.
        undoManager.removeAllActions()
        controller.selectClip(clipID)
        controller.setClipGain(0.5)
        XCTAssertTrue(controller.save(to: savedAsProjectURL))
        XCTAssertFalse(controller.isDirty)
        XCTAssertEqual(controller.projectURL?.standardizedFileURL, savedAsProjectURL.standardizedFileURL)

        undoManager.undo()

        XCTAssertTrue(controller.isDirty)
        XCTAssertEqual(controller.projectURL?.standardizedFileURL, savedAsProjectURL.standardizedFileURL)
        let restoredClip = try XCTUnwrap(controller.project.timeline.tracks[0].clips.first)
        XCTAssertEqual(restoredClip.gain, 1, accuracy: 0.0001)
    }

    func testLeftTrimCannotMoveRightEdgeWhenSourceStartIsZero() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 2)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let recoveryService = AutosaveRecoveryService()
        defer { recoveryService.stop() }
        let controller = ProjectController(recoveryService: recoveryService)
        let asset = try importAsset(from: sourceURL, into: controller)
        _ = controller.addAssetToTimeline(asset.id, at: 1, trackIndex: 0)
        let clipID = try XCTUnwrap(controller.project.timeline.tracks[0].clips.first?.id)

        controller.trimClip(clipID, edge: .left, to: 1.5)
        controller.trimClip(clipID, edge: .left, to: 0)

        let clip = try XCTUnwrap(controller.project.timeline.tracks[0].clips.first)
        XCTAssertEqual(clip.timelineStart, 1, accuracy: 0.0001)
        XCTAssertEqual(clip.sourceStart, 0, accuracy: 0.0001)
        XCTAssertEqual(clip.sourceEnd, 2, accuracy: 0.0001)
        XCTAssertEqual(clip.timelineStart + clip.duration, 3, accuracy: 0.0001)
    }

    func testRejectsOverlappingCrossfadesThatShareAClip() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 2)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let recoveryService = AutosaveRecoveryService()
        defer { recoveryService.stop() }
        let controller = ProjectController(recoveryService: recoveryService)
        let asset = try importAsset(from: sourceURL, into: controller)
        _ = controller.addAssetToTimeline(asset.id, at: 0, trackIndex: 0)
        let firstID = try XCTUnwrap(controller.project.timeline.tracks[0].clips.last?.id)
        _ = controller.addAssetToTimeline(asset.id, at: 0.4, trackIndex: 0)
        let secondID = try XCTUnwrap(controller.project.timeline.tracks[0].clips.last?.id)
        _ = controller.addAssetToTimeline(asset.id, at: 0.8, trackIndex: 0)
        let thirdID = try XCTUnwrap(controller.project.timeline.tracks[0].clips.last?.id)

        controller.selectClips([firstID, secondID], adding: false)
        XCTAssertTrue(controller.createCrossfadeForSelectedClips())
        controller.selectClips([firstID, thirdID], adding: false)
        XCTAssertFalse(controller.createCrossfadeForSelectedClips())
        XCTAssertEqual(controller.project.timeline.crossfades.count, 1)
    }

    func testAutomationInterpolationStaysAccurateWithLargeEnvelope() {
        let keyframes = (0...1_000).map { index in
            ClipVolumeAutomationKeyframe(time: Double(index), gainDB: Double(index) / 100)
        }
        let clip = Clip(
            sourceAssetID: UUID(),
            timelineStart: 0,
            sourceStart: 0,
            sourceEnd: 1_000,
            volumeAutomationKeyframes: keyframes
        )

        XCTAssertEqual(AutomationMath.volumeAutomationDB(for: clip, atClipTime: 500.5), 5.005, accuracy: 0.0001)
        XCTAssertEqual(AutomationMath.volumeAutomationDB(for: clip, atClipTime: 999.75), 9.9975, accuracy: 0.0001)
    }

    func testAsyncRelinkCompletesOnMainThreadAndUpdatesTheAsset() throws {
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-AsyncRelink-\(UUID().uuidString)", isDirectory: true)
        let originalDirectory = workspaceURL.appendingPathComponent("Original", isDirectory: true)
        let replacementDirectory = workspaceURL.appendingPathComponent("Replacement", isDirectory: true)
        let fileName = "Dialog.caf"
        let originalURL = originalDirectory.appendingPathComponent(fileName)
        let replacementURL = replacementDirectory.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacementDirectory, withIntermediateDirectories: true)
        try writeMonoSourceFile(to: originalURL, sample: 0.5, duration: 1)
        try FileManager.default.copyItem(at: originalURL, to: replacementURL)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let recoveryService = AutosaveRecoveryService()
        defer { recoveryService.stop() }
        let controller = ProjectController(recoveryService: recoveryService)
        let asset = try importAsset(from: originalURL, into: controller)
        try FileManager.default.removeItem(at: originalURL)
        _ = controller.refreshMediaAvailability()

        let relinked = expectation(description: "Async relink completes")
        controller.relinkAsync(assetID: asset.id, replacementURL: replacementURL) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(result.accepted, result.reason)
            XCTAssertFalse(result.requiresConfirmation)
            relinked.fulfill()
        }
        wait(for: [relinked], timeout: 5)

        let resolvedAsset = try XCTUnwrap(controller.project.asset(id: asset.id))
        XCTAssertFalse(resolvedAsset.isMissing)
        XCTAssertEqual(resolvedAsset.originalPath, replacementURL.path)
    }

    func testInvalidExportSettingsFailBeforeRendering() {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-Invalid-\(UUID().uuidString).wav")
        let invalidSettings = ExportSettings(
            format: .wav,
            sampleRate: 0,
            channelCount: 2,
            bitrate: nil,
            outputURL: outputURL
        )

        XCTAssertThrowsError(try invalidSettings.validate())
        XCTAssertThrowsError(try NativeAudioExportBackend().export(
            project: Project.empty(),
            settings: invalidSettings,
            cancellationToken: ExportCancellationToken(),
            progress: { _ in }
        ))
    }

    func testProjectValidationRejectsNonFiniteViewStateAndClampsExtremeZoom() throws {
        var invalidProject = Project.empty()
        invalidProject.viewState.zoom = .infinity
        XCTAssertThrowsError(try ProjectFileService().prepareForOpening(&invalidProject, projectURL: nil))

        var extremeProject = Project.empty()
        extremeProject.viewState.zoom = TimelineViewState.maximumZoom * 100
        extremeProject.viewState.horizontalScroll = TimelineViewState.maximumHorizontalScroll * 100
        _ = try ProjectFileService().prepareForOpening(&extremeProject, projectURL: nil)
        XCTAssertEqual(extremeProject.viewState.zoom, TimelineViewState.maximumZoom, accuracy: 0.0001)
        XCTAssertEqual(extremeProject.viewState.horizontalScroll, TimelineViewState.maximumHorizontalScroll, accuracy: 0.0001)

        var invalidTrackHeightProject = Project.empty()
        invalidTrackHeightProject.viewState.trackHeight = .infinity
        XCTAssertThrowsError(try ProjectFileService().prepareForOpening(&invalidTrackHeightProject, projectURL: nil))
    }

    func testEditingStillMarksProjectDirtyWithoutAnUndoManager() throws {
        let sourceURL = try makeMonoSourceFile(sample: 0.5, duration: 1)
        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-NoUndo-\(UUID().uuidString).liau")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: projectURL)
        }

        let recoveryService = AutosaveRecoveryService()
        defer { recoveryService.stop() }
        let controller = ProjectController(recoveryService: recoveryService, undoManagerProvider: { nil })
        let asset = try importAsset(from: sourceURL, into: controller)
        XCTAssertTrue(controller.save(to: projectURL))
        XCTAssertFalse(controller.isDirty)

        _ = controller.addAssetToTimeline(asset.id, at: 0, trackIndex: 0)

        XCTAssertTrue(controller.isDirty)
    }

    func testRelativeMediaPathIsRetriedWhenCollectedMediaAppearsLater() throws {
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-Relative-\(UUID().uuidString)", isDirectory: true)
        let projectURL = workspaceURL.appendingPathComponent("Portable.liau")
        let originalURL = workspaceURL.appendingPathComponent("Original/Clip.caf")
        let collectedURL = workspaceURL.appendingPathComponent("Media/Clip.caf")
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let asset = MediaAsset(
            displayName: "Clip",
            originalPath: originalURL.path,
            relativePath: "Media/Clip.caf",
            resolvedPath: originalURL.path,
            kind: .audio,
            metadata: MediaFileMetadata(fileName: "Clip.caf", fileSize: nil, duration: 1, sampleRate: 44_100, channelCount: 1, checksum: nil),
            waveformCacheKey: nil
        )
        var project = Project.empty(name: "Portable")
        project.assets = [asset]
        let resolver = FileReferenceResolver()

        XCTAssertEqual(resolver.markMissingAssets(in: &project, projectURL: projectURL).count, 1)
        XCTAssertTrue(project.assets[0].isMissing)
        XCTAssertEqual(project.assets[0].originalPath, originalURL.path)

        try FileManager.default.createDirectory(at: collectedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("collected audio placeholder".utf8).write(to: collectedURL)

        XCTAssertTrue(resolver.markMissingAssets(in: &project, projectURL: projectURL).isEmpty)
        XCTAssertFalse(project.assets[0].isMissing)
        XCTAssertEqual(project.assets[0].resolvedPath, collectedURL.path)
        XCTAssertEqual(project.assets[0].originalPath, collectedURL.path)
    }

    func testSavingAnOfflineAssetPreservesItsPortableRelativePath() throws {
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-Offline-Save-\(UUID().uuidString)", isDirectory: true)
        let projectURL = workspaceURL.appendingPathComponent("Portable.liau")
        let originalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LightAudio-Elsewhere-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Clip.caf")
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let asset = MediaAsset(
            displayName: "Clip",
            originalPath: originalURL.path,
            relativePath: "Media/Clip.caf",
            resolvedPath: originalURL.path,
            kind: .audio,
            metadata: MediaFileMetadata(fileName: "Clip.caf", fileSize: nil, duration: 1, sampleRate: 44_100, channelCount: 1, checksum: nil),
            waveformCacheKey: nil
        )
        let project = Project(
            name: "Portable",
            sampleRate: 44_100,
            duration: 0,
            assets: [asset],
            timeline: Timeline(tracks: [Track(name: "A1")]),
            viewState: TimelineViewState(),
            lastSavedAt: nil
        )
        try ProjectFileService().save(project, to: projectURL)

        let recoveryService = AutosaveRecoveryService(recoveryDirectory: workspaceURL.appendingPathComponent("Recovery", isDirectory: true))
        defer { recoveryService.stop() }
        let controller = ProjectController(recoveryService: recoveryService, undoManagerProvider: { nil })
        controller.open(url: projectURL)

        XCTAssertTrue(try XCTUnwrap(controller.project.assets.first).isMissing)
        XCTAssertTrue(controller.save())

        let (savedProject, _) = try ProjectFileService().load(from: projectURL)
        XCTAssertEqual(try XCTUnwrap(savedProject.assets.first).relativePath, "Media/Clip.caf")
        XCTAssertEqual(try XCTUnwrap(savedProject.assets.first).originalPath, originalURL.path)
    }

    func testProxyInvalidationDoesNotDeleteAnUnmanagedPersistedPath() throws {
        let unrelatedURL = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-Unrelated-\(UUID().uuidString).m4a")
        let originalData = Data("Do not delete this unrelated file.".utf8)
        try originalData.write(to: unrelatedURL)
        defer { try? FileManager.default.removeItem(at: unrelatedURL) }

        let asset = MediaAsset(
            displayName: "Video Audio",
            originalPath: FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).mov").path,
            relativePath: nil,
            resolvedPath: nil,
            kind: .videoAudio,
            metadata: MediaFileMetadata(fileName: "missing.mov", fileSize: nil, duration: 1, sampleRate: 44_100, channelCount: 2, checksum: nil),
            waveformCacheKey: nil,
            proxyPath: unrelatedURL.path,
            proxyCacheKey: "untrusted-path",
            proxyStatus: .ready
        )

        MediaProxyService().invalidateProxy(for: asset)

        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
        XCTAssertEqual(try Data(contentsOf: unrelatedURL), originalData)
    }

    func testProjectOpenRestoresTheManagedPathForAnExistingVideoProxy() throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LightAudio-ProxyRestore-\(UUID().uuidString)", isDirectory: true)
        let proxyDirectory = workspaceURL.appendingPathComponent("Proxies", isDirectory: true)
        let recoveryDirectory = workspaceURL.appendingPathComponent("Recovery", isDirectory: true)
        let projectURL = workspaceURL.appendingPathComponent("Proxy Restore.liau")
        let sourceURL = try makeMonoSourceFile(sample: 0.25, duration: 0.1)
        defer {
            try? FileManager.default.removeItem(at: workspaceURL)
            try? FileManager.default.removeItem(at: sourceURL)
        }
        try FileManager.default.createDirectory(at: proxyDirectory, withIntermediateDirectories: true)

        var asset = MediaAsset(
            displayName: "Video Audio",
            originalPath: sourceURL.path,
            relativePath: nil,
            resolvedPath: sourceURL.path,
            kind: .videoAudio,
            metadata: MediaFileMetadata(
                fileName: "source.mov",
                fileSize: nil,
                duration: 0.1,
                sampleRate: 44_100,
                channelCount: 1,
                checksum: nil
            ),
            waveformCacheKey: nil,
            proxyPath: nil,
            proxyCacheKey: nil,
            proxyStatus: .none
        )
        let proxyService = MediaProxyService(proxyDirectory: proxyDirectory)
        let proxyKey = proxyService.cacheKey(for: asset, sourceURL: sourceURL)
        let expectedProxyURL = proxyDirectory.appendingPathComponent("\(proxyKey).m4a")
        try FileManager.default.copyItem(at: sourceURL, to: expectedProxyURL)
        asset.resolvedPath = nil

        let project = Project(
            name: "Proxy Restore",
            sampleRate: 44_100,
            duration: 0,
            assets: [asset],
            timeline: Timeline(tracks: [Track(name: "A1")]),
            viewState: TimelineViewState(),
            lastSavedAt: nil
        )
        try ProjectFileService().save(project, to: projectURL)

        let recoveryService = AutosaveRecoveryService(recoveryDirectory: recoveryDirectory)
        defer { recoveryService.stop() }
        let controller = ProjectController(
            recoveryService: recoveryService,
            proxyService: proxyService,
            undoManagerProvider: { nil }
        )
        controller.open(url: projectURL)

        let restored = expectation(description: "Existing proxy path restored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let openedAsset = controller.project.assets.first
            XCTAssertEqual(openedAsset?.proxyPath, expectedProxyURL.path)
            XCTAssertEqual(openedAsset?.proxyCacheKey, proxyKey)
            XCTAssertEqual(openedAsset?.proxyStatus, .ready)
            XCTAssertEqual(openedAsset?.audioSourceURL, expectedProxyURL)
            restored.fulfill()
        }
        wait(for: [restored], timeout: 3)
    }

    private func importAsset(from sourceURL: URL, into controller: ProjectController) throws -> MediaAsset {
        let imported = expectation(description: "Import source media")
        var result: Result<MediaAsset, Error>?
        controller.importMediaToLibrary(url: sourceURL) { outcome in
            switch outcome {
            case .imported(let asset):
                result = .success(asset)
            case .duplicate, .alreadyImporting:
                result = .failure(NSError(domain: "LightAudioTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "The first import should create a media asset."]))
            case .failed(let error):
                result = .failure(error)
            }
            imported.fulfill()
        }
        wait(for: [imported], timeout: 5)
        return try XCTUnwrap(result).get()
    }

    private func makeMonoSourceFile(sample: Float, duration: TimeInterval, sampleRate: Double = 44_100) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-Test-\(UUID().uuidString).caf")
        try writeMonoSourceFile(to: url, sample: sample, duration: duration, sampleRate: sampleRate)
        return url
    }

    private func writeMonoSourceFile(to url: URL, sample: Float, duration: TimeInterval, sampleRate: Double = 44_100) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
        let frameCount = AVAudioFrameCount((duration * format.sampleRate).rounded())
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let data = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<Int(frameCount) {
            data[0][frame] = sample
        }
        try file.write(from: buffer)
    }

    private func makeSineSourceFile(frequency: Double, duration: TimeInterval, sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-Sine-\(UUID().uuidString).caf")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
        let frameCount = AVAudioFrameCount((duration * sampleRate).rounded())
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let data = try XCTUnwrap(buffer.floatChannelData)[0]
        for frame in 0..<Int(frameCount) {
            data[frame] = Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate) * 0.5)
        }
        try file.write(from: buffer)
        return url
    }

    private func makeSurroundCenterSourceFile(sample: Float, duration: TimeInterval, sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LightAudio-Surround-\(UUID().uuidString).caf")
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A))
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            interleaved: false,
            channelLayout: layout
        ))
        let frameCount = AVAudioFrameCount((duration * sampleRate).rounded())
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frameCount) {
                data[channel][frame] = channel == 2 ? sample : 0
            }
        }
        try file.write(from: buffer)
        return url
    }
}
