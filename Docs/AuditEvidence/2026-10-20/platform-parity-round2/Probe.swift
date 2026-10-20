import Foundation
import AVFoundation
import AppKit

@main
struct Probe {
    static func spin(until done: () -> Bool, seconds: Double = 15) throws {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        if !done() { throw NSError(domain: "AuditTimeout", code: 1) }
    }
    static func writePCM(_ url: URL, sample: Float = 0.2) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        buffer.frameLength = 4410
        for c in 0..<2 { for f in 0..<4410 { buffer.floatChannelData![c][f] = sample } }
        try file.write(from: buffer)
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("tone.caf"); try writePCM(source)
        let metadata = try MediaImportService().metadata(for: source)
        let asset = MediaAsset(displayName: "tone", originalPath: source.path, relativePath: nil, kind: .audio, metadata: metadata, waveformCacheKey: nil)
        let recovery = AutosaveRecoveryService(recoveryDirectory: root.appendingPathComponent("Recovery"))
        let undo = UndoManager(); undo.groupsByEvent = false
        let controller = ProjectController(recoveryService: recovery, proxyService: MediaProxyService(proxyDirectory: root.appendingPathComponent("Proxies")), undoManagerProvider: { undo })
        defer { controller.newProject(); recovery.stop() }
        func load(_ p: Project) throws {
            controller.restore(snapshot: .init(createdAt: Date(), originalProjectURL: nil, project: p))
            try spin { !controller.project.assets.contains(where: \.isVerifyingSource) }
            undo.removeAllActions()
        }
        var results: [String: Any] = [:]
        var project = Project.empty(); project.assets = [asset]
        project.timeline.tracks = (1...64).map { Track(name: "A\($0)") }
        try load(project)
        let placement = controller.addAssetToTimeline(asset.id, at: 0, trackIndex: 64)
        results["track65Placement"] = ["trackCount": controller.project.timeline.tracks.count, "target": placement?.targetTrackName ?? "none", "clamped": placement?.wasTrackClamped ?? false]
        project.timeline.tracks = [Track(name: "A1")]; try load(project)
        let excessiveStart = TimelineViewState.maximumTimelineTime - 0.05
        let invalid = controller.addAssetToTimeline(asset.id, at: excessiveStart, trackIndex: 0)
        let canSave = controller.save(to: root.appendingPathComponent("time-limit.liau"))
        results["timelineBounds"] = ["placementAccepted": invalid != nil, "canSaveAfterPlacement": canSave, "duration": controller.project.duration]
        controller.setPlayhead(.infinity)
        results["nonfinitePlayheadAccepted"] = !controller.playheadTime.isFinite
        // Follow the desktop UI's selected crossfade command on a locked track.
        #if MAC_AUDIT
        let first = Clip(sourceAssetID: asset.id, timelineStart: 0, sourceStart: 0, sourceEnd: 0.1)
        let second = Clip(sourceAssetID: asset.id, timelineStart: 0.05, sourceStart: 0, sourceEnd: 0.1)
        project.timeline.tracks = [Track(name: "Locked", isLocked: true, clips: [first, second])]
        project.timeline.crossfades = [.init(leadingClipID: first.id, trailingClipID: second.id, startTime: 0.05, duration: 0.05)]
        project.recalculateDuration(); try load(project); controller.selectClip(first.id)
        let before = controller.project.timeline.crossfades.count
        controller.removeCrossfadesForSelectedClips()
        results["lockedCrossfadeRemoval"] = ["before": before, "after": controller.project.timeline.crossfades.count, "locked": controller.project.timeline.tracks[0].isLocked]
        // Exercise the actual inspector's field actions without presenting a window.
        let inspector = InspectorViewController(); _ = inspector.view
        var value: Double?
        inspector.onFadeInChanged = { value = $0 }
        let field = Mirror(reflecting: inspector).children.first { $0.label == "fadeInField" }!.value as! NSTextField
        var inputResults: [String: Double] = [:]
        for input in ["0,5", "invalid", "0.5"] {
            field.stringValue = input; value = nil; _ = inspector.perform(NSSelectorFromString("fadeInFieldChanged"))
            inputResults[input] = value ?? -999
        }
        results["inspectorFadeInputs"] = inputResults
        #endif
        // Cold-source verification must not be confused with a missing file when importing.
        let coldSource = root.appendingPathComponent("cold-source.caf")
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            let file = try AVAudioFile(forWriting: coldSource, settings: format.settings)
            let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
            block.frameLength = 44100
            for c in 0..<2 { for f in 0..<44100 { block.floatChannelData![c][f] = 0.2 } }
            for _ in 0..<200 { try file.write(from: block) }
        }
        let coldMetadata = try MediaImportService().metadata(for: coldSource)
        let coldAsset = MediaAsset(displayName: "cold", originalPath: coldSource.path, relativePath: nil, kind: .audio, metadata: coldMetadata, waveformCacheKey: nil)
        project = Project.empty(); project.assets = [coldAsset]
        let document = root.appendingPathComponent("pending.liau"); try ProjectFileService().save(project, to: document)
        let newSource = root.appendingPathComponent("second.caf"); try writePCM(newSource, sample: 0.3)
        FileMetadataHasher.clearVerificationCache()
        _ = controller.open(url: document)
        let pendingAtImport = controller.project.assets.contains(where: \.isVerifyingSource)
        var importOutcome: String?
        controller.importMediaToLibrary(url: newSource) { outcome in
            switch outcome { case .failed(let error): importOutcome = error.localizedDescription
            case .imported: importOutcome = "imported"
            case .duplicate: importOutcome = "duplicate"
            case .alreadyImporting: importOutcome = "already importing" }
        }
        try spin { importOutcome != nil && !controller.project.assets.contains(where: \.isVerifyingSource) }
        results["pendingImportSharedController"] = ["pending": pendingAtImport, "outcome": importOutcome!, "existingSourceMissingAfterVerification": controller.project.assets[0].isMissing]
        controller.newProject(); recovery.stop()
        // An accepted relink must clear old pending-source state.
        var pendingAsset = asset; pendingAsset.isMissing = true; pendingAsset.isVerifyingSource = true
        let relink = MediaRelinkService().verifyAndRelink(asset: pendingAsset, replacementURL: source, projectURL: nil)
        results["relinkPendingState"] = ["accepted": relink.accepted, "isVerifyingSource": relink.updatedAsset?.isVerifyingSource ?? false]
        // Non-overlapping clips should release each decoder when its final frame is exported.
        let clips = (0..<160).map { Clip(sourceAssetID: asset.id, timelineStart: Double($0) * 0.1, sourceStart: 0, sourceEnd: 0.1) }
        project = Project.empty(); project.assets = [asset]; project.timeline.tracks = [Track(name: "Sequential", clips: clips)]; project.recalculateDuration()
        func fds() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }
        let baseline = fds(); var peak = baseline; var finished = false; var exportError: String?
        let exportProject = project
        DispatchQueue.global().async {
            do { _ = try NativeAudioExportBackend().export(project: exportProject, settings: .init(format: .wav, sampleRate: 44100, channelCount: 2, bitrate: nil, outputURL: root.appendingPathComponent("sequence.wav")), cancellationToken: .init(), progress: { _ in peak = max(peak, fds()) }) }
            catch { exportError = error.localizedDescription }
            DispatchQueue.main.async { finished = true }
        }
        try spin(until: { finished }, seconds: 30)
        results["exportDecoderLifetime"] = ["clips": clips.count, "baselineDescriptors": baseline, "peakDescriptors": peak, "growth": peak - baseline, "error": exportError ?? "none"]
        // Overflow after master gain is treated differently by the remaining export stages.
        let huge = root.appendingPathComponent("huge.caf"); try writePCM(huge, sample: Float.greatestFiniteMagnitude * 0.5)
        var hugeAsset = asset; hugeAsset.originalPath = huge.path; hugeAsset.resolvedPath = huge.path; hugeAsset.metadata.checksum = nil
        project = Project.empty(); project.assets = [hugeAsset]; project.timeline.tracks[0].clips = [Clip(sourceAssetID: asset.id, timelineStart: 0, sourceStart: 0, sourceEnd: 0.1)]; project.mixState.masterVolumeDB = 12; project.recalculateDuration()
        let hugeOutput = root.appendingPathComponent("overflow.wav")
        _ = try NativeAudioExportBackend().export(project: project, settings: .init(format: .wav, sampleRate: 44100, channelCount: 2, bitrate: nil, outputURL: hugeOutput), cancellationToken: .init(), progress: { _ in })
        let decoded = try AVAudioFile(forReading: hugeOutput), buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!, frameCapacity: 100)!
        try decoded.read(into: buffer); results["overflowOutputSample"] = Double(buffer.floatChannelData![0][50])
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]); print(String(decoding: data, as: UTF8.self))
    }
}
