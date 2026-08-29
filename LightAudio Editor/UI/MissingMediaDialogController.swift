import AppKit

enum MissingMediaAction {
    case relinkFirst(UUID)
    case locateFolder
    case dismiss
}

final class MissingMediaDialogController {
    static func show(missing: [MediaAsset], window: NSWindow?, completion: @escaping (MissingMediaAction) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("Missing media")
        alert.informativeText = L10n.format("This project opened, but editing, playback, and export are disabled until these files are relinked:\n\n%@", missing.map { $0.metadata.fileName }.joined(separator: "\n"))
        alert.addButton(withTitle: L10n.tr("Relink First"))
        alert.addButton(withTitle: L10n.tr("Locate Folder"))
        alert.addButton(withTitle: L10n.tr("Continue Offline"))
        alert.beginSheetModal(for: window!) { response in
            switch response {
            case .alertFirstButtonReturn:
                completion(.relinkFirst(missing[0].id))
            case .alertSecondButtonReturn:
                completion(.locateFolder)
            default:
                completion(.dismiss)
            }
        }
    }
}
