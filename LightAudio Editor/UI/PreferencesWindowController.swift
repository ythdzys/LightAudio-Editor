import AppKit

final class PreferencesWindowController: NSWindowController {
    private let statusLabel = NSTextField(labelWithString: "")
    private let autoCrossfadeCheckbox = NSButton(checkboxWithTitle: "Automatically create crossfades when clips overlap", target: nil, action: nil)
    private let cacheStatusLabel = NSTextField(labelWithString: "")
    private let clearCacheButton = NSButton(title: "Clear App Cache", target: nil, action: nil)
    private let onClearApplicationCaches: (@escaping (Result<ApplicationCacheClearResult, Error>) -> Void) -> Void

    init(onClearApplicationCaches: @escaping (@escaping (Result<ApplicationCacheClearResult, Error>) -> Void) -> Void) {
        self.onClearApplicationCaches = onClearApplicationCaches
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Preferences"
        super.init(window: window)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        guard let content = window?.contentView else { return }
        autoCrossfadeCheckbox.state = EditorPreferences.automaticallyCreateCrossfades ? .on : .off
        autoCrossfadeCheckbox.target = self
        autoCrossfadeCheckbox.action = #selector(autoCrossfadeChanged)
        clearCacheButton.target = self
        clearCacheButton.action = #selector(clearApplicationCache)
        cacheStatusLabel.textColor = .secondaryLabelColor

        [autoCrossfadeCheckbox, statusLabel, clearCacheButton, cacheStatusLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }

        NSLayoutConstraint.activate([
            autoCrossfadeCheckbox.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            autoCrossfadeCheckbox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            autoCrossfadeCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            statusLabel.topAnchor.constraint(equalTo: autoCrossfadeCheckbox.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            clearCacheButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 30),
            clearCacheButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            cacheStatusLabel.centerYAnchor.constraint(equalTo: clearCacheButton.centerYAnchor),
            cacheStatusLabel.leadingAnchor.constraint(equalTo: clearCacheButton.trailingAnchor, constant: 12),
            cacheStatusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24)
        ])
    }

    @objc private func autoCrossfadeChanged() {
        EditorPreferences.automaticallyCreateCrossfades = autoCrossfadeCheckbox.state == .on
        statusLabel.stringValue = EditorPreferences.automaticallyCreateCrossfades ? "Automatic crossfades enabled." : "Automatic crossfades disabled."
        statusLabel.textColor = .secondaryLabelColor
    }

    @objc private func clearApplicationCache() {
        let alert = NSAlert()
        alert.messageText = "Clear App Cache?"
        alert.informativeText = "Cached waveforms, video audio proxies, and recovery snapshots will be removed. Your .liau projects, current open project, original audio/video files, and preferences will not be changed."
        alert.addButton(withTitle: "Clear Cache")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            self.clearCacheButton.isEnabled = false
            self.cacheStatusLabel.stringValue = "Clearing..."
            self.cacheStatusLabel.textColor = .secondaryLabelColor
            self.onClearApplicationCaches { [weak self] result in
                guard let self = self else { return }
                self.clearCacheButton.isEnabled = true
                switch result {
                case .success(let cleared):
                    self.cacheStatusLabel.stringValue = cleared.summary
                    self.cacheStatusLabel.textColor = .secondaryLabelColor
                case .failure(let error):
                    self.cacheStatusLabel.stringValue = error.localizedDescription
                    self.cacheStatusLabel.textColor = .systemRed
                }
            }
        }
    }
}

enum EditorPreferences {
    private static let automaticCrossfadesKey = "LightAudio.AutomaticCrossfades"

    static var automaticallyCreateCrossfades: Bool {
        get { UserDefaults.standard.bool(forKey: automaticCrossfadesKey) }
        set { UserDefaults.standard.set(newValue, forKey: automaticCrossfadesKey) }
    }
}
