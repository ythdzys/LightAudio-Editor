import Foundation
import AVFoundation

final class MediaImportService {
    private let resolver = FileReferenceResolver()

    func importMedia(at url: URL, projectURL: URL?, completion: @escaping (Result<MediaAsset, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard AudioFormatHelpers.supportedImportExtension(url.pathExtension) else {
                    throw NSError(domain: "LightAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.tr("Unsupported media type.")])
                }
                let isVideo = AudioFormatHelpers.isVideoExtension(url.pathExtension)
                let metadata = try self.metadata(for: url)
                let asset = MediaAsset(
                    displayName: url.deletingPathExtension().lastPathComponent,
                    originalPath: url.path,
                    relativePath: self.resolver.relativePath(for: url, projectURL: projectURL),
                    kind: isVideo ? .videoAudio : .audio,
                    metadata: metadata,
                    sourceModificationTimestamp: self.resolver.sourceModificationTimestamp(for: url),
                    waveformCacheKey: nil,
                    proxyStatus: AudioFormatHelpers.requiresContainerAudioDecode(url.pathExtension) ? .generating : .none,
                    isMissing: false
                )
                DispatchQueue.main.async { completion(.success(asset)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func metadata(for url: URL) throws -> MediaFileMetadata {
        let sampleRate: Double
        let channelCount: Int
        let duration: Double
        if AudioFormatHelpers.requiresContainerAudioDecode(url.pathExtension) {
            let plan = try VideoAudioPlan(asset: AVURLAsset(url: url),
                                          preserveLeadingSilence: !AudioFormatHelpers.isVideoExtension(url.pathExtension))
            duration = plan.duration; sampleRate = plan.sampleRate; channelCount = plan.channelCount
        } else {
            // Match the decoder used by waveform analysis, normalization and rendering.
            // AVAsset track durations can estimate untagged VBR MP3 incorrectly or exclude
            // AAC priming without moving the raw decoder's origin, cutting audible tails.
            let file = try AVAudioFile(forReading: url)
            sampleRate = file.processingFormat.sampleRate
            channelCount = Int(file.processingFormat.channelCount)
            duration = sampleRate > 0 ? Double(file.length) / sampleRate : 0
        }

        guard TimelineViewState.isValidTimelineTime(duration), duration > 0, sampleRate.isFinite, sampleRate > 0, sampleRate <= 384_000, channelCount > 0 else {
            throw NSError(domain: "LightAudio", code: 3, userInfo: [NSLocalizedDescriptionKey: L10n.tr("This media does not contain readable audio.")])
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        return MediaFileMetadata(
            fileName: url.lastPathComponent,
            fileSize: size,
            duration: duration,
            sampleRate: sampleRate,
            channelCount: channelCount,
            checksum: try FileMetadataHasher.fullChecksum(for: url)
        )
    }
}

/// Metadata and PCM extraction use the same set of audio tracks and the same time interval.
struct VideoAudioPlan {
    let asset: AVAsset
    let tracks: [AVAssetTrack]
    let start: Double
    let duration: Double
    let sampleRate: Double
    let channelCount: Int
    init(asset: AVAsset, preserveLeadingSilence: Bool = false) throws {
        self.asset = asset
        tracks = asset.tracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw NSError(domain: "LightAudio", code: 2, userInfo: [NSLocalizedDescriptionKey: L10n.tr("This video does not contain an audio track.")]) }
        var rates: [Double] = [], channels: [Int] = [], starts: [Double] = [], ends: [Double] = []
        for track in tracks {
            guard let description = track.formatDescriptions.first,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description as! CMAudioFormatDescription) else {
                throw NSError(domain: "LightAudio", code: 3, userInfo: [NSLocalizedDescriptionKey: L10n.tr("This media does not contain readable audio.")])
            }
            rates.append(asbd.pointee.mSampleRate); channels.append(Int(asbd.pointee.mChannelsPerFrame))
            // MOV tracks can begin with an empty edit, while timeRange still starts at zero.
            // Use actual media segments for the outer interval, retaining internal gaps.
            let segments = track.segments
            let ranges = segments.isEmpty ? [track.timeRange] : segments.filter { !$0.isEmpty }.map { $0.timeMapping.target }
            for range in ranges { starts.append(range.start.seconds); ends.append(range.end.seconds) }
        }
        start = preserveLeadingSilence ? 0 : (starts.min() ?? 0)
        sampleRate = rates.max() ?? 44100
        channelCount = tracks.count == 1 ? channels[0] : 2
        duration = AudioFrameMath.ceiling(((ends.max() ?? 0) - start) * sampleRate) / sampleRate
        guard start.isFinite, TimelineViewState.isValidTimelineTime(duration), duration > 0, sampleRate.isFinite, sampleRate > 0, sampleRate <= 384000, channelCount > 0 else {
            throw NSError(domain: "LightAudio", code: 3, userInfo: [NSLocalizedDescriptionKey: L10n.tr("This media does not contain readable audio.")])
        }
    }
}
