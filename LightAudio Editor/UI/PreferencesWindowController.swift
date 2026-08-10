import AppKit

final class PreferencesWindowController: NSWindowController {
    private let pathField = NSTextField(string: ExternalEncoderSettings.ffmpegPath ?? "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let autoCrossfadeCheckbox = NSButton(checkboxWithTitle: "Automatically create crossfades when clips overlap", target: nil, action: nil)
    private let cacheStatusLabel = NSTextField(labelWithString: "")
    private let clearCacheButton = NSButton(title: "Clear App Cache", target: nil, action: nil)
    private let testButton = NSButton(title: "Test FFmpeg", target: nil, action: nil)
    private let onClearApplicationCaches: (@escaping (Result<ApplicationCacheClearResult, Error>) -> Void) -> Void
    private var encoderTestGeneration = 0

    init(onClearApplicationCaches: @escaping (@escaping (Result<ApplicationCacheClearResult, Error>) -> Void) -> Void) {
        self.onClearApplicationCaches = onClearApplicationCaches
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 330), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Preferences"
        super.init(window: window)
        setup()
        testFFmpeg(nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        guard let content = window?.contentView else { return }
        let label = NSTextField(labelWithString: "FFmpeg binary")
        let browse = NSButton(title: "Browse...", target: self, action: #selector(browse))
        testButton.target = self
        testButton.action = #selector(testFFmpeg)
        pathField.placeholderString = "/opt/homebrew/bin/ffmpeg"
        autoCrossfadeCheckbox.state = EditorPreferences.automaticallyCreateCrossfades ? .on : .off
        autoCrossfadeCheckbox.target = self
        autoCrossfadeCheckbox.action = #selector(autoCrossfadeChanged)
        clearCacheButton.target = self
        clearCacheButton.action = #selector(clearApplicationCache)
        cacheStatusLabel.textColor = .secondaryLabelColor

        [label, pathField, browse, testButton, statusLabel, autoCrossfadeCheckbox, clearCacheButton, cacheStatusLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            pathField.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            pathField.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 16),
            pathField.trailingAnchor.constraint(equalTo: browse.leadingAnchor, constant: -8),
            browse.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            browse.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            testButton.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 20),
            testButton.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: testButton.bottomAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            autoCrossfadeCheckbox.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 22),
            autoCrossfadeCheckbox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            autoCrossfadeCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            clearCacheButton.topAnchor.constraint(equalTo: autoCrossfadeCheckbox.bottomAnchor, constant: 26),
            clearCacheButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            cacheStatusLabel.centerYAnchor.constraint(equalTo: clearCacheButton.centerYAnchor),
            cacheStatusLabel.leadingAnchor.constraint(equalTo: clearCacheButton.trailingAnchor, constant: 12),
            cacheStatusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20)
        ])
    }

    @objc private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.pathField.stringValue = url.path
            ExternalEncoderSettings.ffmpegPath = url.path
            self?.testFFmpeg(nil)
        }
    }

    @objc private func testFFmpeg(_ sender: Any?) {
        let path = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        ExternalEncoderSettings.ffmpegPath = path.isEmpty ? nil : path
        encoderTestGeneration &+= 1
        let generation = encoderTestGeneration
        testButton.isEnabled = false
        statusLabel.stringValue = "Testing FFmpeg..."
        statusLabel.textColor = .secondaryLabelColor
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let version = ExternalEncoderSettings.ffmpegVersion(path: path)
            DispatchQueue.main.async {
                guard let self, self.encoderTestGeneration == generation else { return }
                self.testButton.isEnabled = true
                if let version {
                    self.statusLabel.stringValue = version
                    self.statusLabel.textColor = .secondaryLabelColor
                } else {
                    self.statusLabel.stringValue = "FFmpeg not available at this path."
                    self.statusLabel.textColor = .systemRed
                }
            }
        }
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
