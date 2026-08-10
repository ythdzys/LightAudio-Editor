import Foundation
import AVFoundation

struct PlaybackMeterSnapshot {
    var trackPeaks: [UUID: Double]
    var masterPeak: Double
    var clippingDetected: Bool
}

final class AudioPlaybackEngine {
    private static let scheduledChunkFrames: AVAudioFrameCount = 4_096
    private static let bufferedChunksPerClip = 4

    private final class ClipPlaybackStream {
        let clip: Clip
        let track: Track
        let project: Project
        let player: AVAudioPlayerNode
        let source: TimelineAudioSource
        let outputFormat: AVAudioFormat
        let playbackStart: TimeInterval
        let playbackEnd: TimeInterval
        var nextTimelineTime: TimeInterval
        var hasScheduledFirstBuffer = false

        init(clip: Clip, track: Track, project: Project, player: AVAudioPlayerNode, source: TimelineAudioSource, outputFormat: AVAudioFormat, playbackStart: TimeInterval, playbackEnd: TimeInterval) {
            self.clip = clip
            self.track = track
            self.project = project
            self.player = player
            self.source = source
            self.outputFormat = outputFormat
            self.playbackStart = playbackStart
            self.playbackEnd = playbackEnd
            nextTimelineTime = max(playbackStart, clip.timelineStart)
        }
    }

    private let engine = AVAudioEngine()
    private let schedulingQueue = DispatchQueue(label: "com.lightaudio.editor.playback-scheduling", qos: .userInitiated)
    private let stateLock = NSLock()
    private let meterLock = NSLock()
    private var players: [AVAudioPlayerNode] = []
    private var trackMixers: [UUID: AVAudioMixerNode] = [:]
    private var activeStreams: [ClipPlaybackStream] = []
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

    var hasReachedEnd: Bool {
        isPlaying && currentTime >= endTime
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
            completion(.failure(NSError(domain: "LightAudio", code: 60, userInfo: [NSLocalizedDescriptionKey: "Could not create the playback audio format."])))
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
                    let name = project.asset(id: clip.sourceAssetID)?.metadata.fileName ?? "Unknown media"
                    unavailableAssetNames.insert(name)
                    continue
                }
                clips.append((track, clip, url))
            }
        }
        guard unavailableAssetNames.isEmpty else {
            let names = unavailableAssetNames.sorted().joined(separator: "\n")
            completion(.failure(NSError(domain: "LightAudio", code: 61, userInfo: [NSLocalizedDescriptionKey: "Relink unavailable media before playback:\n\(names)"])))
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

        for (track, _, _) in clips {
            let player = AVAudioPlayerNode()
            player.volume = 1
            player.pan = 0
            engine.attach(player)
            if let mixer = trackMixers[track.id] {
                engine.connect(player, to: mixer, format: outputFormat)
            } else {
                engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
            }
            players.append(player)
        }
        let playbackPlayers = players
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
            var streams: [ClipPlaybackStream] = []

            do {
                for ((track, clip, url), player) in zip(clips, playbackPlayers) {
                    guard self.isCurrent(generation) else { return }
                    let source = try TimelineAudioSource(url: url)
                    let stream = ClipPlaybackStream(
                        clip: clip,
                        track: track,
                        project: project,
                        player: player,
                        source: source,
                        outputFormat: outputFormat,
                        playbackStart: playbackStart,
                        playbackEnd: playbackEnd
                    )
                    for _ in 0..<Self.bufferedChunksPerClip {
                        guard try self.scheduleNextBuffer(for: stream, generation: generation) else { break }
                    }
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
                self.activeStreams = streams
                do {
                    self.engine.prepare()
                    if !self.engine.isRunning {
                        try self.engine.start()
                    }
                    self.players.forEach { $0.play() }
                    self.fallbackStartedAt = Date()
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
        activeStreams.removeAll()
        engine.stop()
        clockPlayer = nil
        fallbackStartedAt = nil
        lastKnownPlaybackTime = startTime
        engine.mainMixerNode.outputVolume = 1
        isPlaying = false
        isPreparing = false
        resetMeterMeasurements()
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
        player.scheduleBuffer(buffer, at: boundaryTime, options: []) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isCurrent(generation), self.isPlaying else { return }
                self.lastKnownPlaybackTime = self.endTime
                self.onPlaybackBoundary?(self.endTime)
            }
        }
        return player
    }

    private func scheduleNextBuffer(for stream: ClipPlaybackStream, generation: Int) throws -> Bool {
        guard isCurrent(generation) else { return false }
        let clipEnd = min(stream.clip.timelineStart + stream.clip.duration, stream.playbackEnd)
        let remaining = clipEnd - stream.nextTimelineTime
        guard remaining > 0 else { return false }

        let sampleRate = stream.outputFormat.sampleRate
        let requestedFrames = AVAudioFrameCount(min(
            Int(Self.scheduledChunkFrames),
            max(1, Int(ceil(remaining * sampleRate)))
        ))
        guard let buffer = try stream.source.renderClip(
            clip: stream.clip,
            track: stream.track,
            project: stream.project,
            timelineStart: stream.nextTimelineTime,
            frameCount: requestedFrames,
            outputFormat: stream.outputFormat
        ) else {
            return false
        }

        let startTime: AVAudioTime?
        if stream.hasScheduledFirstBuffer {
            startTime = nil
        } else {
            let delay = max(0, stream.nextTimelineTime - stream.playbackStart)
            startTime = AVAudioTime(
                sampleTime: AVAudioFramePosition((delay * sampleRate).rounded()),
                atRate: sampleRate
            )
        }

        stateLock.lock()
        guard playbackGeneration == generation else {
            stateLock.unlock()
            return false
        }
        stream.player.scheduleBuffer(buffer, at: startTime, options: []) { [weak self, weak stream] in
            guard let self, let stream else { return }
            self.schedulingQueue.async {
                guard self.isCurrent(generation) else { return }
                do {
                    _ = try self.scheduleNextBuffer(for: stream, generation: generation)
                } catch {
                    self.reportPlaybackError(error, generation: generation)
                }
            }
        }
        stateLock.unlock()
        stream.hasScheduledFirstBuffer = true
        stream.nextTimelineTime += Double(buffer.frameLength) / sampleRate
        return true
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
        pendingClipping = pendingClipping || peak > 1
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
