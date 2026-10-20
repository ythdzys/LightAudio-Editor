import Foundation
import os
import AVFoundation

struct PlaybackMeterSnapshot {
    var trackPeaks: [UUID: Double]
    var masterPeak: Double
    var clippingDetected: Bool
}

final class AudioPlaybackEngine {
    private static let scheduledChunkFrames: AVAudioFrameCount = 4_096
    private static let bufferedChunksPerClip = 4

    private var engine = AVAudioEngine()
    private let schedulingQueue = DispatchQueue(label: "com.lightaudio.editor.playback-scheduling", qos: .userInitiated)
    private let stateLock = NSLock()
    private let meterLock = NSLock()
    private var players: [AVAudioPlayerNode] = []
    private var trackMixers: [UUID: AVAudioMixerNode] = [:]
    private var loopStreams: [LoopPlaybackStream] = []
    private var loopRange: (start: Double, end: Double)?
    private final class LoopPlaybackStream {
        let player: AVAudioPlayerNode
        let renderer: LoopPCMRenderer
        init(player: AVAudioPlayerNode, renderer: LoopPCMRenderer) { self.player = player; self.renderer = renderer }
    }
    private var playbackGeneration = 0
    private weak var clockPlayer: AVAudioPlayerNode?
    private var fallbackStartedAt: Date?
    private var lastKnownPlaybackTime: TimeInterval = 0
    private var startTime: TimeInterval = 0
    private var endTime: TimeInterval = 0
    private var pendingTrackPeaks: [UUID: Double] = [:]
    private var pendingMasterPeak = 0.0
    private var pendingClipping = false
    private var meterTapsInstalled = false
    private(set) var isPlaying = false
    private(set) var isPreparing = false
    var onPlaybackBoundary: ((TimeInterval) -> Void)?
    var onPlaybackError: ((Error) -> Void)?

    var currentTime: TimeInterval {
        guard isPlaying else { return startTime }
        if let range = loopRange {
            let elapsed: Double
            if let clockPlayer, let node = clockPlayer.lastRenderTime,
               let clock = clockPlayer.playerTime(forNodeTime: node), clock.sampleRate > 0 {
                elapsed = max(0, Double(clock.sampleTime) / clock.sampleRate)
            } else { elapsed = max(0, fallbackStartedAt.map { Date().timeIntervalSince($0) } ?? 0) }
            return Self.loopTime(start: startTime, elapsed: elapsed, range: range)
        }
        let fallbackTime = min(endTime, startTime + (fallbackStartedAt.map { Date().timeIntervalSince($0) } ?? 0))
        guard let clockPlayer,
              let nodeTime = clockPlayer.lastRenderTime,
              let playerTime = clockPlayer.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else {
            return max(lastKnownPlaybackTime, fallbackTime)
        }

        let renderedTime = min(
            endTime,
            startTime + max(0, Double(playerTime.sampleTime) / playerTime.sampleRate)
        )
        let current = max(lastKnownPlaybackTime, renderedTime)
        lastKnownPlaybackTime = current
        return current
    }

    /// Returns actual post-mix peaks collected by mixer taps since the previous read.
    func takeMeterSnapshot() -> PlaybackMeterSnapshot {
        meterLock.lock()
        defer { meterLock.unlock() }
        let snapshot = PlaybackMeterSnapshot(
            trackPeaks: pendingTrackPeaks,
            masterPeak: pendingMasterPeak,
            clippingDetected: pendingClipping
        )
        pendingTrackPeaks = [:]
        pendingMasterPeak = 0
        pendingClipping = false
        return snapshot
    }

    func play(project: Project, from time: TimeInterval, endingAt requestedEnd: TimeInterval? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        stop()

        let playbackStart = max(0, time)
        let playbackEnd = Self.playbackEnd(
            projectDuration: project.duration,
            from: playbackStart,
            requestedEnd: requestedEnd
        )
        let sampleRate = project.sampleRate > 0 ? project.sampleRate : 44_100
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            completion(.failure(NSError(domain: "LightAudio", code: 60, userInfo: [NSLocalizedDescriptionKey: L10n.tr("Could not create the playback audio format.")])))
            return
        }

