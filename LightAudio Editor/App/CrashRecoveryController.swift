import AppKit

final class CrashRecoveryController {
    private let recoveryService: AutosaveRecoveryService

    init(recoveryService: AutosaveRecoveryService) {
        self.recoveryService = recoveryService
    }

    func checkForRecovery(presenter: NSWindow?, openSaved: @escaping (URL) -> Void, restore: @escaping (ProjectRecoverySnapshot) -> Void) {
        guard let (url, snapshot) = recoveryService.latestRecoverableSnapshot() else { return }

        RecoveryPromptController.show(for: snapshot, window: presenter) { [weak self] choice in
            switch choice {
            case .restore:
                restore(snapshot)
            case .lastSaved:
                if let savedURL = snapshot.originalProjectURL {
                    openSaved(savedURL)
                }
            case .cancel:
                break
            }
            self?.recoveryService.markSnapshotConsumed(url: url, snapshot: snapshot)
            self?.recoveryService.removeSnapshot(at: url)
        }
    }
}
