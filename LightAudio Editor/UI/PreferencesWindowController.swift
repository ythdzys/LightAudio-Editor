import AppKit

final class PreferencesWindowController: NSWindowController {
    private let pathField = NSTextField(string: ExternalEncoderSettings.ffmpegPath ?? "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let autoCrossfadeCheckbox = NSButton(checkboxWithTitle: "Automatically create crossfades when clips overlap", target: nil, action: nil)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
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
        let test = NSButton(title: "Test FFmpeg", target: self, action: #selector(testFFmpeg))
        pathField.placeholderString = "/opt/homebrew/bin/ffmpeg"
        autoCrossfadeCheckbox.state = EditorPreferences.automaticallyCreateCrossfades ? .on : .off
        autoCrossfadeCheckbox.target = self
        autoCrossfadeCheckbox.action = #selector(autoCrossfadeChanged)

        [label, pathField, browse, test, statusLabel, autoCrossfadeCheckbox].forEach {
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
            test.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 20),
            test.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: test.bottomAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            autoCrossfadeCheckbox.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 22),
            autoCrossfadeCheckbox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            autoCrossfadeCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20)
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
        guard let version = ExternalEncoderSettings.ffmpegVersion(path: path) else {
            statusLabel.stringValue = "FFmpeg not available at this path."
            statusLabel.textColor = .systemRed
            return
        }
        statusLabel.stringValue = version
        statusLabel.textColor = .secondaryLabelColor
    }

    @objc private func autoCrossfadeChanged() {
        EditorPreferences.automaticallyCreateCrossfades = autoCrossfadeCheckbox.state == .on
        statusLabel.stringValue = EditorPreferences.automaticallyCreateCrossfades ? "Automatic crossfades enabled." : "Automatic crossfades disabled."
        statusLabel.textColor = .secondaryLabelColor
    }
}

enum EditorPreferences {
    private static let automaticCrossfadesKey = "LightAudio.AutomaticCrossfades"

    static var automaticallyCreateCrossfades: Bool {
        get { UserDefaults.standard.bool(forKey: automaticCrossfadesKey) }
        set { UserDefaults.standard.set(newValue, forKey: automaticCrossfadesKey) }
    }
}
