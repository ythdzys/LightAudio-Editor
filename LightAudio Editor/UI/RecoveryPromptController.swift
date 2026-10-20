import AppKit

enum RecoveryChoice {
    case restore
    case lastSaved
    case cancel
}

final class RecoveryPromptController {
    static func show(for snapshot: ProjectRecoverySnapshot, canOpenLastSaved: Bool, window: NSWindow?, completion: @escaping (RecoveryChoice) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("Recovered project found")
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        let createdAt = formatter.string(from: snapshot.createdAt)
        alert.informativeText = canOpenLastSaved
            ? L10n.format("A recovery snapshot from %@ is newer than the last saved project.", createdAt)
            : L10n.format("A recovery snapshot from %@ is available, but the original .liau project file is no longer at its saved location.", createdAt)
        alert.addButton(withTitle: L10n.tr("Restore Recovered Version"))
        if canOpenLastSaved {
            alert.addButton(withTitle: L10n.tr("Open Last Saved Version"))
        }
        alert.addButton(withTitle: L10n.tr("Decide Later"))

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                completion(.restore)
            } else if canOpenLastSaved && response == .alertSecondButtonReturn {
                completion(.lastSaved)
            } else {
                completion(.cancel)
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }
}
