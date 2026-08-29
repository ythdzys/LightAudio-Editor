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
                    proxyStatus: isVideo ? .generating : .none,
                    isMissing: false
                )
                DispatchQueue.main.async { completion(.success(asset)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func metadata(for url: URL) throws -> MediaFileMetadata {
        let avAsset = AVURLAsset(url: url)
        let containerDuration = CMTimeGetSeconds(avAsset.duration)
        var sampleRate = 44100.0
        var channelCount = 2
        var duration = containerDuration

        let isVideo = AudioFormatHelpers.isVideoExtension(url.pathExtension)
        if let track = avAsset.tracks(withMediaType: .audio).first {
            let trackDuration = CMTimeGetSeconds(track.timeRange.duration)
            if trackDuration.isFinite, trackDuration > 0 {
                // A video container can outlast its audio track; clips must use the audible duration.
                duration = trackDuration
            }
            if let description = track.formatDescriptions.first,
               let audioDescription = audioFormatDescription(from: description),
               CMFormatDescriptionGetMediaType(audioDescription) == kCMMediaType_Audio,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioDescription) {
                sampleRate = asbd.pointee.mSampleRate
                channelCount = Int(asbd.pointee.mChannelsPerFrame)
            }
        } else {
            if isVideo {
                throw NSError(domain: "LightAudio", code: 2, userInfo: [NSLocalizedDescriptionKey: L10n.tr("This video does not contain an audio track.")])
            }
            let file = try AVAudioFile(forReading: url)
            sampleRate = file.fileFormat.sampleRate
            channelCount = Int(file.fileFormat.channelCount)
            if sampleRate > 0 {
                duration = Double(file.length) / sampleRate
            }
        }

        guard duration.isFinite, duration > 0, sampleRate > 0, channelCount > 0 else {
            throw NSError(domain: "LightAudio", code: 3, userInfo: [NSLocalizedDescriptionKey: L10n.tr("This media does not contain readable audio.")])
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        return MediaFileMetadata(
            fileName: url.lastPathComponent,
            fileSize: size,
            duration: duration,
            sampleRate: sampleRate,
            channelCount: channelCount,
            checksum: FileMetadataHasher.sha256Prefix(for: url)
        )
    }

    private func audioFormatDescription(from value: Any) -> CMAudioFormatDescription? {
        let reference = value as CFTypeRef
        guard CFGetTypeID(reference) == CMFormatDescriptionGetTypeID() else { return nil }
        return unsafeBitCast(reference, to: CMAudioFormatDescription.self)
    }
}
