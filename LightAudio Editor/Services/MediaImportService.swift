import Foundation
import AVFoundation

final class MediaImportService {
    private let resolver = FileReferenceResolver()

    func importMedia(at url: URL, projectURL: URL?, completion: @escaping (Result<MediaAsset, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard AudioFormatHelpers.supportedImportExtension(url.pathExtension) else {
                    throw NSError(domain: "LightAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported media type."])
                }
                let isVideo = AudioFormatHelpers.isVideoExtension(url.pathExtension)
                let metadata = try self.metadata(for: url)
                let asset = MediaAsset(
                    displayName: url.deletingPathExtension().lastPathComponent,
                    originalPath: url.path,
                    relativePath: self.resolver.relativePath(for: url, projectURL: projectURL),
                    kind: isVideo ? .videoAudio : .audio,
                    metadata: metadata,
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
        let duration = CMTimeGetSeconds(avAsset.duration)
        var sampleRate = 44100.0
        var channelCount = 2

        let isVideo = AudioFormatHelpers.isVideoExtension(url.pathExtension)
        if let track = avAsset.tracks(withMediaType: .audio).first,
           let description = track.formatDescriptions.first {
            let audioDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description as! CMAudioFormatDescription)
            if let asbd = audioDescription {
                sampleRate = asbd.pointee.mSampleRate
                channelCount = Int(asbd.pointee.mChannelsPerFrame)
            }
        } else if isVideo {
            throw NSError(domain: "LightAudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "This video does not contain an audio track."])
        } else {
            let file = try AVAudioFile(forReading: url)
            sampleRate = file.fileFormat.sampleRate
            channelCount = Int(file.fileFormat.channelCount)
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        return MediaFileMetadata(
            fileName: url.lastPathComponent,
            fileSize: size,
            duration: duration.isFinite ? duration : 0,
            sampleRate: sampleRate,
            channelCount: channelCount,
            checksum: FileMetadataHasher.sha256Prefix(for: url)
        )
    }
}
