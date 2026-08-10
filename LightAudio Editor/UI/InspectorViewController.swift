import AppKit

final class InspectorViewController: NSViewController {
    var onGainChanged: ((Double) -> Void)?
    var onPanChanged: ((Double) -> Void)?
    var onFadeInChanged: ((Double) -> Void)?
    var onFadeOutChanged: ((Double) -> Void)?
    var onFadeInCurveChanged: ((FadeCurve) -> Void)?
    var onFadeOutCurveChanged: ((FadeCurve) -> Void)?
    var onNameChanged: ((String?) -> Void)?
    var onColorChanged: ((ClipColorLabel) -> Void)?
    var onAddVolumeKeyframe: (() -> Void)?
    var onClearVolumeAutomation: (() -> Void)?
    var onNormalizeClip: (() -> Void)?
    var onBeginContinuousEdit: ((String) -> Void)?
    var onEndContinuousEdit: (() -> Void)?

    private enum SelectionMode {
        case none
        case single
        case multiple
    }

    private let rowsStack = NSStackView()
    private let summarySection = InspectorSectionView(title: "Selection Summary")
    private let identitySection = InspectorSectionView(title: "Identity")
    private let levelPanSection = InspectorSectionView(title: "Level & Pan")
    private let fadesSection = InspectorSectionView(title: "Fades")
    private let automationSection = InspectorSectionView(title: "Automation")
    private let processingSection = InspectorSectionView(title: "Processing")
    private let automationButtons = NSStackView()

    private let titleLabel = NSTextField(labelWithString: "No clip selected")
    private let summaryDetailLabel = NSTextField(labelWithString: "Select a clip to edit its settings.")
    private let nameField = NSTextField(string: "")
    private let colorPopup = NSPopUpButton()
    private let automationSummaryLabel = NSTextField(labelWithString: "Volume keyframes: 0")
    private let addKeyframeButton = NSButton(title: "Add keyframe", target: nil, action: nil)
    private let clearAutomationButton = NSButton(title: "Clear automation", target: nil, action: nil)
    private let normalizeButton = NSButton(title: "Normalize Clip...", target: nil, action: nil)
    private let gainSlider = ContinuousSlider(value: 0, minValue: -60, maxValue: 12, target: nil, action: nil)
    private let panSlider = ContinuousSlider(value: 0, minValue: -100, maxValue: 100, target: nil, action: nil)
    private let fadeInSlider = ContinuousSlider(value: 0, minValue: 0, maxValue: 10, target: nil, action: nil)
    private let fadeOutSlider = ContinuousSlider(value: 0, minValue: 0, maxValue: 10, target: nil, action: nil)
    private let fadeInCurvePopup = NSPopUpButton()
    private let fadeOutCurvePopup = NSPopUpButton()
    private let gainField = NSTextField(string: "0")
    private let panField = NSTextField(string: "0")
    private let fadeInField = NSTextField(string: "0.00")
    private let fadeOutField = NSTextField(string: "0.00")

    private lazy var nameRow = textRow(title: "Name", field: nameField)
    private lazy var colorRow = popupRow(title: "Color", popup: colorPopup)
    private lazy var gainRow = controlRow(title: "Clip dB", slider: gainSlider, field: gainField)
    private lazy var panRow = controlRow(title: "Pan", slider: panSlider, field: panField)
    private lazy var fadeInRow = controlRow(title: "Fade In", slider: fadeInSlider, field: fadeInField)
    private lazy var fadeInCurveRow = popupRow(title: "In Curve", popup: fadeInCurvePopup)
    private lazy var fadeOutRow = controlRow(title: "Fade Out", slider: fadeOutSlider, field: fadeOutField)
    private lazy var fadeOutCurveRow = popupRow(title: "Out Curve", popup: fadeOutCurvePopup)

    private var isUpdatingControls = false
    private var selectionMode: SelectionMode = .none
    private var currentColumnCount = 0
    private var needsSectionRebuild = true