        let soloedTrackIDs = Set(project.timeline.tracks.filter { $0.isSolo }.map { $0.id })
        var clips: [(Track, Clip, URL)] = []
        var unavailableAssetNames = Set<String>()
        for track in project.timeline.tracks {
            guard !track.isMuted, soloedTrackIDs.isEmpty || soloedTrackIDs.contains(track.id) else { continue }
            for clip in track.clips where clip.timelineStart < playbackEnd && clip.timelineStart + clip.duration > playbackStart {
                guard let asset = project.asset(id: clip.sourceAssetID),
                      !asset.isMissing,
                      let url = asset.audioSourceURL,
                      FileManager.default.fileExists(atPath: url.path) else {
                    let name = project.asset(id: clip.sourceAssetID)?.metadata.fileName ?? L10n.tr("Unknown media")
                    unavailableAssetNames.insert(name)
                    continue
                }
                clips.append((track, clip, url))
            }
        }
        guard unavailableAssetNames.isEmpty else {
            let names = unavailableAssetNames.sorted().joined(separator: "\n")
            completion(.failure(NSError(domain: "LightAudio", code: 61, userInfo: [NSLocalizedDescriptionKey: L10n.format("Relink unavailable media before playback:\n%@", names)])))
            return
        }

        let generation = beginPlayback(preparingFrom: playbackStart, endingAt: playbackEnd)
        engine.mainMixerNode.outputVolume = Float(MixMath.linearGain(forDB: project.mixState.masterVolumeDB))
        let activeTrackIDs = Set(clips.map { $0.0.id })
        for track in project.timeline.tracks where activeTrackIDs.contains(track.id) {
            let mixer = AVAudioMixerNode()
            engine.attach(mixer)
            engine.connect(mixer, to: engine.mainMixerNode, format: outputFormat)
            trackMixers[track.id] = mixer
        }
        installMeterTaps()

