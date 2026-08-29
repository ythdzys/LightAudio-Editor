import AppKit

private let mediaAssetPasteboardType = NSPasteboard.PasteboardType("com.lightaudio.editor.media-asset-id")
private let fileNamesPasteboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

final class MediaBinViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate {
    var assets: [MediaAsset] = [] {
        didSet {
            let selected = selectedAsset?.id
            tableView.reloadData()
            if let selected = selected {
                selectAsset(id: selected)
            }
            updatePlaceholder()
        }
    }
    var usedAssetIDs: Set<UUID> = [] {
        didSet { tableView.reloadData() }
    }
    var usageCounts: [UUID: Int] = [:] {
        didSet { tableView.reloadData() }
    }
    var onAddAsset: ((UUID) -> Void)?
    var onAddAssetToNewTrack: ((UUID) -> Void)?
    var onImportRequested: (() -> Void)?
    var onImportFolderRequested: (() -> Void)?
    var onImportURLs: (([URL]) -> Void)?
    var onRelinkAsset: ((UUID) -> Void)?
    var onRenameAsset: ((UUID) -> Void)?
    var onRegenerateWaveform: ((UUID) -> Void)?
    var onRegenerateProxy: ((UUID) -> Void)?
    var onCancelProxyGeneration: ((UUID) -> Void)?
    var onRemoveAsset: ((UUID) -> Void)?
    var onShowInfo: ((UUID) -> Void)?
    var onShowWaveformError: ((UUID) -> Void)?

    private let rootView = MediaBinDropView()
    private let tableView = MediaBinTableView()
    private let searchField = NSSearchField()
    private let filterPopup = NSPopUpButton()
    private let sortPopup = NSPopUpButton()
    private let placeholderTitle = PassthroughLabel(labelWithString: L10n.tr("Import audio or video files"))
    private let placeholderHint = PassthroughLabel(labelWithString: L10n.tr("Drag files here or right-click to import"))
    private var filterOption: MediaFilterOption = .all
    private var sortOption: MediaSortOption = MediaSortOption.saved