    override func loadView() {
        let container = NSView()

        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = 10

        container.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            rowsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            rowsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            rowsStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -10)
        ])

        configureControls()
        configureSections()
        view = container
        rebuildSectionRows(force: true)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        rebuildSectionRows(force: false)
    }

    private func configureControls() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        summaryDetailLabel.font = .systemFont(ofSize: 11)
        summaryDetailLabel.textColor = .secondaryLabelColor
        summaryDetailLabel.alignment = .left
        summaryDetailLabel.lineBreakMode = .byWordWrapping
        summaryDetailLabel.maximumNumberOfLines = 2

        gainSlider.target = self
        gainSlider.action = #selector(gainChanged)
        panSlider.target = self
        panSlider.action = #selector(panChanged)
        fadeInSlider.target = self
        fadeInSlider.action = #selector(fadeInChanged)
        fadeOutSlider.target = self
        fadeOutSlider.action = #selector(fadeOutChanged)
        gainSlider.onBeginContinuousChange = { [weak self] in self?.onBeginContinuousEdit?("Clip Gain") }
        panSlider.onBeginContinuousChange = { [weak self] in self?.onBeginContinuousEdit?("Clip Pan") }
        fadeInSlider.onBeginContinuousChange = { [weak self] in self?.onBeginContinuousEdit?("Fade In") }
        fadeOutSlider.onBeginContinuousChange = { [weak self] in self?.onBeginContinuousEdit?("Fade Out") }
        [gainSlider, panSlider, fadeInSlider, fadeOutSlider].forEach { slider in
            slider.onEndContinuousChange = { [weak self] in self?.onEndContinuousEdit?() }
        }

        FadeCurve.allCases.forEach {
            fadeInCurvePopup.addItem(withTitle: $0.displayName)
            fadeOutCurvePopup.addItem(withTitle: $0.displayName)
        }
        fadeInCurvePopup.target = self
        fadeInCurvePopup.action = #selector(fadeInCurveChanged)
        fadeOutCurvePopup.target = self
        fadeOutCurvePopup.action = #selector(fadeOutCurveChanged)

        configureValueField(gainField, action: #selector(gainFieldChanged))
        configureValueField(panField, action: #selector(panFieldChanged))
        configureValueField(fadeInField, action: #selector(fadeInFieldChanged))
        configureValueField(fadeOutField, action: #selector(fadeOutFieldChanged))

        nameField.target = self
        nameField.action = #selector(nameFieldChanged)
        nameField.placeholderString = "Clip name"
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        ClipColorLabel.allCases.forEach { colorPopup.addItem(withTitle: $0.displayName) }
        colorPopup.target = self
        colorPopup.action = #selector(colorChanged)

        automationSummaryLabel.textColor = .secondaryLabelColor
        automationSummaryLabel.font = .systemFont(ofSize: 11)
        automationSummaryLabel.lineBreakMode = .byTruncatingTail

        addKeyframeButton.bezelStyle = .rounded
        clearAutomationButton.bezelStyle = .rounded
        normalizeButton.bezelStyle = .rounded
        addKeyframeButton.target = self
        addKeyframeButton.action = #selector(addVolumeKeyframe)
        clearAutomationButton.target = self
        clearAutomationButton.action = #selector(clearVolumeAutomation)
        normalizeButton.target = self
        normalizeButton.action = #selector(normalizeClip)
    }

    private func configureSections() {
        [summarySection, identitySection, levelPanSection, fadesSection, automationSection, processingSection].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            $0.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        automationButtons.orientation = .horizontal
        automationButtons.alignment = .centerY
        automationButtons.spacing = 8
        automationButtons.addArrangedSubview(addKeyframeButton)
        automationButtons.addArrangedSubview(clearAutomationButton)

        summarySection.contentStack.addArrangedSubview(titleLabel)
        summarySection.contentStack.addArrangedSubview(summaryDetailLabel)
        identitySection.contentStack.addArrangedSubview(nameRow)
        identitySection.contentStack.addArrangedSubview(colorRow)
        levelPanSection.contentStack.addArrangedSubview(gainRow)
        levelPanSection.contentStack.addArrangedSubview(panRow)
        fadesSection.contentStack.addArrangedSubview(fadeInRow)
        fadesSection.contentStack.addArrangedSubview(fadeInCurveRow)
        fadesSection.contentStack.addArrangedSubview(fadeOutRow)
        fadesSection.contentStack.addArrangedSubview(fadeOutCurveRow)
        automationSection.contentStack.addArrangedSubview(automationSummaryLabel)
        automationSection.contentStack.addArrangedSubview(automationButtons)
        processingSection.contentStack.addArrangedSubview(normalizeButton)
    }

    private func rebuildSectionRows(force: Bool) {
        let columns = sectionColumnCount(for: view.bounds.width)
        guard force || needsSectionRebuild || columns != currentColumnCount else { return }
        currentColumnCount = columns
        needsSectionRebuild = false

        clearRows()
        let sections = activeSections()
        guard !sections.isEmpty else { return }

        var index = 0
        while index < sections.count {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true

            let end = min(index + columns, sections.count)
            for section in sections[index..<end] {
                row.addArrangedSubview(section)
            }

            let placeholdersNeeded = columns - (end - index)
            if placeholdersNeeded > 0, rowsStack.arrangedSubviews.count > 1 {
                for _ in 0..<placeholdersNeeded {
                    let spacer = NSView()
                    spacer.translatesAutoresizingMaskIntoConstraints = false
                    row.addArrangedSubview(spacer)
                }
            }
            index = end
        }
    }

    private func sectionColumnCount(for width: CGFloat) -> Int {
        let usableWidth = max(1, width - 24)
        let minimumChunkWidth: CGFloat = 280
        let spacing: CGFloat = 10
        let columns = Int((usableWidth + spacing) / (minimumChunkWidth + spacing))
        return max(1, min(4, columns))
    }

    private func activeSections() -> [InspectorSectionView] {
        switch selectionMode {
        case .none:
            return [summarySection]
        case .single:
            return [identitySection, levelPanSection, fadesSection, automationSection, processingSection]
        case .multiple:
            return [summarySection, levelPanSection, fadesSection]
        }
    }

    private func clearRows() {
        for row in rowsStack.arrangedSubviews {
            if let stack = row as? NSStackView {
                removeAllArrangedSubviews(from: stack)
            }
            rowsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
    }

    private func removeAllArrangedSubviews(from stack: NSStackView) {
        for subview in stack.arrangedSubviews {
            stack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
    }

    private func controlRow(title: String, slider: NSSlider, field: NSTextField) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.translatesAutoresizingMaskIntoConstraints = false
        let label = rowLabel(title)
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        row.addArrangedSubview(label)
        row.addArrangedSubview(slider)
        row.addArrangedSubview(field)
        return row
    }

    private func textRow(title: String, field: NSTextField) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.translatesAutoresizingMaskIntoConstraints = false
        let label = rowLabel(title)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        row.addArrangedSubview(label)
        row.addArrangedSubview(field)
        return row
    }

    private func popupRow(title: String, popup: NSPopUpButton) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.translatesAutoresizingMaskIntoConstraints = false
        let label = rowLabel(title)
        popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(label)
        row.addArrangedSubview(popup)
        return row
    }

    private func rowLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 64).isActive = true
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }

    private func configureValueField(_ field: NSTextField, action: Selector) {
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.target = self
        field.action = action
        field.formatter = DecimalNumberFormatter()
    }

    func update(project: Project, selectedClipIDs: Set<UUID>) {
        let editingIsBlocked = project.hasMissingAssets
        guard !selectedClipIDs.isEmpty else {
            selectionMode = .none
            titleLabel.stringValue = editingIsBlocked ? "Editing unavailable" : "No clip selected"
            summaryDetailLabel.stringValue = editingIsBlocked ? "Relink missing media before editing." : "Select a clip to edit its settings."
            automationSummaryLabel.stringValue = "Volume keyframes: 0"
            setControlsEnabled(false)
            setAutomationButtonsEnabled(false)
            markSectionsForRebuild()
            return
        }
        if selectedClipIDs.count > 1 {
            selectionMode = .multiple
            titleLabel.stringValue = "\(selectedClipIDs.count) clips selected"
            summaryDetailLabel.stringValue = editingIsBlocked ? "Relink missing media before editing." : "Batch editing is available for level, pan, and fades."
            automationSummaryLabel.stringValue = "Volume automation: select one clip"
            isUpdatingControls = true
            nameField.stringValue = ""
            colorPopup.selectItem(at: 0)
            gainSlider.doubleValue = 0
            panSlider.doubleValue = 0
            fadeInSlider.doubleValue = 0
            fadeOutSlider.doubleValue = 0
            fadeInCurvePopup.selectItem(at: 0)
            fadeOutCurvePopup.selectItem(at: 0)
            updateField(gainField, value: gainSlider.doubleValue)
            updateField(panField, value: panSlider.doubleValue)
            updateField(fadeInField, value: fadeInSlider.doubleValue)
            updateField(fadeOutField, value: fadeOutSlider.doubleValue)
            setControlsEnabled(!editingIsBlocked)
            setAutomationButtonsEnabled(false)
            isUpdatingControls = false
            markSectionsForRebuild()
            return
        }
        guard let id = selectedClipIDs.first else { return }
        for track in project.timeline.tracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                selectionMode = .single
                isUpdatingControls = true
                titleLabel.stringValue = "Selected Clip"
                summaryDetailLabel.stringValue = editingIsBlocked ? "Relink missing media before editing." : "Editing one timeline clip."
                nameField.stringValue = clip.customName ?? ""
                colorPopup.selectItem(at: ClipColorLabel.allCases.firstIndex(of: clip.colorLabel) ?? 0)
                automationSummaryLabel.stringValue = "Volume keyframes: \(clip.volumeAutomationKeyframes.count)"
                gainSlider.doubleValue = MixMath.db(forLinearGain: clip.gain)
                panSlider.doubleValue = clip.pan * 100
                fadeInSlider.maxValue = max(0.1, min(10, clip.duration))
                fadeOutSlider.maxValue = max(0.1, min(10, clip.duration))
                fadeInSlider.doubleValue = clip.fadeIn.duration
                fadeOutSlider.doubleValue = clip.fadeOut.duration
                fadeInCurvePopup.selectItem(at: FadeCurve.allCases.firstIndex(of: clip.fadeIn.curve) ?? 0)
                fadeOutCurvePopup.selectItem(at: FadeCurve.allCases.firstIndex(of: clip.fadeOut.curve) ?? 0)
                updateField(gainField, value: gainSlider.doubleValue)
                updateField(panField, value: panSlider.doubleValue)
                updateField(fadeInField, value: clip.fadeIn.duration)
                updateField(fadeOutField, value: clip.fadeOut.duration)
                setControlsEnabled(!editingIsBlocked)
                setAutomationButtonsEnabled(!editingIsBlocked)
                isUpdatingControls = false
                markSectionsForRebuild()
                return
            }
        }
        selectionMode = .none
        titleLabel.stringValue = editingIsBlocked ? "Editing unavailable" : "No clip selected"
        summaryDetailLabel.stringValue = editingIsBlocked ? "Relink missing media before editing." : "Select a clip to edit its settings."
        setControlsEnabled(false)
        setAutomationButtonsEnabled(false)
        markSectionsForRebuild()
    }

    func update(project: Project, selectedClipID: UUID?) {
        update(project: project, selectedClipIDs: selectedClipID.map { [$0] } ?? [])
    }

    private func markSectionsForRebuild() {
        needsSectionRebuild = true
        rebuildSectionRows(force: true)
    }

    @objc private func gainChanged() {
        guard !isUpdatingControls else { return }
        updateField(gainField, value: gainSlider.doubleValue)
        onGainChanged?(MixMath.linearGain(forDB: gainSlider.doubleValue))
    }

    @objc private func panChanged() {
        guard !isUpdatingControls else { return }
        updateField(panField, value: panSlider.doubleValue)
        onPanChanged?(panSlider.doubleValue / 100)
    }

    @objc private func fadeInChanged() {
        guard !isUpdatingControls else { return }
        updateField(fadeInField, value: fadeInSlider.doubleValue)
        onFadeInChanged?(fadeInSlider.doubleValue)
    }

    @objc private func fadeOutChanged() {
        guard !isUpdatingControls else { return }
        updateField(fadeOutField, value: fadeOutSlider.doubleValue)
        onFadeOutChanged?(fadeOutSlider.doubleValue)
    }

    @objc private func fadeInCurveChanged() {
        guard !isUpdatingControls else { return }
        let index = max(0, min(FadeCurve.allCases.count - 1, fadeInCurvePopup.indexOfSelectedItem))
        onFadeInCurveChanged?(FadeCurve.allCases[index])
    }

    @objc private func fadeOutCurveChanged() {
        guard !isUpdatingControls else { return }
        let index = max(0, min(FadeCurve.allCases.count - 1, fadeOutCurvePopup.indexOfSelectedItem))
        onFadeOutCurveChanged?(FadeCurve.allCases[index])
    }

    @objc private func nameFieldChanged() {
        guard !isUpdatingControls else { return }
        let clean = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onNameChanged?(clean.isEmpty ? nil : clean)
    }

    @objc private func colorChanged() {
        guard !isUpdatingControls else { return }
        let index = max(0, min(ClipColorLabel.allCases.count - 1, colorPopup.indexOfSelectedItem))
        onColorChanged?(ClipColorLabel.allCases[index])
    }

    @objc private func addVolumeKeyframe() {
        onAddVolumeKeyframe?()
    }

    @objc private func clearVolumeAutomation() {
        onClearVolumeAutomation?()
    }

    @objc private func normalizeClip() {
        onNormalizeClip?()
    }

    @objc private func gainFieldChanged() {
        let value = min(max(-60, gainField.doubleValue), 12)
        gainSlider.doubleValue = value
        updateField(gainField, value: value)
        onGainChanged?(MixMath.linearGain(forDB: value))
    }

    @objc private func panFieldChanged() {
        let value = min(max(-100, panField.doubleValue), 100)
        panSlider.doubleValue = value
        updateField(panField, value: value)
        onPanChanged?(value / 100)
    }

    @objc private func fadeInFieldChanged() {
        let value = min(max(0, fadeInField.doubleValue), fadeInSlider.maxValue)
        fadeInSlider.doubleValue = value
        updateField(fadeInField, value: value)
        onFadeInChanged?(value)
    }

    @objc private func fadeOutFieldChanged() {
        let value = min(max(0, fadeOutField.doubleValue), fadeOutSlider.maxValue)
        fadeOutSlider.doubleValue = value
        updateField(fadeOutField, value: value)
        onFadeOutChanged?(value)
    }

    private func updateField(_ field: NSTextField, value: Double) {
        field.stringValue = String(format: "%.2f", value)
    }

    private func setControlsEnabled(_ enabled: Bool) {
        [gainSlider, panSlider, fadeInSlider, fadeOutSlider, gainField, panField, fadeInField, fadeOutField, nameField, colorPopup, fadeInCurvePopup, fadeOutCurvePopup].forEach { $0.isEnabled = enabled }
    }

    private func setAutomationButtonsEnabled(_ enabled: Bool) {
        [addKeyframeButton, clearAutomationButton, normalizeButton].forEach { $0.isEnabled = enabled }
    }
}

private final class InspectorSectionView: NSView {
    let contentStack = NSStackView()

    private let titleLabel: NSTextField

    init(title: String) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 0.86).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .width
        contentStack.spacing = 7

        addSubview(titleLabel)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            contentStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class ContinuousSlider: NSSlider {
    var onBeginContinuousChange: (() -> Void)?
    var onEndContinuousChange: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBeginContinuousChange?()
        super.mouseDown(with: event)
        onEndContinuousChange?()
    }
}

final class DecimalNumberFormatter: NumberFormatter, @unchecked Sendable {
    override init() {
        super.init()
        numberStyle = .decimal
        minimumFractionDigits = 0
        maximumFractionDigits = 2
        allowsFloats = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func isPartialStringValid(_ partialString: String, newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?, errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        if partialString.isEmpty { return true }
        return Double(partialString) != nil
    }
}