        var nodes: [(Track, AVAudioPlayerNode)] = []
        for track in project.timeline.tracks where activeTrackIDs.contains(track.id) {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: trackMixers[track.id]!, format: outputFormat)
            players.append(player)
            nodes.append((track, player))
        }
        let boundaryPlayer = makePlaybackBoundaryPlayer(
            format: outputFormat,
            playbackStart: playbackStart,
            playbackEnd: playbackEnd,
            generation: generation
        )
        clockPlayer = boundaryPlayer
        players.append(boundaryPlayer)

        schedulingQueue.async { [weak self] in
            guard let self else { return }
            var streams: [LoopPlaybackStream] = []

            do {
                for (track, player) in nodes {
                    guard self.isCurrent(generation) else { return }
                    let renderer = try LoopPCMRenderer(project: project, track: track, format: outputFormat,
                        from: playbackStart, range: (playbackStart, playbackEnd), repeats: false)
                    let stream = LoopPlaybackStream(player: player, renderer: renderer)
                    for _ in 0..<Self.bufferedChunksPerClip { try self.scheduleLoopBuffer(stream, generation: generation) }
                    streams.append(stream)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrent(generation) else { return }
                    self.stop()
                    completion(.failure(error))
                }
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(generation) else { return }
                self.loopStreams = streams
                do {
                    self.engine.prepare()
                    if !self.engine.isRunning {
                        try self.engine.start()
                    }
                    let at = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
                    self.players.forEach { $0.play(at: at) }
                    self.fallbackStartedAt = Date(timeIntervalSinceNow: 0.05)
                    self.lastKnownPlaybackTime = playbackStart
                    self.isPreparing = false
                    self.isPlaying = true
                    completion(.success(()))
                } catch {
                    self.stop()
                    completion(.failure(error))
                }
            }
        }
    }

    /// Continuous per-track PCM queues cross loop boundaries within a buffer. Memory usage depends
    /// on chunk count and track count, not loop length; the engine and meter taps stay running.
    func playLoop(project: Project, from time: Double, range: (start: Double, end: Double), completion: @escaping (Result<Void, Error>) -> Void) {
        stop()
        guard range.start.isFinite, range.end.isFinite, time.isFinite,
              range.start >= 0, range.end > range.start,
              project.sampleRate.isFinite, project.sampleRate > 0,
              range.end * project.sampleRate < Double(Int64.max),
              let format = AVAudioFormat(standardFormatWithSampleRate: project.sampleRate, channels: 2) else {
            completion(.failure(LoopPCMRenderer.invalidRange())); return
        }
        let startFrame = Int64((range.start * format.sampleRate).rounded())
        let endFrame = Int64((range.end * format.sampleRate).rounded())
        guard endFrame > startFrame else { completion(.failure(LoopPCMRenderer.invalidRange())); return }
        let quantized = (start: Double(startFrame) / format.sampleRate, end: Double(endFrame) / format.sampleRate)
        let start = min(quantized.end - 1 / format.sampleRate, max(quantized.start, (time * format.sampleRate).rounded() / format.sampleRate))
        let generation = beginPlayback(preparingFrom: start, endingAt: quantized.end)
        loopRange = quantized
        engine.mainMixerNode.outputVolume = Float(MixMath.linearGain(forDB: project.mixState.masterVolumeDB))
        let solo = project.timeline.tracks.contains { $0.isSolo }
        let tracks = project.timeline.tracks.filter { !$0.isMuted && (!solo || $0.isSolo) }
        // A silent queue still drives the playhead when every track is muted.
        let audible: [Track?] = tracks.isEmpty ? [nil] : tracks.map { Optional($0) }
        var nodes: [(Track?, AVAudioPlayerNode)] = []
        for track in audible {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            if let track {
                let mixer = AVAudioMixerNode()
                engine.attach(mixer); engine.connect(mixer, to: engine.mainMixerNode, format: format)
                engine.connect(player, to: mixer, format: format); trackMixers[track.id] = mixer
            } else { engine.connect(player, to: engine.mainMixerNode, format: format) }
            players.append(player); nodes.append((track, player))
        }
        clockPlayer = players.first
        installMeterTaps()
        schedulingQueue.async { [weak self] in
            guard let self else { return }
            do {
                var streams: [LoopPlaybackStream] = []
                for (track, player) in nodes {
                    guard self.isCurrent(generation) else { return }
                    let renderer = try LoopPCMRenderer(project: project, track: track, format: format, from: start, range: quantized)
                    let stream = LoopPlaybackStream(player: player, renderer: renderer)
                    for _ in 0..<Self.bufferedChunksPerClip { try self.scheduleLoopBuffer(stream, generation: generation) }
                    streams.append(stream)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrent(generation) else { return }
                    self.loopStreams = streams
                    do {
                        self.engine.prepare(); try self.engine.start()
                        let host = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05)
                        let at = AVAudioTime(hostTime: host)
                        self.players.forEach { $0.play(at: at) }
                        self.fallbackStartedAt = Date(timeIntervalSinceNow: 0.05)
                        self.isPreparing = false; self.isPlaying = true
                        completion(.success(()))
                    } catch { self.stop(); completion(.failure(error)) }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrent(generation) else { return }
                    self.stop(); completion(.failure(error))
                }
            }
        }
    }
    private func scheduleLoopBuffer(_ stream: LoopPlaybackStream, generation: Int) throws {
        let trace = OSSignpostID(log: MediaPreparationScheduler.log)
        os_signpost(.begin, log: MediaPreparationScheduler.log, name: "Loop chunk", signpostID: trace)
        defer { os_signpost(.end, log: MediaPreparationScheduler.log, name: "Loop chunk", signpostID: trace) }
        guard isCurrent(generation) else { return }
        let buffer = try stream.renderer.render(frameCount: Self.scheduledChunkFrames)
        guard buffer.frameLength > 0 else { return }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard playbackGeneration == generation else { return }
        stream.player.scheduleBuffer(buffer) { [weak self, weak stream] in
            guard let self, let stream else { return }
            self.schedulingQueue.async {
                guard self.isCurrent(generation) else { return }
                do { try self.scheduleLoopBuffer(stream, generation: generation) }
                catch { self.reportPlaybackError(error, generation: generation) }
            }
        }
    }
    static func loopTime(start: Double, elapsed: Double, range: (start: Double, end: Double)) -> Double {
        let duration = range.end - range.start
        guard duration > 0 else { return range.start }
        return range.start + (max(0, start - range.start) + max(0, elapsed)).truncatingRemainder(dividingBy: duration)
    }

    /// A loop or explicitly requested playback range may intentionally extend beyond the last clip.
    static func playbackEnd(
        projectDuration: TimeInterval,
        from playbackStart: TimeInterval,
        requestedEnd: TimeInterval?
    ) -> TimeInterval {
        let safeStart = max(0, playbackStart)
        let fallbackEnd = projectDuration.isFinite ? max(0, projectDuration) : safeStart
        let requested = requestedEnd.flatMap { $0.isFinite ? max(0, $0) : nil } ?? fallbackEnd
        return max(safeStart, requested)
    }

    func pause() {
        guard !isPreparing else {
            stop()
            return
        }
        startTime = currentTime
        players.forEach { $0.pause() }
        fallbackStartedAt = nil
        lastKnownPlaybackTime = startTime
        isPlaying = false
    }

    func stop() {
        invalidatePlaybackGeneration()
        let mixers = Array(trackMixers.values)
        if meterTapsInstalled {
            engine.mainMixerNode.removeTap(onBus: 0)
            mixers.forEach { $0.removeTap(onBus: 0) }
            meterTapsInstalled = false
        }
        players.forEach {
            $0.stop()
            engine.detach($0)
        }
        players.removeAll()
        mixers.forEach { engine.detach($0) }
        trackMixers.removeAll()
        loopStreams.removeAll(); loopRange = nil
        engine.stop()
        clockPlayer = nil
        fallbackStartedAt = nil
        lastKnownPlaybackTime = startTime
        engine.mainMixerNode.outputVolume = 1
        isPlaying = false
        isPreparing = false
        resetMeterMeasurements()
    }

    /// AVAudioEngine and nodes belong to the old media-service instance after a reset.
    func resetAfterMediaServicesReset() {
        stop()
        engine = AVAudioEngine()
    }

    func seek(to time: TimeInterval) {
        startTime = max(0, time)
        if isPlaying || isPreparing {
            stop()
        }
    }

    private func beginPlayback(preparingFrom start: TimeInterval, endingAt end: TimeInterval) -> Int {
        stateLock.lock()
        playbackGeneration += 1
        let generation = playbackGeneration
        stateLock.unlock()

        startTime = start
        endTime = end
        fallbackStartedAt = nil
        lastKnownPlaybackTime = start
        isPlaying = false
        isPreparing = true
        return generation
    }

    private func invalidatePlaybackGeneration() {
        stateLock.lock()
        playbackGeneration += 1
        stateLock.unlock()
    }

    private func isCurrent(_ generation: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return playbackGeneration == generation
    }

    /// A one-frame silent buffer gives the controller an audio-rendered end boundary instead of
    /// relying on the UI timer to decide when playback or a loop should restart.
    private func makePlaybackBoundaryPlayer(
        format: AVAudioFormat,
        playbackStart: TimeInterval,
        playbackEnd: TimeInterval,
        generation: Int
    ) -> AVAudioPlayerNode {
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else {
            return player
        }
        buffer.frameLength = 1
        if let data = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                data[channel][0] = 0
            }
        }

        let durationFrames = max(
            AVAudioFramePosition(1),
            AVAudioFramePosition(((playbackEnd - playbackStart) * format.sampleRate).rounded())
        )
        let boundaryTime = AVAudioTime(sampleTime: durationFrames - 1, atRate: format.sampleRate)
        player.scheduleBuffer(buffer, at: boundaryTime, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isCurrent(generation), self.isPlaying else { return }
                self.lastKnownPlaybackTime = self.endTime
                self.onPlaybackBoundary?(self.endTime)
            }
        }
        return player
    }


    private func reportPlaybackError(_ error: Error, generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isCurrent(generation),
                  self.isPlaying || self.isPreparing else {
                return
            }
            let failedAt = self.currentTime
            self.stop()
            self.startTime = failedAt
            self.lastKnownPlaybackTime = failedAt
            self.onPlaybackError?(error)
        }
    }

    private func installMeterTaps() {
        resetMeterMeasurements()
        for (trackID, mixer) in trackMixers {
            mixer.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
                guard let self = self else { return }
                self.recordTrackPeak(self.peakLevel(in: buffer), for: trackID)
            }
        }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.recordMasterPeak(self.peakLevel(in: buffer))
        }
        meterTapsInstalled = true
    }

    private func peakLevel(in buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData else { return 0 }
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(data[channel][frame]))
            }
        }
        return Double(peak)
    }

    private func recordTrackPeak(_ peak: Double, for trackID: UUID) {
        guard peak > 0 else { return }
        meterLock.lock()
        pendingTrackPeaks[trackID] = max(pendingTrackPeaks[trackID] ?? 0, peak)
        meterLock.unlock()
    }

    private func recordMasterPeak(_ peak: Double) {
        meterLock.lock()
        pendingMasterPeak = max(pendingMasterPeak, peak)
        pendingClipping = pendingClipping || AudioPeakMath.isClipping(peak: peak)
        meterLock.unlock()
    }

    private func resetMeterMeasurements() {
        meterLock.lock()
        pendingTrackPeaks = [:]
        pendingMasterPeak = 0
        pendingClipping = false
        meterLock.unlock()
    }
}