    private var displayedAssets: [MediaAsset] {
        var result = assets
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            result = result.filter { asset in
                asset.displayName.lowercased().contains(query)
                    || asset.metadata.fileName.lowercased().contains(query)
                    || asset.originalPath.lowercased().contains(query)
            }
        }
        result = result.filter { asset in
            switch filterOption {
            case .all: return true
            case .audio: return asset.kind == .audio
            case .videoAudio: return asset.kind == .videoAudio
            case .missing: return asset.isMissing || asset.proxyStatus == .missing
            case .waveformFailed: return asset.waveformStatus == .failed
            case .proxyFailed: return asset.proxyStatus == .failed
            case .used: return usageCounts[asset.id, default: 0] > 0
            case .unused: return usageCounts[asset.id, default: 0] == 0
            }
        }
        return result.sorted { lhs, rhs in
            switch sortOption {
            case .name:
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            case .duration:
                return lhs.metadata.duration == rhs.metadata.duration ? lhs.displayName < rhs.displayName : lhs.metadata.duration < rhs.metadata.duration
            case .mediaType:
                return lhs.kind.rawValue == rhs.kind.rawValue ? lhs.displayName < rhs.displayName : lhs.kind.rawValue < rhs.kind.rawValue
            case .status:
                return statusText(for: lhs) == statusText(for: rhs) ? lhs.displayName < rhs.displayName : statusText(for: lhs) < statusText(for: rhs)
            case .dateImported:
                return (lhs.importedAt ?? .distantPast) > (rhs.importedAt ?? .distantPast)
            case .used:
                let leftUsed = usageCounts[lhs.id, default: 0]
                let rightUsed = usageCounts[rhs.id, default: 0]
                return leftUsed == rightUsed ? lhs.displayName < rhs.displayName : leftUsed > rightUsed
            }
        }
    }

    override func loadView() {
        let scroll = MediaBinScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(addSelectedToNewTrack)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
        tableView.menuProvider = { [weak self] event in self?.menu(for: event) }
        tableView.onURLsDropped = { [weak self] urls in self?.onImportURLs?(urls) }
        tableView.onDragHighlightChanged = { [weak self] highlighted in self?.rootView.setDropTargeted(highlighted) }
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.onURLsDropped = { [weak self] urls in self?.onImportURLs?(urls) }
        scroll.onDragHighlightChanged = { [weak self] highlighted in self?.rootView.setDropTargeted(highlighted) }

        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.menuProvider = { [weak self] _ in self?.emptyMenu() }
        rootView.onURLsDropped = { [weak self] urls in self?.onImportURLs?(urls) }

        searchField.placeholderString = L10n.tr("Search media")
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        filterPopup.addItems(withTitles: MediaFilterOption.allCases.map(\.title))
        filterPopup.target = self
        filterPopup.action = #selector(filterChanged)
        sortPopup.addItems(withTitles: MediaSortOption.allCases.map(\.title))
        sortPopup.selectItem(at: MediaSortOption.allCases.firstIndex(of: sortOption) ?? 0)
        sortPopup.target = self
        sortPopup.action = #selector(sortChanged)
        let controls = NSStackView(views: [filterPopup, sortPopup])
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.distribution = .fillEqually
        controls.spacing = 6

        let placeholderStack = NSStackView(views: [placeholderTitle, placeholderHint])
        placeholderStack.translatesAutoresizingMaskIntoConstraints = false
        placeholderStack.orientation = .vertical
        placeholderStack.alignment = .centerX
        placeholderStack.spacing = 5
        placeholderTitle.textColor = .secondaryLabelColor
        placeholderTitle.font = .systemFont(ofSize: 13, weight: .medium)
        placeholderTitle.alignment = .center
        placeholderHint.textColor = .tertiaryLabelColor
        placeholderHint.font = .systemFont(ofSize: 11, weight: .regular)
        placeholderHint.alignment = .center

        rootView.addSubview(searchField)
        rootView.addSubview(controls)
        rootView.addSubview(scroll)
        rootView.addSubview(placeholderStack)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -8),
            controls.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            controls.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            placeholderStack.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            placeholderStack.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),
            placeholderStack.leadingAnchor.constraint(greaterThanOrEqualTo: rootView.leadingAnchor, constant: 16),
            placeholderStack.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -16)
        ])
        view = rootView
        updatePlaceholder()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedAssets.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = id
        if cell.textField == nil {
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        let asset = displayedAssets[row]
        let usage = usageCounts[asset.id, default: 0]
        let usageText = usage == 0
            ? L10n.tr("unused")
            : L10n.format(usage == 1 ? "%d use" : "%d uses", usage)
        cell.textField?.stringValue = "\(asset.displayName)  \(statusText(for: asset))  \(usageText)"
        cell.textField?.textColor = asset.isMissing || asset.waveformStatus == .failed || asset.proxyStatus == .failed || asset.proxyStatus == .unsupported ? .systemRed : .labelColor
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let assets = displayedAssets
        guard row >= 0 && row < assets.count else { return nil }
        let item = NSPasteboardItem()
        item.setString(assets[row].id.uuidString, forType: mediaAssetPasteboardType)
        item.setString(assets[row].displayName, forType: .string)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        externalFileURLs(from: info.draggingPasteboard).isEmpty ? [] : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = externalFileURLs(from: info.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        rootView.setDropTargeted(false)
        onImportURLs?(urls)
        return true
    }

    func selectAsset(id: UUID) {
        guard let row = displayedAssets.firstIndex(where: { $0.id == id }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    @objc private func addSelected() {
        guard let asset = selectedAsset else { return }
        onAddAsset?(asset.id)
    }

    @objc private func addSelectedToNewTrack() {
        guard let asset = selectedAsset else { return }
        onAddAssetToNewTrack?(asset.id)
    }

    private func menu(for event: NSEvent) -> NSMenu? {
        let point = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: point)
        let assets = displayedAssets
        guard row >= 0 && row < assets.count else {
            tableView.deselectAll(nil)
            return emptyMenu()
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return itemMenu(for: assets[row])
    }

    private func emptyMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(targetedItem(title: "Import Media...", action: #selector(importMedia)))
        menu.addItem(targetedItem(title: "Import Folder...", action: #selector(importFolder)))
        return menu
    }

    private func itemMenu(for asset: MediaAsset) -> NSMenu {
        let fileExists = FileManager.default.fileExists(atPath: asset.originalPath)
        let menu = NSMenu()

        let add = targetedItem(title: "Add to Timeline at Playhead", action: #selector(addSelected))
        add.isEnabled = !asset.isMissing && asset.proxyStatus != .failed && asset.proxyStatus != .unsupported
        menu.addItem(add)

        menu.addItem(targetedItem(title: "Rename Media...", action: #selector(renameSelected)))

        let reveal = targetedItem(title: "Reveal in Finder", action: #selector(revealSelected))
        reveal.isEnabled = fileExists && !asset.isMissing
        menu.addItem(reveal)

        let relink = targetedItem(title: "Relink Media...", action: #selector(relinkSelected))
        relink.isEnabled = asset.isMissing || !fileExists || asset.proxyStatus == .missing
        menu.addItem(relink)

        menu.addItem(NSMenuItem.separator())

        let waveform = targetedItem(title: "Regenerate Waveform", action: #selector(regenerateWaveformSelected))
        waveform.isEnabled = !asset.isMissing
        menu.addItem(waveform)

        if asset.waveformStatus == .failed {
            menu.addItem(targetedItem(title: "Show Waveform Error", action: #selector(showWaveformErrorSelected)))
        }

        if asset.kind == .videoAudio {
            let proxy = targetedItem(title: "Regenerate Audio Proxy", action: #selector(regenerateProxySelected))
            proxy.isEnabled = !asset.isMissing
            menu.addItem(proxy)

            if asset.proxyStatus == .generating {
                menu.addItem(targetedItem(title: "Cancel Audio Proxy Generation", action: #selector(cancelProxyGenerationSelected)))
            }
        }

        menu.addItem(NSMenuItem.separator())

        menu.addItem(targetedItem(title: "Show Media Info", action: #selector(showInfoSelected)))
        let remove = targetedItem(title: "Remove from Project", action: #selector(removeSelected))
        remove.isEnabled = !usedAssetIDs.contains(asset.id)
        menu.addItem(remove)
        return menu
    }

    private func targetedItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.tr(title), action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func importMedia() {
        onImportRequested?()
    }

    @objc private func importFolder() {
        onImportFolderRequested?()
    }

    @objc private func relinkSelected() {
        guard let asset = selectedAsset else { return }
        onRelinkAsset?(asset.id)
    }

    @objc private func revealSelected() {
        guard let asset = selectedAsset, !asset.isMissing else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: asset.originalPath)])
    }

    @objc private func renameSelected() {
        guard let asset = selectedAsset else { return }
        onRenameAsset?(asset.id)
    }

    @objc private func regenerateWaveformSelected() {
        guard let asset = selectedAsset else { return }
        onRegenerateWaveform?(asset.id)
    }

    @objc private func regenerateProxySelected() {
        guard let asset = selectedAsset else { return }
        onRegenerateProxy?(asset.id)
    }

    @objc private func cancelProxyGenerationSelected() {
        guard let asset = selectedAsset else { return }
        onCancelProxyGeneration?(asset.id)
    }

    @objc private func removeSelected() {
        guard let asset = selectedAsset else { return }
        onRemoveAsset?(asset.id)
    }

    @objc private func showInfoSelected() {
        guard let asset = selectedAsset else { return }
        onShowInfo?(asset.id)
    }

    @objc private func showWaveformErrorSelected() {
        guard let asset = selectedAsset else { return }
        onShowWaveformError?(asset.id)
    }

    private var selectedAsset: MediaAsset? {
        let row = tableView.selectedRow
        let assets = displayedAssets
        guard row >= 0 && row < assets.count else { return nil }
        return assets[row]
    }

    private func statusText(for asset: MediaAsset) -> String {
        if asset.isMissing || asset.proxyStatus == .missing {
            return L10n.tr("Missing")
        }
        switch asset.proxyStatus {
        case .generating:
            return L10n.tr("Generating audio proxy")
        case .failed:
            return L10n.tr("Proxy failed")
        case .unsupported:
            return L10n.tr("Unsupported")
        case .ready, .none:
            break
        case .missing:
            return L10n.tr("Missing")
        }
        switch asset.waveformStatus {
        case .notGenerated:
            return L10n.tr("Pending waveform")
        case .generating:
            return L10n.tr("Generating waveform")
        case .ready:
            return L10n.tr("Ready")
        case .failed:
            return L10n.tr("Waveform failed")
        case .missing:
            return L10n.tr("Missing")
        }
    }

    private func updatePlaceholder() {
        let isEmptyDisplay = displayedAssets.isEmpty
        placeholderTitle.isHidden = !isEmptyDisplay
        placeholderHint.isHidden = !isEmptyDisplay
        if assets.isEmpty {
            placeholderTitle.stringValue = L10n.tr("Import audio or video files")
            placeholderHint.stringValue = L10n.tr("Drag files here or right-click to import")
        } else {
            placeholderTitle.stringValue = L10n.tr("No matching media")
            placeholderHint.stringValue = L10n.tr("Clear search or change filter")
        }
    }

    @objc private func searchChanged() {
        reloadPreservingSelection()
    }

    func controlTextDidChange(_ obj: Notification) {
        searchChanged()
    }

    @objc private func filterChanged() {
        filterOption = MediaFilterOption.allCases[max(0, min(MediaFilterOption.allCases.count - 1, filterPopup.indexOfSelectedItem))]
        reloadPreservingSelection()
    }

    @objc private func sortChanged() {
        sortOption = MediaSortOption.allCases[max(0, min(MediaSortOption.allCases.count - 1, sortPopup.indexOfSelectedItem))]
        UserDefaults.standard.set(sortOption.rawValue, forKey: MediaSortOption.userDefaultsKey)
        reloadPreservingSelection()
    }

    private func reloadPreservingSelection() {
        let selected = selectedAsset?.id
        tableView.reloadData()
        if let selected = selected {
            selectAsset(id: selected)
        }
        updatePlaceholder()
    }
}

private enum MediaSortOption: String, CaseIterable {
    static let userDefaultsKey = "LightAudio.MediaBinSort"
    case name
    case duration
    case mediaType
    case status
    case dateImported
    case used

    static var saved: MediaSortOption {
        if let raw = UserDefaults.standard.string(forKey: userDefaultsKey), let option = MediaSortOption(rawValue: raw) {
            return option
        }
        return .name
    }

    var title: String {
        switch self {
        case .name: return L10n.tr("Name")
        case .duration: return L10n.tr("Duration")
        case .mediaType: return L10n.tr("Type")
        case .status: return L10n.tr("Status")
        case .dateImported: return L10n.tr("Imported")
        case .used: return L10n.tr("Used")
        }
    }
}

private enum MediaFilterOption: CaseIterable {
    case all
    case audio
    case videoAudio
    case missing
    case waveformFailed
    case proxyFailed
    case used
    case unused

    var title: String {
        switch self {
        case .all: return L10n.tr("All")
        case .audio: return L10n.tr("Audio")
        case .videoAudio: return L10n.tr("Video")
        case .missing: return L10n.tr("Missing")
        case .waveformFailed: return L10n.tr("Waveform Failed")
        case .proxyFailed: return L10n.tr("Proxy Failed")
        case .used: return L10n.tr("Used")
        case .unused: return L10n.tr("Unused")
        }
    }
}

private final class MediaBinDropView: NSView {
    var onURLsDropped: (([URL]) -> Void)?
    var menuProvider: ((NSEvent) -> NSMenu?)?
    private var isDropTargeted = false {
        didSet { needsDisplay = true }
    }

    func setDropTargeted(_ targeted: Bool) {
        isDropTargeted = targeted
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, fileNamesPasteboardType])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, fileNamesPasteboardType])
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !externalFileURLs(from: sender.draggingPasteboard).isEmpty else { return [] }
        isDropTargeted = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        externalFileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTargeted = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTargeted = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !externalFileURLs(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTargeted = false
        let urls = externalFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onURLsDropped?(urls)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isDropTargeted else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        bounds.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.75).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 6, yRadius: 6)
        border.lineWidth = 2
        border.stroke()
    }
}

private final class MediaBinTableView: NSTableView {
    var onURLsDropped: (([URL]) -> Void)?
    var menuProvider: ((NSEvent) -> NSMenu?)?
    var onDragHighlightChanged: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, fileNamesPasteboardType])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, fileNamesPasteboardType])
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepts = !externalFileURLs(from: sender.draggingPasteboard).isEmpty
        onDragHighlightChanged?(accepts)
        return accepts ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        externalFileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragHighlightChanged?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragHighlightChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !externalFileURLs(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragHighlightChanged?(false)
        let urls = externalFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onURLsDropped?(urls)
        return true
    }
}

private final class MediaBinScrollView: NSScrollView {
    var onURLsDropped: (([URL]) -> Void)?
    var onDragHighlightChanged: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, fileNamesPasteboardType])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, fileNamesPasteboardType])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepts = !externalFileURLs(from: sender.draggingPasteboard).isEmpty
        onDragHighlightChanged?(accepts)
        return accepts ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        externalFileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragHighlightChanged?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragHighlightChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !externalFileURLs(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragHighlightChanged?(false)
        let urls = externalFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onURLsDropped?(urls)
        return true
    }
}

private final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private func externalFileURLs(from pasteboard: NSPasteboard) -> [URL] {
    guard pasteboard.availableType(from: [mediaAssetPasteboardType]) == nil else { return [] }
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
        return urls
    }
    if let paths = pasteboard.propertyList(forType: fileNamesPasteboardType) as? [String] {
        return paths.map { URL(fileURLWithPath: $0) }
    }
    return []
}
