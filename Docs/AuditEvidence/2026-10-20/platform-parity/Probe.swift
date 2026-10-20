import Foundation
import AVFoundation

// UI localization is not part of these audio-only probes.
enum L10n {
    static func tr(_ text: String) -> String { text }
}

@main
struct Probe {
    static func writePCM(_ url: URL, rate: Double, channels: Int, count: Int,
                         sample: (Int, Int) -> Float) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))!
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<channels {
            for frame in 0..<count {
                buffer.floatChannelData![channel][frame] = sample(channel, frame)
            }
        }
        try file.write(from: buffer)
    }

    static func render(_ url: URL, clip: Clip, rate: Double, channels: Int, frames: Int) throws -> [Float] {
        let source = try TimelineAudioSource(url: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))!
        let buffer = try source.renderClip(
            clip: clip, track: Track(name: "Probe", clips: [clip]), project: Project.empty(),
            timelineStart: clip.timelineStart, frameCount: AVAudioFrameCount(frames), outputFormat: format
        )!
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stereoURL = root.appendingPathComponent("stereo.caf")
        let monoURL = root.appendingPathComponent("mono.caf")
        let resampleURL = root.appendingPathComponent("resample.caf")
        try writePCM(stereoURL, rate: 48000, channels: 2, count: 4800) { channel, _ in channel == 0 ? 0.4 : 0.2 }
        try writePCM(monoURL, rate: 48000, channels: 1, count: 4800) { _, _ in 0.4 }
        try writePCM(resampleURL, rate: 44100, channels: 1, count: 22050) { _, frame in
            let time: Double = Double(frame) / 44100.0
            let low: Double = 0.4 * sin(2.0 * Double.pi * 997.0 * time)
            let high: Double = 0.2 * sin(2.0 * Double.pi * 4001.0 * time)
            return Float(low + high)
        }
        var clip = Clip(sourceAssetID: UUID(), timelineStart: 0, sourceStart: 0, sourceEnd: 0.1)
        let centerStereo = try render(stereoURL, clip: clip, rate: 48000, channels: 1, frames: 4800)[100]
        clip.pan = 1
        let hardRightStereo = try render(stereoURL, clip: clip, rate: 48000, channels: 1, frames: 4800)[100]
        clip.pan = 0
        let centerMono = try render(monoURL, clip: clip, rate: 48000, channels: 1, frames: 4800)[100]
        clip.pan = 1
        let hardRightMono = try render(monoURL, clip: clip, rate: 48000, channels: 1, frames: 4800)[100]
        let wholeClip = Clip(sourceAssetID: UUID(), timelineStart: 0, sourceStart: 0, sourceEnd: 0.5)
        let whole = try render(resampleURL, clip: wholeClip, rate: 48000, channels: 2, frames: 24000)
        var first = wholeClip
        first.sourceEnd = 0.137
        var second = wholeClip
        second.timelineStart = 0.137
        second.sourceStart = 0.137
        let joined = try render(resampleURL, clip: first, rate: 48000, channels: 2, frames: 6576)
            + render(resampleURL, clip: second, rate: 48000, channels: 2, frames: 17424)
        let differences = zip(whole, joined).map { Double(abs($0 - $1)) }
        let result: [String: Any] = [
            "stereoToMonoCenter": centerStereo,
            "stereoToMonoHardRight": hardRightStereo,
            "monoToMonoCenter": centerMono,
            "monoToMonoHardRight": hardRightMono,
            "resampledSplitMaxError": differences.max()!,
            "resampledSplitRMSError": sqrt(differences.map { $0 * $0 }.reduce(0, +) / Double(differences.count)),
            "renderedFrames": whole.count,
            "splitRenderedFrames": joined.count
        ]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