/// Sample-aligned loop rendering, shared by live playback and PCM regression tests.
/// One instance belongs to one track and is used only on the scheduling queue.
final class LoopPCMRenderer {
    private let project: Project
    private let track: Track?
    private let format: AVAudioFormat
    private let firstFrame: Int64
    private let endFrame: Int64
    private var cursor: Int64
    private var clips: [(Clip, URL)] = []
    private var sources: [UUID: TimelineAudioSource] = [:]
    private let repeats: Bool
    var openSourceCount: Int { sources.count }
    private(set) var totalSourceOpenCount = 0
    private var period: AVAudioPCMBuffer?
    var cachedFrameCount: AVAudioFrameCount { period?.frameLength ?? 0 }
    // At most one queue-sized period and 64 KiB per track. Longer loops keep streaming.
    private var canCachePeriod: Bool {
        repeats && endFrame - firstFrame <= 4096 &&
        endFrame - firstFrame <= 65536 / (Int64(format.channelCount) * 4)
    }

    static func invalidRange() -> Error {
        NSError(domain: "LightAudio", code: 62, userInfo: [NSLocalizedDescriptionKey: L10n.tr("The loop range must contain at least one audio frame.")])
    }
    init(project: Project, track: Track?, format: AVAudioFormat, from: Double, range: (start: Double, end: Double), repeats: Bool = true) throws {
        guard from.isFinite, range.start.isFinite, range.end.isFinite,
              range.start >= 0, range.end > range.start, format.sampleRate > 0,
              range.end * format.sampleRate < Double(Int64.max) else { throw Self.invalidRange() }
        self.project = project; self.track = track; self.format = format; self.repeats = repeats
        firstFrame = Int64((range.start * format.sampleRate).rounded())
        endFrame = Int64((range.end * format.sampleRate).rounded())
        guard endFrame > firstFrame else { throw Self.invalidRange() }
        cursor = Int64((min(range.end, max(range.start, from)) * format.sampleRate).rounded())
        if cursor >= endFrame { cursor = firstFrame }
        for clip in track?.clips ?? [] where clip.timelineStart < range.end && clip.timelineStart + clip.duration > range.start {
            guard let asset = project.asset(id: clip.sourceAssetID), !asset.isMissing,
                  let url = asset.audioSourceURL, FileManager.default.fileExists(atPath: url.path) else {
                throw NSError(domain: "LightAudio", code: 61, userInfo: [NSLocalizedDescriptionKey: L10n.tr("Relink unavailable media before playback.")])
            }
            clips.append((clip, url))
        }
    }
    func render(frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        if frameCount > 0 && canCachePeriod {
            if period == nil {
                let savedCursor = cursor
                cursor = firstFrame
                // The renderer owns an immutable project snapshot. Stopping playback or editing
                // audio discards it, so a cached period never survives into the next playback.
                defer { cursor = savedCursor; sources.removeAll() }
                period = try renderStreaming(frameCount: AVAudioFrameCount(endFrame - firstFrame))
            }
            return try renderCached(frameCount: frameCount)
        }
        return try renderStreaming(frameCount: frameCount)
    }
    private func renderCached(frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let period, let samples = period.floatChannelData,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData else { throw Self.invalidRange() }
        buffer.frameLength = frameCount
        let length = Int(period.frameLength), start = Int(cursor - firstFrame)
        let seedCount = min(length, Int(frameCount))
        let tailCount = min(length - start, seedCount)
        for channel in 0..<Int(format.channelCount) {
            channels[channel].update(from: samples[channel] + start, count: tailCount)
            if seedCount > tailCount {
                (channels[channel] + tailCount).update(from: samples[channel], count: seedCount - tailCount)
            }
            // Double the initialized prefix instead of copying once per loop (possibly one frame).
            var copied = seedCount
            while copied < Int(frameCount) {
                let count = min(copied, Int(frameCount) - copied)
                (channels[channel] + copied).update(from: channels[channel], count: count)
                copied += count
            }
        }
        cursor = firstFrame + (cursor - firstFrame + Int64(frameCount)) % Int64(length)
        return buffer
    }
    private func renderStreaming(frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData else { throw Self.invalidRange() }
        buffer.frameLength = repeats ? frameCount : AVAudioFrameCount(min(Int64(frameCount), max(0, endFrame - cursor)))
        for channel in 0..<Int(format.channelCount) { channels[channel].initialize(repeating: 0, count: Int(frameCount)) }
        var offset = 0
        while offset < Int(buffer.frameLength) {
            let count = min(Int(endFrame - cursor), Int(buffer.frameLength) - offset)
            if let track {
                for (clip, url) in clips {
                    let first = max(cursor, Int64(AudioFrameMath.ceiling(clip.timelineStart * format.sampleRate)))
                    let last = min(cursor + Int64(count), Int64(AudioFrameMath.ceiling((clip.timelineStart + clip.duration) * format.sampleRate)))
                    guard last > first else { continue }
                    let source: TimelineAudioSource
                    if let existing = sources[clip.id] { source = existing }
                    else {
                        source = try TimelineAudioSource(url: url)
                        totalSourceOpenCount += 1
                        sources[clip.id] = source
                    }
                    try source.mix(clip: clip, track: track, project: project, into: buffer,
                                   timelineStart: Double(first) / format.sampleRate,
                                   frameCount: AVAudioFrameCount(last - first), destinationOffset: offset + Int(first - cursor))
                    let clipEnd = Int64(AudioFrameMath.ceiling((clip.timelineStart + clip.duration) * format.sampleRate))
                    if clipEnd <= cursor + Int64(count) { sources.removeValue(forKey: clip.id) }
                }
            }
            cursor += Int64(count); offset += count
            if cursor >= endFrame && repeats { cursor = firstFrame; sources.removeAll() }
        }
        return buffer
    }
}
