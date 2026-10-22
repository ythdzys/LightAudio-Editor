import AppKit

final class PreferencesWindowController: NSWindowController {
    var onAutosavePreferenceChanged: (() -> Void)?
    private let cacheService: ApplicationCacheService
    private let appearanceControl = NSSegmentedControl(
        labels: [L10n.tr("System Default"), L10n.tr("Light"), L10n.tr("Dark")],
        trackingMode: .selectOne, target: nil, action: nil
    )
    private let autosaveCheckbox = NSButton(checkboxWithTitle: L10n.tr("Automatically save changes to saved projects"), target: nil, action: nil)
    private let cacheUsageLabel = NSTextField(wrappingLabelWithString: "")
    private let refreshCacheButton = NSButton(title: L10n.tr("Refresh Cache Usage"), target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let languageLabel = NSTextField(labelWithString: L10n.tr("Language:"))
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let languageHintLabel = NSTextField(labelWithString: L10n.tr("Language changes take effect after restart."))
    private let autoCrossfadeCheckbox = NSButton(checkboxWithTitle: L10n.tr("Automatically create crossfades when clips overlap"), target: nil, action: nil)
    private let cacheStatusLabel = NSTextField(labelWithString: "")
    private let clearCacheButton = NSButton(title: L10n.tr("Clear App Cache"), target: nil, action: nil)
    private let onClearApplicationCaches: (@escaping (Result<ApplicationCacheClearResult, Error>) -> Void) -> Void

    init(cacheService: ApplicationCacheService = ApplicationCacheService(), onClearApplicationCaches: @escaping (@escaping (Result<ApplicationCacheClearResult, Error>) -> Void) -> Void) {
        self.cacheService = cacheService
        self.onClearApplicationCaches = onClearApplicationCaches
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
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

        appearanceControl.identifier = NSUserInterfaceItemIdentifier("editorAppearance")
        appearanceControl.setAccessibilityLabel(L10n.tr("Appearance:"))
        appearanceControl.selectedSegment = EditorAppearance.allCases.firstIndex(of: .preferred) ?? 0
        appearanceControl.target = self
        appearanceControl.action = #selector(appearanceChanged)
        autosaveCheckbox.state = EditorPreferences.automaticallySaveChanges ? .on : .off
        autosaveCheckbox.target = self
        autosaveCheckbox.action = #selector(autosaveChanged)
        refreshCacheButton.target = self
        refreshCacheButton.action = #selector(refreshCacheUsage)
        cacheUsageLabel.textColor = .secondaryLabelColor

        let languageRow = NSStackView(views: [languageLabel, languagePopup])
        let appearanceRow = NSStackView(views: [NSTextField(labelWithString: L10n.tr("Appearance:")), appearanceControl])
        let cacheRow = NSStackView(views: [clearCacheButton, refreshCacheButton])
        let stack = NSStackView(views: [languageRow, languageHintLabel, appearanceRow,
            autoCrossfadeCheckbox, autosaveCheckbox, statusLabel, cacheUsageLabel, cacheRow, cacheStatusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            cacheUsageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        refreshCacheUsage()
    }

    override func showWindow(_ sender: Any?) {
        appearanceControl.selectedSegment = EditorAppearance.allCases.firstIndex(of: .preferred) ?? 0
        super.showWindow(sender)
        refreshCacheUsage()
    }

    @objc private func appearanceChanged() {
        let index = appearanceControl.selectedSegment
        guard EditorAppearance.allCases.indices.contains(index) else { return }
        EditorAppearance.preferred = EditorAppearance.allCases[index]
        EditorAppearance.apply()
    }

    @objc private func autosaveChanged() {
        EditorPreferences.automaticallySaveChanges = autosaveCheckbox.state == .on
        onAutosavePreferenceChanged?()
    }

    @objc private func refreshCacheUsage() {
        refreshCacheButton.isEnabled = false
        cacheService.measureApplicationCaches { [weak self] result in
            guard let self else { return }
            self.refreshCacheButton.isEnabled = true
            switch result {
            case .success(let usage):
                let size: (Int64) -> String = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                self.cacheUsageLabel.stringValue = [
                    L10n.format("Waveforms: %@", size(usage.waveformBytes)),
                    L10n.format("Video audio proxies: %@", size(usage.proxyBytes)),
                    L10n.format("Recovery snapshots: %@", size(usage.recoveryBytes)),
                    L10n.format("Total cache: %@", size(usage.totalBytes))
                ].joined(separator: "\n")
            case .failure(let error):
                self.cacheUsageLabel.stringValue = error.localizedDescription
            }
        }
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
                    self.refreshCacheUsage()
                    self.cacheStatusLabel.textColor = .secondaryLabelColor
                case .failure(let error):
                    self.cacheStatusLabel.stringValue = error.localizedDescription
                    self.cacheStatusLabel.textColor = .systemRed
                }
            }
        }
    }
}
