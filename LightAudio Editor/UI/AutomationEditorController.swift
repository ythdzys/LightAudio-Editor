import AppKit

enum AutomationTarget {
    case clipVolume(UUID)
    case clipPan(UUID)
    case trackVolume(UUID)

    var isPan: Bool { if case .clipPan = self { return true }; return false }
    var isClip: Bool { if case .trackVolume = self { return false }; return true }
    var title: String {
        switch self {
        case .clipVolume: return L10n.tr("Clip Volume Automation")
        case .clipPan: return L10n.tr("Clip Pan Automation")
        case .trackVolume: return L10n.tr("Track Volume Automation")
        }
    }
    var range: ClosedRange<Double> { isPan ? -100...100 : -60...12 }
    func track(in project: Project) -> Track? {
        switch self {
        case .clipPan(let id), .clipVolume(let id): return project.timeline.tracks.first { $0.clips.contains { $0.id == id } }
        case .trackVolume(let id): return project.timeline.tracks.first { $0.id == id }
        }
    }
    func clip(in project: Project) -> Clip? {
        switch self {
        case .clipPan(let id), .clipVolume(let id): return track(in: project)?.clips.first { $0.id == id }
        case .trackVolume: return nil
        }
    }
}

struct AutomationPoint {
    let id: UUID
    let time: Double
    let value: Double
}

private final class AutomationPanel: NSPanel {
    override var canBecomeMain: Bool { false }
    override var undoManager: UndoManager? { NSApp.mainWindow?.undoManager }
}

