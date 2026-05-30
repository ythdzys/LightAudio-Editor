import Foundation
import AVFoundation

final class AudioPlaybackEngine {
    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var startedAt: Date?
    private var startTime: TimeInterval = 0
    private(set) var isPlaying = false

    var currentTime: TimeInterval {
        guard isPlaying, let startedAt = startedAt else { return startTime }
        return startTime + Date().timeIntervalSince(startedAt)
    }

    func play(project: Project, from time: TimeInterval) throws {
        stop()
        startTime = max(0, time)
        let soloedTrackIDs = Set(project.timeline.tracks.filter { $0.isSolo }.map { $0.id })

        for track in project.timeline.tracks {
            if track.isMuted { continue }
            if !soloedTrackIDs.isEmpty && !soloedTrackIDs.contains(track.id) { continue }

            for clip in track.clips where clip.timelineStart + clip.duration > startTime {
                guard let asset = project.asset(id: clip.sourceAssetID), !asset.isMissing, let url = asset.audioSourceURL else { continue }
                guard let file = try? AVAudioFile(forReading: url) else { continue }

                let clipOffset = max(0, startTime - clip.timelineStart)
                let sourceTime = clip.sourceStart + clipOffset
                let framesLeft = AVAudioFrameCount(max(0, (clip.sourceEnd - sourceTime) * file.processingFormat.sampleRate))
                guard framesLeft > 0 else { continue }

                let player = AVAudioPlayerNode()
                player.volume = 1
                player.pan = Float(MixMath.combinedPan(clip.pan, track.pan))
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
                let delay = max(0, clip.timelineStart - startTime)
                let startFrame = AVAudioFramePosition(delay * file.processingFormat.sampleRate)
                try scheduleClip(clip, track: track, project: project, file: file, player: player, sourceTime: sourceTime, framesLeft: framesLeft, startFrame: startFrame, scheduleRate: file.processingFormat.sampleRate)
                players.append(player)
            }
        }

        if !engine.isRunning {
            try engine.start()
        }
        players.forEach { $0.play() }
        startedAt = Date()
        isPlaying = true
    }

    func pause() {
        startTime = currentTime
        players.forEach { $0.pause() }
        startedAt = nil
        isPlaying = false
    }

    func stop() {
        players.forEach {
            $0.stop()
            engine.detach($0)
        }
        players.removeAll()
        engine.stop()
        startedAt = nil
        isPlaying = false
    }

    func seek(to time: TimeInterval) {
        startTime = max(0, time)
        if isPlaying {
            stop()
        }
    }

    private func scheduleClip(_ clip: Clip, track: Track, project: Project, file: AVAudioFile, player: AVAudioPlayerNode, sourceTime: TimeInterval, framesLeft: AVAudioFrameCount, startFrame: AVAudioFramePosition, scheduleRate: Double) throws {
        let sampleRate = file.processingFormat.sampleRate
        let chunkFrames: AVAudioFrameCount = 4096
        var remaining = framesLeft
        var firstBuffer = true
        var sourceFrame = AVAudioFramePosition(sourceTime * sampleRate)

        while remaining > 0 {
            let frameCount = min(chunkFrames, remaining)
            file.framePosition = sourceFrame
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else { break }
            try file.read(into: buffer, frameCount: frameCount)
            if buffer.frameLength == 0 { break }
            applyGainAndFade(to: buffer, clip: clip, track: track, project: project, sourceStartFrame: sourceFrame, sampleRate: sampleRate)

            let startTime = firstBuffer ? AVAudioTime(sampleTime: startFrame, atRate: scheduleRate) : nil
            player.scheduleBuffer(buffer, at: startTime, options: [], completionHandler: nil)
            firstBuffer = false
            sourceFrame += AVAudioFramePosition(buffer.frameLength)
            remaining -= buffer.frameLength
        }
    }

    private func applyGainAndFade(to buffer: AVAudioPCMBuffer, clip: Clip, track: Track, project: Project, sourceStartFrame: AVAudioFramePosition, sampleRate: Double) {
        guard let data = buffer.floatChannelData else {
            return
        }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        let trackGain = MixMath.linearGain(forDB: track.volumeDB)
        let masterGain = MixMath.linearGain(forDB: project.mixState.masterVolumeDB)

        for frame in 0..<frameCount {
            let sourceTime = Double(sourceStartFrame + AVAudioFramePosition(frame)) / sampleRate
            let timelineTime = clip.timelineStart + (sourceTime - clip.sourceStart)
            let clipTime = timelineTime - clip.timelineStart
            let automationGain = AutomationMath.volumeAutomationGain(for: clip, atClipTime: clipTime)
            let trackAutomationGain = AutomationMath.trackVolumeAutomationGain(for: track, atTimelineTime: timelineTime)
            let fadeGain = FadeMath.edgeFadeGain(for: clip, timelineTime: timelineTime)
            let crossfadeGain = FadeMath.crossfadeGain(for: clip.id, timelineTime: timelineTime, timeline: project.timeline)
            let gain = Float(MixMath.clampClipGainLinear(clip.gain) * automationGain * fadeGain * crossfadeGain * trackGain * trackAutomationGain * masterGain)
            for channel in 0..<channelCount {
                data[channel][frame] *= gain
            }
        }
    }
}
