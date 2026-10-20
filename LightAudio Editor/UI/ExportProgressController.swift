import AppKit

final class ExportProgressController: NSWindowController {
    var onCancel: (() -> Void)?

    private let progress = NSProgressIndicator()
    private let label = NSTextField(labelWithString: L10n.tr("Exporting..."))

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 124), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = L10n.tr("Export")
        super.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showActivity(_ text: String) {
        window?.title = text
        label.stringValue = text
        progress.isIndeterminate = true
        progress.startAnimation(nil)
    }

    func update(progress value: Double) {
        progress.doubleValue = min(1, max(0, value)) * 100
        label.stringValue = L10n.format("Exporting %d%%", Int(progress.doubleValue))
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        let cancel = NSButton(title: L10n.tr("Cancel"), target: self, action: #selector(cancelExport))
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(progress)
        stack.addArrangedSubview(cancel)
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            progress.widthAnchor.constraint(equalToConstant: 324)
        ])
    }

    @objc private func cancelExport() {
        onCancel?()
    }
}
