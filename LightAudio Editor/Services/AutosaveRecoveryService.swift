import Foundation

final class AutosaveRecoveryService {
    private let fileService = ProjectFileService()
    private let recoveryDirectoryURL: URL
    private var timer: Timer?
    private var snapshotWritesSuspended = false
    private var activeSessionID: UUID?
    private(set) var activeProjectURL: URL?
    var projectProvider: (() -> Project?)?
    var isDirtyProvider: (() -> Bool)?

    init(recoveryDirectory: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        recoveryDirectoryURL = recoveryDirectory ?? base.appendingPathComponent("LightAudio Editor/Recovery", isDirectory: true)
    }

    private var recoveryDirectory: URL {
        recoveryDirectoryURL
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
        guard !snapshotWritesSuspended,
              let project = projectProvider?(),
              let projectURL = activeProjectURL,
              let sessionID = activeSessionID,
              isDirtyProvider?() == true else { return }
        do {
            try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
            let savedDate = (try? FileManager.default.attributesOfItem(atPath: projectURL.path)[.modificationDate]) as? Date
            let snapshot = ProjectRecoverySnapshot(createdAt: Date(), sessionID: sessionID, originalProjectURL: projectURL, project: project, wasDirty: true, savedProjectModificationDate: savedDate)
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
        var metadata = loadMetadata()

        // A displayed recovery sheet may outlive the app session that displayed it. Preserve the
        // specific snapshot until the user chooses an action instead of losing it to a later
        // session identifier after another quit or crash.
        if let pendingKey = metadata.pendingSnapshotKey {
            if let pending = allSnapshots().first(where: { snapshotKey(url: $0.0, snapshot: $0.1) == pendingKey }),
               isSnapshotRecoverable(pending.1) {
                return pending
            }
            metadata.pendingSnapshotKey = nil
            saveMetadata(metadata)
        }

        guard metadata.cleanShutdown == false,
              let crashedSessionID = metadata.activeSessionID else {
            return nil
        }

        for (url, snapshot) in allSnapshots() {
            // Legacy snapshots lack a session token and cannot be safely attributed to the app session that crashed.
            guard snapshot.sessionID == crashedSessionID,
                  !metadata.consumedSnapshotKeys.contains(snapshotKey(url: url, snapshot: snapshot)),
                  snapshot.wasDirty else {
                continue
            }

            guard isSnapshotRecoverable(snapshot) else {
                markSnapshotConsumed(url: url, snapshot: snapshot)
                removeSnapshot(at: url)
                continue
            }
            return (url, snapshot)
        }
        return nil
    }

    /// Pins a snapshot while its recovery sheet is presented. The snapshot remains eligible even
    /// if the user quits before responding, and is cleared only by an explicit recovery choice.
    func markSnapshotPending(url: URL, snapshot: ProjectRecoverySnapshot) {
        var metadata = loadMetadata()
        metadata.pendingSnapshotKey = snapshotKey(url: url, snapshot: snapshot)
        saveMetadata(metadata)
    }

    func removeSnapshot(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func markSessionStarted() {
        if activeSessionID == nil {
            activeSessionID = UUID()
        }
        var metadata = loadMetadata()
        metadata.cleanShutdown = false
        metadata.activeSessionID = activeSessionID
        saveMetadata(metadata)
    }

    /// Cache clearing deliberately removes recovery metadata. Recreate the active-session marker
    /// so later autosaves remain discoverable if the app stops unexpectedly.
    func resumeSessionAfterRecoveryCacheClear() {
        guard let activeSessionID else { return }
        var metadata = loadMetadata()
        metadata.cleanShutdown = false
        metadata.activeSessionID = activeSessionID
        saveMetadata(metadata)
    }

    func markCleanShutdown() {
        var metadata = loadMetadata()
        let sessionID = activeSessionID ?? metadata.activeSessionID
        if let sessionID {
            removeSnapshots(for: sessionID)
        }
        metadata.cleanShutdown = true
        metadata.activeSessionID = nil
        saveMetadata(metadata)
        activeSessionID = nil
    }

    func markSnapshotConsumed(url: URL, snapshot: ProjectRecoverySnapshot) {
        var metadata = loadMetadata()
        let key = snapshotKey(url: url, snapshot: snapshot)
        metadata.consumedSnapshotKeys.insert(key)
        if metadata.pendingSnapshotKey == key {
            metadata.pendingSnapshotKey = nil
        }
        saveMetadata(metadata)
    }

    func setSnapshotWritesSuspended(_ suspended: Bool) {
        snapshotWritesSuspended = suspended
    }

    func discardSnapshot(forProjectID projectID: UUID) {
        let url = recoveryDirectory.appendingPathComponent("\(projectID.uuidString).recovery.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if let snapshot = try? fileService.decodeRecovery(from: url) {
            markSnapshotConsumed(url: url, snapshot: snapshot)
        }
        removeSnapshot(at: url)
    }

    private func snapshotKey(url: URL, snapshot: ProjectRecoverySnapshot) -> String {
        "\(url.lastPathComponent)|\(snapshot.createdAt.timeIntervalSince1970)"
    }

    private func allSnapshots() -> [(URL, ProjectRecoverySnapshot)] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: recoveryDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        return files.compactMap { url -> (URL, ProjectRecoverySnapshot)? in
            guard let snapshot = try? fileService.decodeRecovery(from: url) else { return nil }
            return (url, snapshot)
        }
        .sorted { $0.1.createdAt > $1.1.createdAt }
    }

    private func removeSnapshots(for sessionID: UUID) {
        for (url, snapshot) in allSnapshots() where snapshot.sessionID == sessionID {
            removeSnapshot(at: url)
        }
    }

    private func isSnapshotRecoverable(_ snapshot: ProjectRecoverySnapshot) -> Bool {
        guard snapshot.wasDirty, snapshot.originalProjectURL != nil else { return false }
        if let savedURL = snapshot.originalProjectURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: savedURL.path),
           let savedDate = attrs[.modificationDate] as? Date,
           savedDate >= snapshot.createdAt {
            return false
        }
        if let lastSavedAt = snapshot.project.lastSavedAt, lastSavedAt >= snapshot.createdAt {
            return false
        }
        return true
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
    var activeSessionID: UUID?
    var pendingSnapshotKey: String?
    var consumedSnapshotKeys: Set<String> = []
}
