import Foundation

struct RelinkResult {
    var accepted: Bool
    var reason: String
    var updatedAsset: MediaAsset?
    var warnings: [String] = []

    var requiresConfirmation: Bool {
        accepted && !warnings.isEmpty
    }

    var isSafeForAutomaticRelink: Bool {
        accepted && warnings.isEmpty
    }
}

final class MediaRelinkService {
    private let importService = MediaImportService()
    private let resolver = FileReferenceResolver()

    func verifyAndRelink(asset: MediaAsset, replacementURL: URL, projectURL: URL?) -> RelinkResult {
        do {
            guard AudioFormatHelpers.supportedImportExtension(replacementURL.pathExtension) else {
                return RelinkResult(accepted: false, reason: L10n.tr("Unsupported media type."), updatedAsset: nil)
            }
            if asset.kind == .videoAudio && !AudioFormatHelpers.isVideoExtension(replacementURL.pathExtension) {
                return RelinkResult(accepted: false, reason: L10n.tr("Choose a video file with a matching audio track for this video-origin asset."), updatedAsset: nil)
            }
            if asset.kind == .audio && AudioFormatHelpers.isVideoExtension(replacementURL.pathExtension) {
                return RelinkResult(accepted: false, reason: L10n.tr("Choose an audio file for this audio asset."), updatedAsset: nil)
            }
            let replacement = try importService.metadata(for: replacementURL)
            let durationDelta = abs(replacement.duration - asset.metadata.duration)
            // Old direct-decoded MP3/AAC imports could persist a wrong AVAsset duration.
            // Verified identical bytes may refresh that metadata despite a large delta;
            // the controller still checks every current clip before accepting the result.
            let ext = replacementURL.pathExtension.lowercased()
            let correctsLegacyDuration = ["mp3", "aac"].contains(ext)
                && URL(fileURLWithPath: asset.originalPath).pathExtension.lowercased() == ext
                && asset.metadata.checksum?.hasPrefix("sha256:") == true
                && asset.metadata.checksum == replacement.checksum
            guard durationDelta <= 0.25 || correctsLegacyDuration else {
                return RelinkResult(accepted: false, reason: L10n.tr("Duration does not match closely enough."), updatedAsset: nil)
            }

            var warnings: [String] = []
            if replacement.sampleRate != asset.metadata.sampleRate { warnings.append(L10n.tr("sample rate differs")) }
            if replacement.channelCount != asset.metadata.channelCount { warnings.append(L10n.tr("channel count differs")) }
            if replacement.fileSize != asset.metadata.fileSize { warnings.append(L10n.tr("file size differs")) }
            if replacement.fileName != asset.metadata.fileName { warnings.append(L10n.tr("file name differs")) }
            if let expected = asset.metadata.checksum, expected.hasPrefix("sha256:") {
                if expected != replacement.checksum { warnings.append(L10n.tr("audio checksum differs")) }
            } else {
                warnings.append(L10n.tr("The original project has no full-file fingerprint; confirm this replacement manually."))
            }

            var updated = asset
            updated.originalPath = replacementURL.path
            updated.relativePath = resolver.relativePath(for: replacementURL, projectURL: projectURL)
            updated.resolvedPath = replacementURL.standardizedFileURL.path
            updated.metadata = replacement
            // Older FLAC imports used packet-rounded durations. Relinking the
            // identical bytes must not invalidate or silently shorten saved trims.
            // Fresh imports use the exact PCM extent; existing edits keep theirs.
            if replacementURL.pathExtension.lowercased() == "flac",
               let expected = asset.metadata.checksum, expected.hasPrefix("sha256:"),
               expected == replacement.checksum {
                updated.metadata.duration = asset.metadata.duration
            }
            updated.proxyPath = nil
            updated.proxyCacheKey = nil
            updated.proxyFailureReason = nil
            updated.sourceModificationTimestamp = resolver.sourceModificationTimestamp(for: replacementURL)
            updated.isMissing = false
            updated.isVerifyingSource = false
            updated.sourceVerificationFailure = nil
            updated.waveformCacheKey = nil
            let suffix = warnings.isEmpty
                ? L10n.tr("Relinked.")
                : L10n.format("Candidate needs confirmation: %@.", warnings.joined(separator: L10n.tr(", ")))
            return RelinkResult(accepted: true, reason: suffix, updatedAsset: updated, warnings: warnings)
        } catch {
            return RelinkResult(accepted: false, reason: error.localizedDescription, updatedAsset: nil)
        }
    }
}