/// A graph and an accessible point list edit the same persisted keyframes.
final class AutomationEditorController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let controller: ProjectController
    private let documentID: UUID
    private let target: AutomationTarget
    private let graph = AutomationGraphView()
    private let table = NSTableView()
    private let timeField = NSTextField(string: "0")
    private let valueField = NSTextField(string: "0")
    private let descriptionLabel = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []
    private var points: [AutomationPoint] = []
    private var selectedID: UUID?
    private var refreshing = false

    init(controller: ProjectController, target: AutomationTarget) {
        self.controller = controller
        documentID = controller.project.id
        self.target = target
        let window = AutomationPanel(contentRect: NSRect(x: 0, y: 0, width: 610, height: 480),
                              styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        window.title = target.title
        super.init(window: window)
        window.delegate = self
        window.minSize = NSSize(width: 570, height: 440)
        setup()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var editable: Bool {
        controller.project.id == documentID && !controller.project.hasMissingAssets &&
        target.track(in: controller.project)?.isLocked == false
    }
    private var duration: Double {
        target.clip(in: controller.project)?.duration ?? max(10, controller.project.duration, points.last?.time ?? 0)
    }

    private func setup() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        graph.identifier = .init("automation.graph")
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        for (id, title, width) in [("time", "Time (seconds)", 260.0), ("value", target.isPan ? "Pan (%)" : "Gain (dB)", 260.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = L10n.tr(title); column.width = width
            table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self
        table.setAccessibilityLabel(target.title)
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        timeField.identifier = .init("automation.time"); valueField.identifier = .init("automation.value")
        timeField.setAccessibilityLabel(L10n.tr("Time (seconds)"))
        valueField.setAccessibilityLabel(L10n.tr(target.isPan ? "Pan (%)" : "Gain (dB)"))
        let fields = NSStackView(views: [NSTextField(labelWithString: L10n.tr("Time (seconds)")), timeField,
                                       NSTextField(labelWithString: L10n.tr(target.isPan ? "Pan (%)" : "Gain (dB)")), valueField])
        fields.spacing = 10
        let actions: [(String, Selector)] = [
            ("Add Point", #selector(addPoint)), ("Update Point", #selector(updatePoint)),
            ("Delete Point", #selector(deletePoint)), ("Clear Automation", #selector(clearPoints))
        ]
        buttons = actions.map { NSButton(title: L10n.tr($0.0), target: self, action: $0.1) }
        let controls = NSStackView(views: buttons); controls.spacing = 8
        [descriptionLabel, graph, scroll, fields, controls].forEach { stack.addArrangedSubview($0) }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            graph.widthAnchor.constraint(equalTo: stack.widthAnchor),
            graph.heightAnchor.constraint(equalToConstant: 190),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            timeField.widthAnchor.constraint(equalToConstant: 100),
            valueField.widthAnchor.constraint(equalToConstant: 100)
        ])
        graph.onSelect = { [weak self] id in self?.selectedID = id; self?.refresh() }
        graph.onEdit = { [weak self] id, time, value in self?.put(id: id, time: time, value: value) }
        graph.onBegin = { [weak self] in self?.controller.beginContinuousEdit(actionName: "Move Automation Point") }
        graph.onEnd = { [weak self] in self?.controller.endContinuousEdit() }
    }

    func refresh() {
        guard controller.project.id == documentID, let track = target.track(in: controller.project) else {
            close(); return
        }
        let clip = target.clip(in: controller.project)
        switch target {
        case .clipPan: points = clip?.panAutomationKeyframes.map { .init(id: $0.id, time: $0.time, value: $0.pan) } ?? []
        case .clipVolume: points = clip?.volumeAutomationKeyframes.map { .init(id: $0.id, time: $0.time, value: $0.gainDB) } ?? []
        case .trackVolume: points = track.volumeAutomationKeyframes.map { .init(id: $0.id, time: $0.time, value: $0.gainDB) }
        }
        descriptionLabel.stringValue = track.name + " — " + L10n.tr(editable ? "Click to add a point; drag to move it." : "Unlock the track and finish media preparation to edit.")
        refreshing = true
        table.reloadData()
        if let index = points.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            if window?.firstResponder !== timeField.currentEditor() { timeField.stringValue = String(format: "%.6f", points[index].time) }
            if window?.firstResponder !== valueField.currentEditor() { valueField.stringValue = String(format: "%.3f", points[index].value) }
        } else { selectedID = nil; table.deselectAll(nil) }
        refreshing = false
        graph.points = points; graph.duration = duration; graph.range = target.range
        graph.selectedID = selectedID; graph.editable = editable; graph.needsDisplay = true
        buttons.forEach { $0.isEnabled = editable }
        buttons[1].isEnabled = editable && selectedID != nil
        buttons[2].isEnabled = editable && selectedID != nil
        timeField.isEnabled = editable; valueField.isEnabled = editable
    }

    func numberOfRows(in tableView: NSTableView) -> Int { points.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard points.indices.contains(row) else { return nil }
        return NSTextField(labelWithString: String(format: tableColumn?.identifier.rawValue == "time" ? "%.6f" : "%.3f",
                                                  tableColumn?.identifier.rawValue == "time" ? points[row].time : points[row].value))
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshing else { return }
        selectedID = points.indices.contains(table.selectedRow) ? points[table.selectedRow].id : nil
        refresh()
    }
    private func put(id: UUID?, time: Double, value: Double) {
        guard editable, time.isFinite, value.isFinite, time >= 0,
              time <= (target.isClip ? duration : TimelineViewState.maximumTimelineTime),
              target.range.contains(value) else { NSSound.beep(); return }
        switch target {
        case .clipVolume(let clip):
            if let id { controller.moveVolumeKeyframe(clipID: clip, keyframeID: id, time: time, gainDB: value) }
            else { controller.addVolumeKeyframe(clipID: clip, time: time, gainDB: value) }
        case .clipPan(let clip):
            if let id { controller.movePanKeyframe(clipID: clip, keyframeID: id, time: time, pan: value) }
            else { controller.addPanKeyframe(clipID: clip, time: time, pan: value) }
        case .trackVolume(let track):
            if let id { controller.moveTrackVolumeKeyframe(trackID: track, keyframeID: id, time: time, gainDB: value) }
            else { controller.addTrackVolumeKeyframe(trackID: track, time: time, gainDB: value) }
        }
        refresh()
    }
    private func applyFields(id: UUID?) {
        guard let time = NumericInput.number(timeField.stringValue), let value = NumericInput.number(valueField.stringValue) else { NSSound.beep(); return }
        put(id: id, time: time, value: value)
    }
    @objc private func addPoint() { applyFields(id: nil) }
    @objc private func updatePoint() { if let selectedID { applyFields(id: selectedID) } }
    @objc private func deletePoint() {
        guard editable, let selectedID else { return }
        switch target {
        case .clipVolume(let id): controller.deleteVolumeKeyframe(clipID: id, keyframeID: selectedID)
        case .clipPan(let id): controller.deletePanKeyframe(clipID: id, keyframeID: selectedID)
        case .trackVolume(let id): controller.deleteTrackVolumeKeyframe(trackID: id, keyframeID: selectedID)
        }
        refresh()
    }
    @objc private func clearPoints() {
        guard editable else { return }
        switch target {
        case .clipVolume(let id): controller.clearVolumeAutomation(clipID: id)
        case .clipPan(let id): controller.clearPanAutomation(clipID: id)
        case .trackVolume(let id): controller.clearTrackVolumeAutomation(trackID: id)
        }
        refresh()
    }
    func windowWillClose(_ notification: Notification) { controller.endContinuousEdit() }
}

private final class AutomationGraphView: NSView {
    var points: [AutomationPoint] = []
    var duration: Double = 1
    var range: ClosedRange<Double> = -100...100
    var editable = false
    var selectedID: UUID?
    var onSelect: ((UUID) -> Void)?
    var onEdit: ((UUID?, Double, Double) -> Void)?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    private var dragging: UUID?
    private var plot: NSRect { bounds.insetBy(dx: 12, dy: 12) }
    private func position(_ p: AutomationPoint) -> NSPoint {
        NSPoint(x: plot.minX + p.time / max(duration, 0.001) * plot.width,
                y: plot.minY + (p.value - range.lowerBound) / (range.upperBound - range.lowerBound) * plot.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        NSColor.separatorColor.setStroke(); NSBezierPath(rect: plot).stroke()
        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            if index == 0 { path.move(to: position(point)) } else { path.line(to: position(point)) }
        }
        NSColor.controlAccentColor.setStroke(); path.lineWidth = 2; path.stroke()
        for point in points {
            (point.id == selectedID ? NSColor.systemOrange : NSColor.controlAccentColor).setFill()
            let p = position(point)
            NSBezierPath(ovalIn: NSRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)).fill()
        }
    }
    private func edit(_ event: NSEvent, id: UUID?) {
        let p = convert(event.locationInWindow, from: nil)
        let x = min(1, max(0, (p.x - plot.minX) / max(1, plot.width)))
        let y = min(1, max(0, (p.y - plot.minY) / max(1, plot.height)))
        onEdit?(id, Double(x) * duration, range.lowerBound + Double(y) * (range.upperBound - range.lowerBound))
    }
    override func mouseDown(with event: NSEvent) {
        guard editable else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let nearest = points.min(by: { hypot(position($0).x - p.x, position($0).y - p.y) < hypot(position($1).x - p.x, position($1).y - p.y) }),
           hypot(position(nearest).x - p.x, position(nearest).y - p.y) <= 14 {
            dragging = nearest.id; onSelect?(nearest.id); onBegin?()
        } else { edit(event, id: nil) }
    }
    override func mouseDragged(with event: NSEvent) { if editable, let dragging { edit(event, id: dragging) } }
    override func mouseUp(with event: NSEvent) { if dragging != nil { onEnd?() }; dragging = nil }
}
