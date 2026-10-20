import XCTest
import AVFoundation
import AppKit
@testable import LightAudio_Editor

final class MediaPortabilityTests: XCTestCase {
    private var root: URL!
    private var recovery: AutosaveRecoveryService!
    private var controller: ProjectController!
    private var undo: UndoManager!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LAE-Media-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        recovery = AutosaveRecoveryService(recoveryDirectory: root.appendingPathComponent("Recovery"))
        undo = UndoManager(); undo.groupsByEvent = false
        controller = ProjectController(recoveryService: recovery,
            proxyService: MediaProxyService(proxyDirectory: root.appendingPathComponent("Proxies")), undoManagerProvider: { [weak self] in self?.undo })
    }

    override func tearDownWithError() throws {
        controller.newProject(); recovery.stop(); controller = nil; recovery = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func fixture(_ name: String) throws -> URL {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        let url = root.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    private func pcm(_ name: String = "tone.caf", frames: Int = 44_100, rate: Double = 44_100, channels: UInt32 = 1) throws -> URL {
        let url = root.appendingPathComponent(name)
        let format: AVAudioFormat
        if channels == 3 {
            let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_3_0_A))
            format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                interleaved: false, channelLayout: layout))
        } else {
            format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames)))
        buffer.frameLength = UInt32(frames)
        for c in 0..<Int(channels) { for f in 0..<frames { buffer.floatChannelData![c][f] = Float(sin(Double(f) * 0.05) * 0.2 + Double(c) * 0.01) } }
        try file.write(from: buffer)
        return url
    }

    private func asset(_ url: URL) throws -> MediaAsset {
        MediaAsset(displayName: "Custom name", originalPath: url.path, relativePath: nil,
            kind: AudioFormatHelpers.isVideoExtension(url.pathExtension) ? .videoAudio : .audio,
            metadata: try MediaImportService().metadata(for: url),
            sourceModificationTimestamp: FileReferenceResolver().sourceModificationTimestamp(for: url), waveformCacheKey: nil)
    }

    private func project(_ assets: [MediaAsset]) -> Project {
        var p = Project.empty(name: "Portable")
        p.assets = assets
        if let a = assets.first {
            p.timeline.tracks[0].clips = [Clip(sourceAssetID: a.id, timelineStart: 0.25, sourceStart: 0.1, sourceEnd: a.metadata.duration)]
            p.timeline.tracks[0].clips[0].gain = 0.75
            p.timeline.tracks[0].clips[0].fadeIn.duration = 0.1
        }
        p.recalculateDuration()
        return p
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func samples(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length)))
        try file.read(into: buffer)
        return (0..<Int(buffer.format.channelCount)).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength))) }
    }

    private func prepare(_ source: MediaAsset) throws -> MediaAsset {
        var result: Result<MediaAsset, Error>?
        let done = expectation(description: "Lossless video proxy")
        MediaProxyService(proxyDirectory: root.appendingPathComponent("ReferenceProxies")).prepareProxy(for: source) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(result).get()
    }

    private func render(_ project: Project, name: String) throws -> [[Float]] {
        let output = root.appendingPathComponent(name + ".wav")
        _ = try NativeAudioExportBackend().export(project: project,
            settings: ExportSettings(format: .wav, sampleRate: 44_100, channelCount: 2, bitrate: nil, outputURL: output),
            cancellationToken: ExportCancellationToken(), progress: { _ in })
        return try samples(output)
    }

    func testAudioOnlyCollectionMovesWithoutOriginalsAndPreservesSamplesEditsAndUnusedMedia() throws {
        let movie = try fixture("with-audio.mov")
        // A valid ignored QuickTime free atom models a video much larger than its audio.
        let file = try FileHandle(forWritingTo: movie)
        file.seekToEndOfFile()
        var size = UInt32(2_000_008).bigEndian
        file.write(withUnsafeBytes(of: &size) { Data($0) } + Data("free".utf8) + Data(repeating: 0, count: 2_000_000))
        try file.close()
        let video = try prepare(asset(movie))
        let unused = try asset(pcm("with-audio.caf"))
        let p = project([video, unused])
        let before = try render(p, name: "before")
        let sourceBytes = try Data(contentsOf: movie)
        let encoded = try encode(p)
        let exported = try controller.collectProjectMedia(snapshot: .init(project: p, projectURL: nil), to: root)
        XCTAssertEqual(try encode(p), encoded)
        XCTAssertEqual(try Data(contentsOf: movie), sourceBytes)
        let moved = root.appendingPathComponent("Moved")
        try FileManager.default.moveItem(at: exported.deletingLastPathComponent(), to: moved)
        try FileManager.default.removeItem(at: movie)
        try FileManager.default.removeItem(at: unused.resolvedURL!)
        try FileManager.default.removeItem(at: root.appendingPathComponent("ReferenceProxies"))
        let (restored, missing) = try ProjectFileService().load(from: moved.appendingPathComponent(exported.lastPathComponent))
        XCTAssertTrue(missing.isEmpty)
        XCTAssertEqual(restored.assets.map(\.id), p.assets.map(\.id))
        XCTAssertEqual(try encode(restored.timeline), try encode(p.timeline))
        XCTAssertTrue(restored.assets.allSatisfy { $0.kind == .audio && $0.proxyPath == nil && $0.relativePath?.hasPrefix("Media/") == true })
        XCTAssertEqual(restored.assets[0].metadata.sampleRate, video.metadata.sampleRate)
        XCTAssertEqual(restored.assets[0].metadata.channelCount, video.metadata.channelCount)
        XCTAssertLessThan(try XCTUnwrap(restored.assets[0].metadata.fileSize), Int64(sourceBytes.count / 2))
        XCTAssertEqual(Set(restored.assets.map { $0.metadata.fileName }).count, 2)
        XCTAssertEqual(try render(restored, name: "after"), before)
    }

    func testFullVideoCollectionPreservesEveryLibrarySourceAndDoesNotOverwrite() throws {
        let movie = try fixture("with-audio.mov")
        let a = try asset(movie), b = try asset(movie)
        let p = project([a, b])
        let first = try controller.collectProjectMedia(snapshot: .init(project: p, projectURL: nil), to: root, videoAudioOnly: false)
        let second = try controller.collectProjectMedia(snapshot: .init(project: p, projectURL: nil), to: root, videoAudioOnly: false)
        XCTAssertNotEqual(first, second)
        let restored = try ProjectFileService().load(from: first).0
        XCTAssertEqual(restored.assets.count, 2)
        for a in restored.assets {
            XCTAssertEqual(a.kind, .videoAudio)
            XCTAssertEqual(a.metadata.fileName, a.resolvedURL?.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(a.resolvedURL)), try Data(contentsOf: movie))
        }
    }

    func testCollectionPanelOffersEnabledAudioOnlyOption() throws {
        let document = root.appendingPathComponent("Source.liau")
        try ProjectFileService().save(project([try asset(fixture("with-audio.mov"))]), to: document)
        controller.open(url: document)
        let main = MainWindowController(projectController: controller)
        let window = try XCTUnwrap(main.window)
        defer { window.delegate = nil; window.close() }
        main.collectProjectMedia(nil)
        let panel = try XCTUnwrap(window.attachedSheet as? NSOpenPanel)
        defer { window.endSheet(panel, returnCode: .cancel) }
        let accessory = try XCTUnwrap(panel.accessoryView as? NSStackView)
        let checkbox = try XCTUnwrap(accessory.arrangedSubviews.compactMap { $0 as? NSButton }.first)
        XCTAssertEqual(checkbox.title, L10n.tr("Audio only for video files"))
        XCTAssertEqual(checkbox.state, .on)
        XCTAssertTrue(checkbox.isEnabled)
        checkbox.performClick(nil)
        XCTAssertEqual(checkbox.state, .off)
    }

    func testCollectionCancellationAndDecodeFailureRemovePartialFolders() throws {
        let video = try asset(fixture("with-audio.mov")), audio = try asset(pcm())
        let exports = root.appendingPathComponent("Exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let token = ExportCancellationToken()
        XCTAssertThrowsError(try controller.collectProjectMedia(snapshot: .init(project: project([video, audio]), projectURL: nil),
            to: exports, cancellation: token, progress: { _ in token.cancel() }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: exports.path).isEmpty)
        let silent = try fixture("silent.mov")
        var bad = video; bad.originalPath = silent.path; bad.metadata.fileSize = nil
        bad.metadata.checksum = nil; bad.sourceModificationTimestamp = nil
        XCTAssertThrowsError(try controller.collectProjectMedia(snapshot: .init(project: project([bad]), projectURL: nil), to: exports))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: exports.path).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.originalPath))
        XCTAssertThrowsError(try MediaProxyService().exportLosslessAudio(from: video.resolvedURL!, to: exports.appendingPathComponent("cancel.caf"), cancellation: token))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: exports.path).isEmpty)
    }

    func testMissingUnusedMediaBlocksCollectionWithoutPublishing() throws {
        let a = try asset(pcm()), b = try asset(pcm("unused.caf"))
        try FileManager.default.removeItem(at: b.resolvedURL!)
        XCTAssertThrowsError(try controller.collectProjectMedia(snapshot: .init(project: project([a, b]), projectURL: nil), to: root))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.contains("Collected") || $0.hasSuffix("partial") })
    }

    func testCollectionRejectsSourceChangedAfterCopyAndCleansOutput() throws {
        let source = try pcm(), a = try asset(source)
        let output = root.appendingPathComponent("Exports")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        XCTAssertThrowsError(try controller.collectProjectMedia(snapshot: .init(project: project([a]), projectURL: nil), to: output) { _ in
            let file = try! FileHandle(forWritingTo: source)
            file.seekToEndOfFile(); file.write(Data([1])); try! file.close()
        })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    func testAudioExportRejectsOutOfBoundsClipBeforeCreatingOutput() throws {
        let a = try asset(pcm())
        var p = project([a])
        p.assets[0].metadata.duration -= 1 / p.assets[0].metadata.sampleRate
        for format in [ExportFormat.wav, .aiff, .m4a, .mp3, .flac] {
            let destination = root.appendingPathComponent("invalid.\(format.rawValue.lowercased())")
            let backend: AudioExportBackend = [.wav, .aiff].contains(format) ? NativeAudioExportBackend() : ExternalEncoderExportBackend()
            XCTAssertThrowsError(try backend.export(project: p,
                settings: ExportSettings(format: format, sampleRate: 44_100, channelCount: 2, bitrate: 128, outputURL: destination),
                cancellationToken: ExportCancellationToken(), progress: { _ in }))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testFullFingerprintDetectsChangedTailWithRestoredTimestampAndLegacyNeedsReview() throws {
        let source = try pcm(frames: 400_000)
        let a = try asset(source)
        let prefix = FileMetadataHasher.sha256Prefix(for: source)
        let stamp = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate])
        let file = try FileHandle(forWritingTo: source)
        file.seek(toFileOffset: 1_200_000); file.write(Data(repeating: 0, count: 16)); try file.close()
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: source.path)
        XCTAssertEqual(prefix, FileMetadataHasher.sha256Prefix(for: source))
        var p = project([a])
        XCTAssertEqual(FileReferenceResolver().markMissingAssets(in: &p, projectURL: nil).count, 1)
        let result = MediaRelinkService().verifyAndRelink(asset: a, replacementURL: source, projectURL: nil)
        XCTAssertTrue(result.requiresConfirmation)
        XCTAssertTrue(result.warnings.contains(L10n.tr("audio checksum differs")))
        var legacy = a; legacy.metadata.checksum = prefix
        XCTAssertTrue(MediaRelinkService().verifyAndRelink(asset: legacy, replacementURL: source, projectURL: nil).requiresConfirmation)
    }

    func testTimestampOnlyChangeKeepsIdenticalMediaOnline() throws {
        let source = try pcm(), a = try asset(source)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: source.path)
        var p = project([a])
        XCTAssertTrue(FileReferenceResolver().markMissingAssets(in: &p, projectURL: nil).isEmpty)
        XCTAssertNotEqual(p.assets[0].sourceModificationTimestamp, a.sourceModificationTimestamp)
    }

    func testRelinkRejectsOneFrameShortSourceEvenAfterConfirmationOnMutedLockedTrack() throws {
        let original = try pcm(), a = try asset(original), shorter = try pcm("short.caf", frames: 44_099)
        var p = project([a]); p.timeline.tracks[0].isMuted = true; p.timeline.tracks[0].isLocked = true
        let document = root.appendingPathComponent("Source.liau")
        try ProjectFileService().save(p, to: document)
        try FileManager.default.removeItem(at: original)
        controller.open(url: document)
        for confirmed in [false, true] {
            XCTAssertFalse(controller.relink(assetID: a.id, replacementURL: shorter, allowingMetadataWarnings: confirmed).accepted)
            XCTAssertTrue(controller.project.hasMissingAssets)
            XCTAssertEqual(controller.project.assets[0].originalPath, original.path)
        }
        XCTAssertFalse(undo.canUndo)
    }

    func testRelinkConfirmationRejectsReplacementChangedAfterReview() throws {
        let original = try pcm(), replacement = try pcm("replacement.caf"), a = try asset(original)
        let document = root.appendingPathComponent("Source.liau")
        try ProjectFileService().save(project([a]), to: document)
        try FileManager.default.removeItem(at: original); controller.open(url: document)
        let preview = controller.relink(assetID: a.id, replacementURL: replacement)
        XCTAssertTrue(preview.requiresConfirmation)
        let file = try FileHandle(forWritingTo: replacement); file.seekToEndOfFile(); file.write(Data([1])); try file.close()
        let done = expectation(description: "Confirm changed source")
        controller.relinkAsync(assetID: a.id, replacementURL: replacement, allowingMetadataWarnings: true,
            expectedReplacementChecksum: preview.updatedAsset?.metadata.checksum) { result in
                XCTAssertFalse(result.accepted); done.fulfill()
            }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(controller.project.hasMissingAssets)
    }

    func testRelinkRejectsUnsupportedExtensionAndWrongMediaKind() throws {
        let source = try pcm(), a = try asset(source)
        let unsupported = root.appendingPathComponent("tone.bin")
        try FileManager.default.copyItem(at: source, to: unsupported)
        XCTAssertFalse(MediaRelinkService().verifyAndRelink(asset: a, replacementURL: unsupported, projectURL: nil).accepted)
        let video = try asset(fixture("with-audio.mov"))
        XCTAssertFalse(MediaRelinkService().verifyAndRelink(asset: video, replacementURL: source, projectURL: nil).accepted)
        XCTAssertFalse(MediaRelinkService().verifyAndRelink(asset: a, replacementURL: video.resolvedURL!, projectURL: nil).accepted)
    }

    private func verifyRelink(_ source: URL) throws {
        let a = try asset(source)
        let reference = a.requiresAudioPreparation ? try prepare(a) : a
        let expected = try render(project([reference]), name: "baseline")
        let p = project([a])
        let document = root.appendingPathComponent("Source.liau")
        try ProjectFileService().save(p, to: document)
        let search = root.appendingPathComponent("Search"), nested = search.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let replacement = nested.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: replacement)
        try Data("bad candidate".utf8).write(to: search.appendingPathComponent(source.lastPathComponent))
        try FileManager.default.removeItem(at: source)
        controller.open(url: document)
        XCTAssertTrue(controller.project.hasMissingAssets)
        let done = expectation(description: "Recursive relink")
        controller.locateMissingAssets(in: search) { _ in done.fulfill() }
        wait(for: [done], timeout: 20)
        XCTAssertFalse(controller.project.hasMissingAssets)
        XCTAssertEqual(controller.project.assets[0].id, a.id)
        XCTAssertEqual(try encode(controller.project.timeline), try encode(p.timeline))
        undo.undo(); XCTAssertTrue(controller.project.hasMissingAssets)
        undo.redo(); XCTAssertFalse(controller.project.hasMissingAssets)
        undo.undo(); XCTAssertTrue(controller.project.hasMissingAssets)
        let individual = expectation(description: "Individual relink")
        controller.relinkAsync(assetID: a.id, replacementURL: replacement) { result in
            XCTAssertTrue(result.isSafeForAutomaticRelink); individual.fulfill()
        }
        wait(for: [individual], timeout: 20)
        XCTAssertFalse(controller.project.hasMissingAssets)
        let ready = expectation(for: NSPredicate { _, _ in self.controller.project.assets[0].waveformStatus == .ready }, evaluatedWith: nil)
        wait(for: [ready], timeout: 20)
        XCTAssertTrue(controller.save())
        XCTAssertTrue(try ProjectFileService().load(from: document).1.isEmpty)
        XCTAssertEqual(try render(controller.project, name: "relinked"), expected)
    }

    func testRelinkWAV() throws { try verifyRelink(pcm("tone.wav")) }
    func testRelinkAIFF() throws { try verifyRelink(pcm("tone.aiff")) }
    func testRelinkAIF() throws { try verifyRelink(pcm("tone.aif")) }
    func testRelinkCAF() throws { try verifyRelink(pcm()) }
    func testRelinkMP3() throws { try verifyRelink(fixture("vbr-duration-underestimated.mp3")) }
    func testRelinkAAC() throws { try verifyRelink(fixture("raw-aac-tail-marker.aac")) }
    func testRelinkMOV() throws { try verifyRelink(fixture("with-audio.mov")) }
    func testRelinkMP4() throws { try verifyRelink(movieContainer(extension: "mp4", type: .mp4)) }
    func testRelinkM4V() throws { try verifyRelink(movieContainer(extension: "m4v", type: .m4v)) }

    private func movieContainer(extension ext: String, type: AVFileType) throws -> URL {
        let input = try fixture("with-audio.mov"), output = root.appendingPathComponent("movie.\(ext)")
        let session = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: input), presetName: AVAssetExportPresetPassthrough))
        session.outputFileType = type; session.outputURL = output
        let done = expectation(description: "Container fixture")
        session.exportAsynchronously { done.fulfill() }; wait(for: [done], timeout: 15)
        XCTAssertEqual(session.status, .completed, session.error?.localizedDescription ?? "")
        return output
    }

    private func compressed(_ format: ExportFormat, ext: String) throws -> URL {
        let a = try asset(pcm()), output = root.appendingPathComponent("compressed.\(ext)")
        _ = try ExternalEncoderExportBackend().export(project: project([a]),
            settings: ExportSettings(format: format, sampleRate: 44_100, channelCount: 2, bitrate: 128, outputURL: output),
            cancellationToken: ExportCancellationToken(), progress: { _ in })
        return output
    }
    func testRelinkM4AAAC() throws { try verifyRelink(compressed(.m4a, ext: "m4a")) }
    func testRelinkFLAC() throws { try verifyRelink(compressed(.flac, ext: "flac")) }
    func testRelinkM4AALAC() throws {
        let url = root.appendingPathComponent("lossless.m4a"), source = try pcm()
        func writeALAC() throws {
            let input = try AVAudioFile(forReading: source)
            let output = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitDepthHintKey: 16])
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: UInt32(input.length)))
            try input.read(into: buffer); try output.write(from: buffer)
        }
        try writeALAC()
        try verifyRelink(url)
    }

    private func conditionalContainer(_ name: String) throws {
        let source = try fixture(name)
        if (try? MediaImportService().metadata(for: source)) != nil { try verifyRelink(source) }
        else {
            var a = try asset(pcm()); a.kind = .videoAudio
            XCTAssertFalse(MediaRelinkService().verifyAndRelink(asset: a, replacementURL: source, projectURL: nil).accepted)
        }
    }
    func testRelinkAVIOrRejectUnsupportedDecoder() throws { try conditionalContainer("relink-pcm.avi") }
    func testRelinkMKVOrRejectUnsupportedDecoder() throws { try conditionalContainer("relink-pcm.mkv") }

    func testLosslessVideoNativePrecisionAndRetimingMatchPlaybackProxy() throws {
        let native = try pcm("precision.caf", frames: 96_000, rate: 96_000, channels: 3)
        for duration in [1.0, 1.5] {
            let composition = AVMutableComposition(), av = AVURLAsset(url: native)
            let sourceTrack = try XCTUnwrap(av.tracks(withMediaType: .audio).first)
            let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 96000))
            try track.insertTimeRange(range, of: sourceTrack, at: .zero)
            track.scaleTimeRange(range, toDuration: CMTime(seconds: duration, preferredTimescale: 96000))
            let movie = root.appendingPathComponent("precision-\(duration).mov")
            let session = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
            session.outputFileType = .mov; session.outputURL = movie
            let done = expectation(description: "Retimed movie")
            session.exportAsynchronously { done.fulfill() }; wait(for: [done], timeout: 15)
            XCTAssertEqual(session.status, .completed)
            let a = try prepare(asset(movie))
            let output = try controller.collectProjectMedia(snapshot: .init(project: project([a]), projectURL: nil), to: root)
            let collected = try XCTUnwrap(ProjectFileService().load(from: output).0.assets.first)
            XCTAssertEqual(collected.metadata.sampleRate, 96000)
            XCTAssertEqual(collected.metadata.channelCount, 3)
            XCTAssertEqual(collected.metadata.duration, duration, accuracy: 1 / 96000)
            XCTAssertEqual(try samples(collected.audioSourceURL!), try samples(a.audioSourceURL!))
            if duration == 1 { XCTAssertEqual(try samples(collected.audioSourceURL!), try samples(native)) }
        }
    }
}
