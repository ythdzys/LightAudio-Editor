import AppKit

final class PreferencesWindowController: NSWindowController {
    private let statusLabel = NSTextField(labelWithString: "")
    private let languageLabel = NSTextField(labelWithString: L10n.tr("Language:"))
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let languageHintLabel = NSTextField(labelWithString: L10n.tr("Language changes take effect after restart."))
    private let autoCrossfadeCheckbox = NSButton(checkboxWithTitle: L10n.tr("Automatically create crossfades when clips overlap"), target: nil, action: nil)
    private let cacheStatusLabel = NSTextField(labelWithString: "")
    private let clearCacheButton = NSButton(title: L10n.tr("Clear App Cache"), target: nil, action: nil)
    private let onClearApplicationCaches: (@escaping (Result<ApplicationCacheClearResult, Error>) -> Void) -> Void

    init(onClearApplicationCaches: @escaping (@escaping (Result<ApplicationCacheClearResult, Error>) -> Void) -> Void) {
        self.onClearApplicationCaches = onClearApplicationCaches
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 280), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.tr("Preferences")
        super.init(window: window)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        guard let content = window?.contentView else { return }
        languagePopup.addItems(withTitles: [
            L10n.tr("System Default"),
            L10n.tr("English"),
            L10n.tr("Simplified Chinese")
        ])
        languagePopup.selectItem(at: AppLanguage.allCases.firstIndex(of: AppLanguage.preferred) ?? 0)
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languageHintLabel.textColor = .secondaryLabelColor
        languageHintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        autoCrossfadeCheckbox.state = EditorPreferences.automaticallyCreateCrossfades ? .on : .off
        autoCrossfadeCheckbox.target = self
        autoCrossfadeCheckbox.action = #selector(autoCrossfadeChanged)
        clearCacheButton.target = self
        clearCacheButton.action = #selector(clearApplicationCache)
        cacheStatusLabel.textColor = .secondaryLabelColor

        [languageLabel, languagePopup, languageHintLabel, autoCrossfadeCheckbox, statusLabel, clearCacheButton, cacheStatusLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }

        NSLayoutConstraint.activate([
            languageLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            languageLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            languageLabel.centerYAnchor.constraint(equalTo: languagePopup.centerYAnchor),
            languagePopup.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            languagePopup.leadingAnchor.constraint(equalTo: languageLabel.trailingAnchor, constant: 12),
            languagePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            languageHintLabel.topAnchor.constraint(equalTo: languagePopup.bottomAnchor, constant: 4),
            languageHintLabel.leadingAnchor.constraint(equalTo: languagePopup.leadingAnchor),
            languageHintLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            autoCrossfadeCheckbox.topAnchor.constraint(equalTo: languageHintLabel.bottomAnchor, constant: 24),
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

    @objc private func languageChanged() {
        let index = languagePopup.indexOfSelectedItem
        guard AppLanguage.allCases.indices.contains(index) else { return }
        let selectedLanguage = AppLanguage.allCases[index]
        guard selectedLanguage != AppLanguage.preferred else { return }
        AppLanguage.preferred = selectedLanguage

        let alert = NSAlert()
        alert.messageText = L10n.tr("Restart Required")
        alert.informativeText = L10n.tr("The language will change after LightAudio Editor restarts.")
        alert.addButton(withTitle: L10n.tr("Quit Now"))
        alert.addButton(withTitle: L10n.tr("Later"))
        alert.beginSheetModal(for: window!) { response in
            if response == .alertFirstButtonReturn {
                NSApp.terminate(self)
            }
        }
    }

    @objc private func autoCrossfadeChanged() {
        EditorPreferences.automaticallyCreateCrossfades = autoCrossfadeCheckbox.state == .on
        statusLabel.stringValue = EditorPreferences.automaticallyCreateCrossfades ? L10n.tr("Automatic crossfades enabled.") : L10n.tr("Automatic crossfades disabled.")
        statusLabel.textColor = .secondaryLabelColor
    }

    @objc private func clearApplicationCache() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Clear App Cache?")
        alert.informativeText = L10n.tr("Cached waveforms, video audio proxies, and recovery snapshots will be removed. Your .liau projects, current open project, original audio/video files, and preferences will not be changed.")
        alert.addButton(withTitle: L10n.tr("Clear Cache"))
        alert.addButton(withTitle: L10n.tr("Cancel"))
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            self.clearCacheButton.isEnabled = false
            self.cacheStatusLabel.stringValue = L10n.tr("Clearing...")
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
