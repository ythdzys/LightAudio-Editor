import Foundation
import Darwin

enum ExternalEncoderSettings {
    private static let ffmpegPathKey = "LightAudioFFmpegPath"
    private static let processTimeout: TimeInterval = 3
    private static let encoderLock = NSLock()
    private static var cachedEncoderNames: [String: Set<String>] = [:]

    static var ffmpegPath: String? {
        get {
            preferredFFmpegPath(
                configuredPath: configuredFFmpegPath,
                bundledPath: bundledFFmpegPath,
                systemCandidates: systemFFmpegCandidates
            )
        }
        set {
            configuredFFmpegPath = newValue
        }
    }

    /// An optional user override. A blank value deliberately falls back to the
    /// signed helper inside the app bundle, then to a compatible system install.
    static var configuredFFmpegPath: String? {
        get {
            normalizedPath(UserDefaults.standard.string(forKey: ffmpegPathKey))
        }
        set {
            if let path = normalizedPath(newValue) {
                UserDefaults.standard.set(path, forKey: ffmpegPathKey)
            } else {
                UserDefaults.standard.removeObject(forKey: ffmpegPathKey)
            }
            encoderLock.lock()
            cachedEncoderNames.removeAll()
            encoderLock.unlock()
        }
    }

    static var bundledFFmpegPath: String? {
        let bundles = [Bundle.main, Bundle(for: BundleLocator.self)]
        for bundle in bundles {
            if let path = bundle.path(forResource: "ffmpeg", ofType: nil, inDirectory: "BundledEncoder"),
               FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    static func detectedFFmpegPath() -> String? {
        preferredFFmpegPath(
            configuredPath: nil,
            bundledPath: bundledFFmpegPath,
            systemCandidates: systemFFmpegCandidates
        )
    }

    static func sourceDescription(for path: String) -> String {
        if pathsReferToSameFile(path, bundledFFmpegPath) {
            return "Bundled FFmpeg"
        }
        if pathsReferToSameFile(path, configuredFFmpegPath) {
            return "Custom FFmpeg"
        }
        return "System FFmpeg"
    }

    static func preferredFFmpegPath(
        configuredPath: String?,
        bundledPath: String?,
        systemCandidates: [String],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let configuredPath = normalizedPath(configuredPath) {
            // Keep an invalid explicit override visible so Preferences can report it,
            // instead of silently exporting with a different binary.
            return configuredPath
        }
        if let bundledPath = normalizedPath(bundledPath), isExecutable(bundledPath) {
            return bundledPath
        }
        return systemCandidates.first(where: isExecutable)
    }

    static func ffmpegVersion(path: String) -> String? {
        guard let result = runTextCommand(path: path, arguments: ["-version"]) else { return nil }
        return String(data: result, encoding: .utf8)?.components(separatedBy: .newlines).first
    }

    /// Queries the configured binary once and caches the supported audio encoders by file identity.
    /// Export availability can then distinguish a valid executable from a build that lacks a codec.
    static func audioEncoderNames(path: String) -> Set<String>? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let cacheKey = encoderCacheKey(for: path)
        encoderLock.lock()
        if let cached = cachedEncoderNames[cacheKey] {
            encoderLock.unlock()
            return cached
        }
        encoderLock.unlock()

        guard let data = runTextCommand(path: path, arguments: ["-hide_banner", "-encoders"]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let encoders = Set(text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0].first == "A" else { return nil }
            return String(fields[1])
        })
        encoderLock.lock()
        cachedEncoderNames[cacheKey] = encoders
        encoderLock.unlock()
        return encoders
    }

    /// Runs user-configured encoder probes with bounded output and a hard timeout so a broken
    /// binary cannot hold the Preferences or Export panels hostage.
    private static func runTextCommand(path: String, arguments: [String]) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        let output = Pipe()
        let outputLock = NSLock()
        var collected = Data()
        let limit = 512 * 1024

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputLock.lock()
            if collected.count < limit {
                collected.append(data.prefix(limit - collected.count))
            }
            outputLock.unlock()
        }

        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        let deadline = Date().addingTimeInterval(processTimeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let graceDeadline = Date().addingTimeInterval(0.25)
            while process.isRunning, Date() < graceDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        // Do not synchronously drain to EOF here. A malformed helper can leave a child process
        // holding the inherited pipe open after the parent has been terminated.
        output.fileHandleForReading.closeFile()
        outputLock.lock()
        let result = collected
        outputLock.unlock()
        guard !timedOut, process.terminationStatus == 0 else { return nil }
        return result
    }

    private static func encoderCacheKey(for path: String) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.stringValue ?? ""
        let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)|\(size)|\(date)"
    }

    private static let systemFFmpegCandidates = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg"
    ]

    private static func normalizedPath(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return (path as NSString).expandingTildeInPath
    }

    private static func pathsReferToSameFile(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = normalizedPath(lhs), let rhs = normalizedPath(rhs) else { return false }
        return URL(fileURLWithPath: lhs).resolvingSymlinksInPath().standardizedFileURL
            == URL(fileURLWithPath: rhs).resolvingSymlinksInPath().standardizedFileURL
    }

    private final class BundleLocator: NSObject {}
}
