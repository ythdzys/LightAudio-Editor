import Foundation

final class AutosaveRecoveryService {
    private let fileService = ProjectFileService()
    private var timer: Timer?
    private(set) var activeProjectURL: URL?
    var projectProvider: (() -> Project?)?
    var isDirtyProvider: (() -> Bool)?

    private var recoveryDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LightAudio Editor/Recovery", isDirectory: true)
    }

    private var metadataURL: URL {
        recoveryDirectory.appendingPathComponent("recovery-state.json")
    }

    func start(projectURL: URL?, interval: TimeInterval = 20) {
        activeProjectURL = projectURL
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.writeSnapshot()
        }
    }

    func updateProjectURL(_ url: URL?) {
        activeProjectURL = url
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func writeSnapshot() {
        guard let project = projectProvider?(),
              let projectURL = activeProjectURL,
              isDirtyProvider?() == true else { return }
        do {
            try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
            let savedDate = (try? FileManager.default.attributesOfItem(atPath: projectURL.path)[.modificationDate]) as? Date
            let snapshot = ProjectRecoverySnapshot(createdAt: Date(), originalProjectURL: projectURL, project: project, wasDirty: true, savedProjectModificationDate: savedDate)
            let name = "\(project.id.uuidString).recovery.json"
            try fileService.encodeRecovery(snapshot, to: recoveryDirectory.appendingPathComponent(name))
        } catch {
            NSLog("Recovery snapshot failed: \(error)")
        }
    }

    func latestSnapshot() -> (URL, ProjectRecoverySnapshot)? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: recoveryDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return files.compactMap { url -> (URL, ProjectRecoverySnapshot)? in
            guard let snapshot = try? fileService.decodeRecovery(from: url) else { return nil }
            return (url, snapshot)
        }
        .sorted { $0.1.createdAt > $1.1.createdAt }
        .first
    }

    func latestRecoverableSnapshot() -> (URL, ProjectRecoverySnapshot)? {
        let metadata = loadMetadata()
        guard metadata.cleanShutdown == false,
              let (url, snapshot) = latestSnapshot(),
              !metadata.consumedSnapshotKeys.contains(snapshotKey(url: url, snapshot: snapshot)),
              snapshot.wasDirty,
              let savedURL = snapshot.originalProjectURL else {
            return nil
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: savedURL.path),
              let savedDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        if savedDate >= snapshot.createdAt {
            markSnapshotConsumed(url: url, snapshot: snapshot)
            removeSnapshot(at: url)
            return nil
        }
        if let lastSavedAt = snapshot.project.lastSavedAt, lastSavedAt >= snapshot.createdAt {
            markSnapshotConsumed(url: url, snapshot: snapshot)
            removeSnapshot(at: url)
            return nil
        }
        return (url, snapshot)
    }

    func removeSnapshot(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func markSessionStarted() {
        var metadata = loadMetadata()
        metadata.cleanShutdown = false
        saveMetadata(metadata)
    }

    func markCleanShutdown() {
        var metadata = loadMetadata()
        metadata.cleanShutdown = true
        saveMetadata(metadata)
    }

    func markSnapshotConsumed(url: URL, snapshot: ProjectRecoverySnapshot) {
        var metadata = loadMetadata()
        metadata.consumedSnapshotKeys.insert(snapshotKey(url: url, snapshot: snapshot))
        saveMetadata(metadata)
    }

    private func snapshotKey(url: URL, snapshot: ProjectRecoverySnapshot) -> String {
        "\(url.lastPathComponent)|\(snapshot.createdAt.timeIntervalSince1970)"
    }

    private func loadMetadata() -> RecoveryMetadata {
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(RecoveryMetadata.self, from: data) else {
            return RecoveryMetadata()
        }
        return metadata
    }

    private func saveMetadata(_ metadata: RecoveryMetadata) {
        do {
            try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            NSLog("Recovery metadata failed: \(error)")
        }
    }
}

private struct RecoveryMetadata: Codable {
    var cleanShutdown: Bool = true
    var consumedSnapshotKeys: Set<String> = []
}
