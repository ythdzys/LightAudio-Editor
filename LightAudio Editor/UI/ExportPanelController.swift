import AppKit

final class ExportPanelController: NSWindowController {
    private static var active: ExportPanelController?

    private let project: Project
    private let completion: (ExportSettings) -> Void
    private let formatPopup = NSPopUpButton()
    private let rangePopup = NSPopUpButton()
    private let sampleRatePopup = NSPopUpButton()
    private let channelsPopup = NSPopUpButton()
    private let bitratePopup = NSPopUpButton()
    private let outputField = NSTextField(labelWithString: "")
    private let availabilityLabel = NSTextField(labelWithString: "")
    private let exportButton = NSButton(title: "Export", target: nil, action: nil)
    private var outputURL: URL?
    private var availabilityRequestID = UUID()

    static func show(window: NSWindow?, project: Project, completion: @escaping (ExportSettings) -> Void) {
        let controller = ExportPanelController(project: project, completion: completion)
        active = controller
        window?.beginSheet(controller.window!) { _ in
            active = nil
        }
    }

    private init(project: Project, completion: @escaping (ExportSettings) -> Void) {
        self.project = project
        self.completion = completion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 330), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Export Audio"
        super.init(window: window)
        setup()
        updateForFormat()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        guard let content = window?.contentView else { return }
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        content.addSubview(grid)

        ExportFormat.allCases.forEach { formatPopup.addItem(withTitle: $0.rawValue) }
        rangePopup.addItems(withTitles: ["Entire Project", "In/Out Range"])
        if project.viewState.validRange == nil {
            rangePopup.item(at: 1)?.isEnabled = false
        }
        sampleRatePopup.addItems(withTitles: ["Project default", "44100", "48000", "96000"])
        channelsPopup.addItems(withTitles: ["Project default", "Mono", "Stereo"])
        bitratePopup.addItems(withTitles: ["128 kbps", "192 kbps", "256 kbps", "320 kbps"])
        bitratePopup.selectItem(withTitle: "256 kbps")
        outputURL = defaultOutputURL(for: .wav)
        outputField.stringValue = outputURL?.path ?? ""

        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
        let browse = NSButton(title: "Browse...", target: self, action: #selector(browseOutput))

        addRow(to: grid, label: "Format", view: formatPopup)
        addRow(to: grid, label: "Range", view: rangePopup)
        addRow(to: grid, label: "Sample rate", view: sampleRatePopup)
        addRow(to: grid, label: "Channels", view: channelsPopup)
        addRow(to: grid, label: "Bitrate", view: bitratePopup)
        addRow(to: grid, label: "Output", view: outputField, trailing: browse)
        addRow(to: grid, label: "Availability", view: availabilityLabel)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        exportButton.target = self
        exportButton.action = #selector(export)
        [cancel, exportButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            cancel.trailingAnchor.constraint(equalTo: exportButton.leadingAnchor, constant: -10),
            cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            exportButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            exportButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
    }

    private func addRow(to grid: NSGridView, label: String, view: NSView, trailing: NSView? = nil) {
        let labelView = NSTextField(labelWithString: label)
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        if let trailing = trailing {
            trailing.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(trailing)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                view.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -8),
                trailing.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                trailing.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            ])
        }
        grid.addRow(with: [labelView, container])
    }

    @objc private func formatChanged() {
        let selected = selectedFormat()
        outputURL = replacingExtension(of: outputURL ?? defaultOutputURL(for: selected), format: selected)
        outputField.stringValue = outputURL?.path ?? ""
        updateForFormat()
    }

    private func updateForFormat() {
        let format = selectedFormat()
        let compressed = format == .m4a || format == .mp3
        bitratePopup.isHidden = !compressed

        let requestID = UUID()
        availabilityRequestID = requestID
        switch format {
        case .wav, .aiff:
            applyAvailability(ExternalEncoderExportBackend.availability(for: format))
        case .m4a, .mp3, .flac:
            availabilityLabel.stringValue = "Checking FFmpeg..."
            availabilityLabel.textColor = .secondaryLabelColor
            exportButton.isEnabled = false
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let availability = ExternalEncoderExportBackend.availability(for: format)
                DispatchQueue.main.async {
                    guard let self,
                          self.availabilityRequestID == requestID,
                          self.selectedFormat() == format else {
                        return
                    }
                    self.applyAvailability(availability)
                }
            }
        }
    }

    private func applyAvailability(_ availability: (available: Bool, reason: String?)) {
        exportButton.isEnabled = availability.available && outputURL != nil
        availabilityLabel.stringValue = availability.reason ?? "Available"
        availabilityLabel.textColor = availability.available ? .secondaryLabelColor : .systemRed
    }

    @objc private func browseOutput() {
        let format = selectedFormat()
        let panel = NSSavePanel()
        panel.allowedFileTypes = [fileExtension(for: format)]
        panel.nameFieldStringValue = "\(project.name).\(fileExtension(for: format))"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.outputURL = url
            self?.outputField.stringValue = url.path
            self?.updateForFormat()
        }
    }

    @objc private func cancel() {
        guard let window = window else { return }
        window.sheetParent?.endSheet(window)
    }

    @objc private func export() {
        guard let outputURL = outputURL else { return }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            confirmOverwrite(of: outputURL)
            return
        }
        finishExport(to: outputURL, overwritingExisting: false)
    }

    private func confirmOverwrite(of outputURL: URL) {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace existing export?"
        alert.informativeText = "\(outputURL.lastPathComponent) already exists. Replacing it cannot be undone."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.finishExport(to: outputURL, overwritingExisting: true)
        }
    }

    private func finishExport(to outputURL: URL, overwritingExisting: Bool) {
        let settings = ExportSettings(
            format: selectedFormat(),
            sampleRate: selectedSampleRate(),
            channelCount: selectedChannelCount(),
            bitrate: selectedBitrate(),
            outputURL: outputURL,
            range: selectedRange(),
            overwriteExisting: overwritingExisting
        )
        guard let window = window else { return }
        window.sheetParent?.endSheet(window)
        completion(settings)
    }

    private func selectedFormat() -> ExportFormat {
        ExportFormat.allCases[formatPopup.indexOfSelectedItem]
    }

    private func selectedSampleRate() -> Double {
        switch sampleRatePopup.indexOfSelectedItem {
        case 1: return 44100
        case 2: return 48000
        case 3: return 96000
        default: return project.sampleRate
        }
    }

    private func selectedChannelCount() -> Int {
        switch channelsPopup.indexOfSelectedItem {
        case 1: return 1
        case 2: return 2
        default: return 2
        }
    }

    private func selectedBitrate() -> Int? {
        guard selectedFormat() == .m4a || selectedFormat() == .mp3 else { return nil }
        return [128, 192, 256, 320][max(0, bitratePopup.indexOfSelectedItem)]
    }

    private func selectedRange() -> ExportRange {
        guard rangePopup.indexOfSelectedItem == 1, let range = project.viewState.validRange else {
            return .entireProject
        }
        return .timeRange(start: range.start, end: range.end)
    }

    private func defaultOutputURL(for format: ExportFormat) -> URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
            .appendingPathComponent("\(project.name).\(fileExtension(for: format))")
    }

    private func replacingExtension(of url: URL, format: ExportFormat) -> URL {
        url.deletingPathExtension().appendingPathExtension(fileExtension(for: format))
    }

    private func fileExtension(for format: ExportFormat) -> String {
        switch format {
        case .wav: return "wav"
        case .aiff: return "aiff"
        case .m4a: return "m4a"
        case .mp3: return "mp3"
        case .flac: return "flac"
        }
    }
}
