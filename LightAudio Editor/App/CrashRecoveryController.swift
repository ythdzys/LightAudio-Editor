import AppKit

final class CrashRecoveryController {
    private let recoveryService: AutosaveRecoveryService

    init(recoveryService: AutosaveRecoveryService) {
        self.recoveryService = recoveryService
    }

    func checkForRecovery(presenter: NSWindow?, openSaved: @escaping (URL) -> Void, restore: @escaping (ProjectRecoverySnapshot) -> Void) {
        guard let (url, snapshot) = recoveryService.latestRecoverableSnapshot() else { return }
        let canOpenLastSaved = snapshot.originalProjectURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        recoveryService.markSnapshotPending(url: url, snapshot: snapshot)

        RecoveryPromptController.show(for: snapshot, canOpenLastSaved: canOpenLastSaved, window: presenter) { [weak self] choice in
            switch choice {
            case .restore:
                restore(snapshot)
            case .lastSaved:
                if let savedURL = snapshot.originalProjectURL,
                   FileManager.default.fileExists(atPath: savedURL.path) {
                    openSaved(savedURL)
                } else {
                    // The project was moved while the prompt was shown; preserve the recovered edits.
                    restore(snapshot)
                }
            case .cancel:
                break
            }
            self?.recoveryService.markSnapshotConsumed(url: url, snapshot: snapshot)
            self?.recoveryService.removeSnapshot(at: url)
        }
    }
}
