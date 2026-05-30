import Foundation

enum AudioFormatHelpers {
    static let audioExtensions = ["mp3", "wav", "m4a", "aac", "flac", "aiff", "aif", "caf"]
    static let videoExtensions = ["mp4", "mov", "m4v", "mkv", "avi"]

    static func supportedImportExtension(_ ext: String) -> Bool {
        let lower = ext.lowercased()
        return audioExtensions.contains(lower) || videoExtensions.contains(lower)
    }

    static func isVideoExtension(_ ext: String) -> Bool {
        videoExtensions.contains(ext.lowercased())
    }
}
