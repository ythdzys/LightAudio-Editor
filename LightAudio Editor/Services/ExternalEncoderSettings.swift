import Foundation

enum ExternalEncoderSettings {
    private static let ffmpegPathKey = "LightAudioFFmpegPath"

    static var ffmpegPath: String? {
        get {
            let stored = UserDefaults.standard.string(forKey: ffmpegPathKey)
            if let stored = stored, !stored.isEmpty { return stored }
            return detectedFFmpegPath()
        }
        set {
            UserDefaults.standard.set(newValue, forKey: ffmpegPathKey)
        }
    }

    static func detectedFFmpegPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func ffmpegVersion(path: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-version"]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return text.components(separatedBy: .newlines).first
        } catch {
            return nil
        }
    }
}
