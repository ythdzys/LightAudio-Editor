import AppKit

final class CrashRecoveryController {
    private let recoveryService: AutosaveRecoveryService

    init(recoveryService: AutosaveRecoveryService) {
        self.recoveryService = recoveryService
    }

    func checkForRecovery(
        presenter: NSWindow?,
        openSaved: @escaping (URL) -> Bool,
        restore: @escaping (ProjectRecoverySnapshot) -> Bool,
        completion: @escaping () -> Void = {}
    ) {
        guard let (url, snapshot) = recoveryService.latestRecoverableSnapshot() else {
            completion()
            return
        }
        let canOpenLastSaved = snapshot.originalProjectURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        recoveryService.markSnapshotPending(url: url, snapshot: snapshot)
        recoveryService.setSnapshotWritesSuspended(true)

        RecoveryPromptController.show(for: snapshot, canOpenLastSaved: canOpenLastSaved, window: presenter) { [weak self] choice in
            self?.resolve(choice, url: url, snapshot: snapshot, openSaved: openSaved, restore: restore)
            self?.recoveryService.setSnapshotWritesSuspended(false)
            completion()
        }
    }

    /// A restore callback succeeds only after the recovered edits have been saved.
    @discardableResult
    func resolve(_ choice: RecoveryChoice, url: URL, snapshot: ProjectRecoverySnapshot,
                 openSaved: (URL) -> Bool, restore: (ProjectRecoverySnapshot) -> Bool) -> Bool {
        let succeeded: Bool
        switch choice {
        case .restore:
            succeeded = restore(snapshot)
        case .lastSaved:
            if let savedURL = snapshot.originalProjectURL, FileManager.default.fileExists(atPath: savedURL.path) {
                succeeded = openSaved(savedURL)
            } else {
                succeeded = restore(snapshot)
            }
        case .cancel:
            return false
        }
        guard succeeded else { return false }
        recoveryService.markSnapshotConsumed(url: url, snapshot: snapshot)
        recoveryService.removeSnapshot(at: url)
        return true
    }
}
