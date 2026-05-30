import AppKit

enum RecoveryChoice {
    case restore
    case lastSaved
    case cancel
}

final class RecoveryPromptController {
    static func show(for snapshot: ProjectRecoverySnapshot, window: NSWindow?, completion: @escaping (RecoveryChoice) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Recovered project found"
        alert.informativeText = "A recovery snapshot from \(snapshot.createdAt) is newer than the last saved project."
        alert.addButton(withTitle: "Restore Recovered Version")
        alert.addButton(withTitle: "Open Last Saved Version")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { response in
            switch response {
            case .alertFirstButtonReturn: completion(.restore)
            case .alertSecondButtonReturn: completion(.lastSaved)
            default: completion(.cancel)
            }
        }
    }
}
