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
        alert.messageText = "Recovered project found"
        alert.informativeText = canOpenLastSaved
            ? "A recovery snapshot from \(snapshot.createdAt) is newer than the last saved project."
            : "A recovery snapshot from \(snapshot.createdAt) is available, but the original .liau project file is no longer at its saved location."
        alert.addButton(withTitle: "Restore Recovered Version")
        if canOpenLastSaved {
            alert.addButton(withTitle: "Open Last Saved Version")
        }
        alert.addButton(withTitle: "Cancel")

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
