import Foundation
import CryptoKit

final class AutosaveRecoveryService {
    private let fileService = ProjectFileService()
    private let ioQueue = DispatchQueue(label: "com.lightaudio.recovery-writes", qos: .utility)
    private let ioKey = DispatchSpecificKey<Bool>()
    private func serialized<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: ioKey) == true { return try body() }
        return try ioQueue.sync(execute: body)
    }
    private let recoveryDirectoryURL: URL
    private var timer: Timer?
    private var snapshotWritesSuspended = false
    private var activeSessionID: UUID?
    private(set) var activeProjectURL: URL?
    var projectProvider: (() -> Project?)?
    var isDirtyProvider: (() -> Bool)?

    init(recoveryDirectory: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        ioQueue.setSpecific(key: ioKey, value: true)
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
            self?.writeSnapshot(asynchronously: true)
        }
    }

    func updateProjectURL(_ url: URL?) {
        activeProjectURL = url
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func writeSnapshot(asynchronously: Bool = false) {
        guard !snapshotWritesSuspended,
              let project = projectProvider?(),
              let projectURL = activeProjectURL,
              let sessionID = activeSessionID,
              isDirtyProvider?() == true else { return }
        let capturedAt = Date()
        let work = { self.writeSnapshot(project: project, projectURL: projectURL, sessionID: sessionID, capturedAt: capturedAt) }
        if asynchronously { ioQueue.async(execute: work) }
        else { serialized(work) }
    }

    private func writeSnapshot(project: Project, projectURL: URL, sessionID: UUID, capturedAt: Date) {
        let snapshots = allSnapshots()
        let matching = snapshots.filter { $0.1.project.id == project.id && sameDocument($0.1.originalProjectURL, projectURL) }
        // Imported backups may retain the same project ID in independent local folders.
        // Protect only the pending document, not every copy sharing that ID.
        if let pending = loadMetadata().pendingSnapshotKey,
           matching.contains(where: { snapshotKey(url: $0.0, snapshot: $0.1) == pending }) { return }
        do {
            try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
            let savedDate = (try? FileManager.default.attributesOfItem(atPath: projectURL.path)[.modificationDate]) as? Date
            let snapshot = ProjectRecoverySnapshot(createdAt: capturedAt, sessionID: sessionID, originalProjectURL: projectURL, project: project, wasDirty: true, savedProjectModificationDate: savedDate)
            let legacy = recoveryDirectory.appendingPathComponent("\(project.id.uuidString).recovery.json")
            let destination: URL
            if let existing = matching.first { destination = existing.0 }
            else if !FileManager.default.fileExists(atPath: legacy.path) { destination = legacy }
            else {
                let digest = SHA256.hash(data: Data(Self.documentPath(projectURL).utf8)).map { String(format: "%02x", $0) }.joined()
                destination = recoveryDirectory.appendingPathComponent("\(project.id.uuidString)-\(digest).recovery.json")
            }
            try fileService.encodeRecovery(snapshot, to: destination)
        } catch {
            NSLog("Recovery snapshot failed: \(error)")
        }
    }

    func latestRecoverableSnapshot() -> (URL, ProjectRecoverySnapshot)? {
        return serialized {
            var metadata = loadMetadata()

            // A displayed recovery sheet may outlive the app session that displayed it. Preserve the
            // specific snapshot until the user chooses an action instead of losing it to a later
            // session identifier after another quit or crash.
            if let pendingKey = metadata.pendingSnapshotKey {
                if let pending = allSnapshots().first(where: { snapshotKey(url: $0.0, snapshot: $0.1) == pendingKey }),
                   !metadata.consumedSnapshotKeys.contains(pendingKey),
                   isSnapshotRecoverable(pending.1) {
                    return pending
                }
                metadata.pendingSnapshotKey = nil
                saveMetadata(metadata)
            }

            var eligibleSessions = metadata.interruptedSessionIDs ?? []
            if !metadata.cleanShutdown, let previous = metadata.activeSessionID {
                eligibleSessions.insert(previous)
            }
            for (url, snapshot) in allSnapshots() {
                // Legacy snapshots lack a session token and cannot be safely attributed to the app session that crashed.
                guard let sessionID = snapshot.sessionID, eligibleSessions.contains(sessionID),
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
    }

    /// Pins a snapshot while its recovery sheet is presented. The snapshot remains eligible even
    /// if the user quits before responding, and is cleared only by an explicit recovery choice.
    func markSnapshotPending(url: URL, snapshot: ProjectRecoverySnapshot) {
        return serialized {
            var metadata = loadMetadata()
            metadata.pendingSnapshotKey = snapshotKey(url: url, snapshot: snapshot)
            saveMetadata(metadata)
        }
    }

    func removeSnapshot(at url: URL) {
        return serialized {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func markSessionStarted() {
        return serialized {
            if activeSessionID == nil {
                activeSessionID = UUID()
            }
            var metadata = loadMetadata()
            // Preserve the interrupted session even when an older pinned recovery is offered first.
            var interrupted = metadata.interruptedSessionIDs ?? []
            if !metadata.cleanShutdown, let previous = metadata.activeSessionID, previous != activeSessionID {
                interrupted.insert(previous)
            }
            let remainingSessions = Set(allSnapshots().compactMap { $0.1.sessionID })
            metadata.interruptedSessionIDs = interrupted.intersection(remainingSessions)
            metadata.cleanShutdown = false
            metadata.activeSessionID = activeSessionID
            saveMetadata(metadata)
        }
    }

    /// Cache clearing deliberately removes recovery metadata. Recreate the active-session marker
    /// so later autosaves remain discoverable if the app stops unexpectedly.
    func resumeSessionAfterRecoveryCacheClear() {
        return serialized {
            guard let activeSessionID else { return }
            var metadata = loadMetadata()
            metadata.cleanShutdown = false
            metadata.activeSessionID = activeSessionID
            saveMetadata(metadata)
        }
    }

    func markCleanShutdown() {
        return serialized {
            var metadata = loadMetadata()
            let sessionID = activeSessionID ?? metadata.activeSessionID
            if let sessionID {
                removeSnapshots(for: sessionID)
                metadata.interruptedSessionIDs?.remove(sessionID)
            }
            metadata.cleanShutdown = true
            metadata.activeSessionID = nil
            saveMetadata(metadata)
            activeSessionID = nil
        }
    }

    func markSnapshotConsumed(url: URL, snapshot: ProjectRecoverySnapshot) {
        return serialized {
            var metadata = loadMetadata()
            let key = snapshotKey(url: url, snapshot: snapshot)
            metadata.consumedSnapshotKeys.insert(key)
            if metadata.pendingSnapshotKey == key {
                metadata.pendingSnapshotKey = nil
            }
            saveMetadata(metadata)
        }
    }

    func setSnapshotWritesSuspended(_ suspended: Bool) {
        snapshotWritesSuspended = suspended
    }

    func discardSnapshot(forProjectID projectID: UUID, asynchronously: Bool = false) {
        guard let document = activeProjectURL else { return }
        let work = { self.discardSnapshotOnQueue(projectID: projectID, document: document) }
        if asynchronously { ioQueue.async(execute: work) }
        else { serialized(work) }
    }
    private func discardSnapshotOnQueue(projectID: UUID, document: URL) {
        let pending = loadMetadata().pendingSnapshotKey
        for (url, snapshot) in allSnapshots() where snapshot.project.id == projectID && sameDocument(snapshot.originalProjectURL, document) {
            guard pending != snapshotKey(url: url, snapshot: snapshot) else { continue }
            markSnapshotConsumed(url: url, snapshot: snapshot)
            removeSnapshot(at: url)
        }
    }

    private func sameDocument(_ first: URL?, _ second: URL) -> Bool {
        first.map { Self.documentPath($0) == Self.documentPath(second) } ?? false
    }

    /// Resolve the nearest existing ancestor too, for missing document/folder recovery
    /// and the /private/var alias used on devices.
    static func documentPath(_ url: URL) -> String {
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        while ancestor.path != "/" && !FileManager.default.fileExists(atPath: ancestor.path) {
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missing.reversed() { resolved.appendPathComponent(component) }
        return resolved.path
    }

    private func snapshotKey(url: URL, snapshot: ProjectRecoverySnapshot) -> String {
        "\(url.lastPathComponent)|\(snapshot.createdAt.timeIntervalSince1970)"
    }

    /// Maintenance must fail closed if any recovery snapshot cannot be inspected.
    func projectsProtectedByRecovery() throws -> [(Project, URL?)] {
        try serialized {
            guard FileManager.default.fileExists(atPath: recoveryDirectory.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: recoveryDirectory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix(".recovery.json") }
                .map { let snapshot = try fileService.decodeRecovery(from: $0); return (snapshot.project, snapshot.originalProjectURL) }
        }
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
        guard snapshot.wasDirty, let savedURL = snapshot.originalProjectURL else { return false }
        // File modification time records when I/O finished, not which edit revision it saved.
        // An older background save can finish after a newer recovery was captured. Retire a
        // snapshot only when the saved editing content proves it is already durable. Ambiguous,
        // missing, unreadable and legacy files must keep their recovery available.
        return (try? fileService.savedEditingContentMatches(snapshot.project, at: savedURL)) != true
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
    // Optional so metadata written by earlier versions remains decodable.
    var interruptedSessionIDs: Set<UUID>?
    var consumedSnapshotKeys: Set<String> = []
}
