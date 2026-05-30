import Foundation

struct RelinkResult {
    var accepted: Bool
    var reason: String
    var updatedAsset: MediaAsset?
}

final class MediaRelinkService {
    private let importService = MediaImportService()
    private let resolver = FileReferenceResolver()

    func verifyAndRelink(asset: MediaAsset, replacementURL: URL, projectURL: URL?) -> RelinkResult {
        do {
            if asset.kind == .videoAudio && !AudioFormatHelpers.isVideoExtension(replacementURL.pathExtension) {
                return RelinkResult(accepted: false, reason: "Choose a video file with a matching audio track for this video-origin asset.", updatedAsset: nil)
            }
            if asset.kind == .audio && AudioFormatHelpers.isVideoExtension(replacementURL.pathExtension) {
                return RelinkResult(accepted: false, reason: "Choose an audio file for this audio asset.", updatedAsset: nil)
            }
            let replacement = try importService.metadata(for: replacementURL)
            let durationDelta = abs(replacement.duration - asset.metadata.duration)
            guard durationDelta <= 0.25 else {
                return RelinkResult(accepted: false, reason: "Duration does not match closely enough.", updatedAsset: nil)
            }

            var warnings: [String] = []
            if replacement.sampleRate != asset.metadata.sampleRate { warnings.append("sample rate differs") }
            if replacement.channelCount != asset.metadata.channelCount { warnings.append("channel count differs") }
            if replacement.fileSize != asset.metadata.fileSize { warnings.append("file size differs") }
            if replacement.fileName != asset.metadata.fileName { warnings.append("file name differs") }

            var updated = asset
            updated.originalPath = replacementURL.path
            updated.relativePath = resolver.relativePath(for: replacementURL, projectURL: projectURL)
            updated.metadata = replacement
            updated.proxyPath = asset.kind == .videoAudio ? nil : updated.proxyPath
            updated.proxyCacheKey = asset.kind == .videoAudio ? nil : updated.proxyCacheKey
            updated.proxyFailureReason = nil
            updated.isMissing = false
            let suffix = warnings.isEmpty ? "Relinked." : "Relinked with warnings: \(warnings.joined(separator: ", "))."
            return RelinkResult(accepted: true, reason: suffix, updatedAsset: updated)
        } catch {
            return RelinkResult(accepted: false, reason: error.localizedDescription, updatedAsset: nil)
        }
    }
}
