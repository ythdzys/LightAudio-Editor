import AppKit

private let mediaAssetPasteboardType = NSPasteboard.PasteboardType("com.lightaudio.editor.media-asset-id")

enum TimelineContentSizing {
    static let maximumWidth: CGFloat = 8_000_000

    static func contentWidth(calculatedWidth: Double, viewportWidth: CGFloat) -> CGFloat {
        let safeCalculated = calculatedWidth.isFinite ? CGFloat(max(0, calculatedWidth)) : maximumWidth
        let safeViewport = viewportWidth.isFinite ? max(0, viewportWidth) : 0
        return min(maximumWidth, max(320, max(safeCalculated, safeViewport)))
    }
}

enum TimelineScrollInvalidation {
    static func newlyExposedRects(from oldBounds: NSRect, to newBounds: NSRect) -> [NSRect] {
        let old = oldBounds.standardized
        let new = newBounds.standardized
        guard new.width > 0, new.height > 0 else { return [] }

        let overlap = old.intersection(new)
        guard !overlap.isNull, !overlap.isEmpty else { return [new] }

        var rects: [NSRect] = []
        if new.minX < overlap.minX {
            rects.append(NSRect(x: new.minX, y: new.minY, width: overlap.minX - new.minX, height: new.height))
        }
        if overlap.maxX < new.maxX {
            rects.append(NSRect(x: overlap.maxX, y: new.minY, width: new.maxX - overlap.maxX, height: new.height))
        }

        if overlap.width > 0 {
            if new.minY < overlap.minY {
                rects.append(NSRect(x: overlap.minX, y: new.minY, width: overlap.width, height: overlap.minY - new.minY))
            }
            if overlap.maxY < new.maxY {
                rects.append(NSRect(x: overlap.minX, y: overlap.maxY, width: overlap.width, height: new.maxY - overlap.maxY))
            }
        }
        return rects.filter { $0.width > 0 && $0.height > 0 }
    }
}

enum WaveformRenderMetrics {
    static let maximumDrawnColumns = 6_000
    static let maximumReferenceSamples = 8_192

    static func barCount(peakCount: Int, dirtyWidth: CGFloat) -> Int {
        guard peakCount > 0 else { return 1 }
        let pixelColumns = max(1, Int(ceil(max(0, dirtyWidth))))
        return max(1, min(peakCount, min(maximumDrawnColumns, pixelColumns)))
    }

    static func referencePeak(
        peaks: [WaveformPeak],
        percentile: Double,
        noiseFloor: Float
    ) -> Float {
        guard !peaks.isEmpty else { return 1 }
        let stride = max(1, Int(ceil(Double(peaks.count) / Double(maximumReferenceSamples))))
        var amplitudes: [Float] = []
        amplitudes.reserveCapacity(min(peaks.count, maximumReferenceSamples))
        var index = 0
        while index < peaks.count {
            let peak = peaks[index]
            let amplitude = max(abs(peak.min), abs(peak.max))
            if amplitude.isFinite, amplitude > noiseFloor {
                amplitudes.append(amplitude)
            }
            index += stride
        }
        guard !amplitudes.isEmpty else { return 1 }
        amplitudes.sort()
        let clampedPercentile = min(1, max(0, percentile))
        let percentileIndex = min(
            amplitudes.count - 1,
            max(0, Int(Double(amplitudes.count - 1) * clampedPercentile))
        )
        return max(noiseFloor, amplitudes[percentileIndex])
    }
}

final class TimelineView: NSView {
    enum TrimEdge { case left, right }

    var project: Project = .empty() {
        didSet {
            rebuildProjectCaches()
            needsDisplay = true
        }
    }
    var waveforms: [UUID: WaveformData] = [:] {
        didSet {
            let activeCacheKeys = Set(waveforms.values.map(\.cacheKey))
            waveformReferencePeakCache = waveformReferencePeakCache.filter { activeCacheKeys.contains($0.key) }
            needsDisplay = true
        }
    }
    var selectedClipIDs: Set<UUID> = [] { didSet { needsDisplay = true } }
    var selectedClipID: UUID? { didSet { needsDisplay = true } }
    var playheadTime: TimeInterval = 0 {
        didSet { invalidatePlayhead(from: oldValue, to: playheadTime) }
    }
    var trackLevels: [UUID: Double] = [:] {
        didSet { invalidateVisibleTrackHeaders() }
    }
    var tool: TimelineTool = .selection

    var onSelectClip: ((UUID?) -> Void)?
    var onSelectClipWithModifiers: ((UUID, Bool, Bool) -> Void)?
    var onSelectClips: ((Set<UUID>, Bool) -> Void)?
    var onMoveClip: ((UUID, TimeInterval, Int) -> Void)?
    var onTrimClip: ((UUID, TrimEdge, TimeInterval) -> Void)?
    var onSetClipFade: ((UUID, TrimEdge, TimeInterval) -> Void)?
    var onSplitClip: ((UUID, TimeInterval) -> Void)?
    var onSetPlayhead: ((TimeInterval) -> Void)?
    var onToggleTrackMute: ((UUID) -> Void)?
    var onToggleTrackSolo: ((UUID) -> Void)?
    var onToggleTrackLock: ((UUID) -> Void)?
    var onSetTrackVolume: ((UUID, Double) -> Void)?
    var onSetTrackPan: ((UUID, Double) -> Void)?
    var onRenameTrack: ((UUID) -> Void)?
    var onAddTrack: (() -> Void)?
    var onAddTrackAbove: ((UUID) -> Void)?
    var onAddTrackBelow: ((UUID) -> Void)?
    var onDuplicateTrack: ((UUID) -> Void)?
    var onToggleTrackCollapse: ((UUID) -> Void)?
    var onResetTrackHeight: (() -> Void)?
    var onReorderTrack: ((UUID, Int) -> Void)?
    var onDropAsset: ((UUID, TimeInterval, Int) -> Void)?
    var onPinchZoom: ((Double, TimeInterval, CGFloat) -> Void)?
    var onAddMarker: (() -> Void)?
    var onDeleteMarker: ((UUID) -> Void)?
    var onRenameMarker: ((UUID) -> Void)?
    var onRenameClip: ((UUID) -> Void)?
    var onSetClipColor: ((UUID, ClipColorLabel) -> Void)?
    var onSetClipFadeCurve: ((UUID, TrimEdge, FadeCurve) -> Void)?
    var onCreateCrossfade: ((UUID) -> Void)?
    var onSetCrossfadeCurve: ((UUID, CrossfadeCurve) -> Void)?
    var onRemoveCrossfades: ((UUID) -> Void)?
    var onAddVolumeKeyframe: ((UUID, TimeInterval, Double) -> Void)?
    var onAddVolumeKeyframeAtPlayhead: ((UUID) -> Void)?
    var onMoveVolumeKeyframe: ((UUID, UUID, TimeInterval, Double) -> Void)?
    var onDeleteVolumeKeyframe: ((UUID, UUID) -> Void)?
    var onClearVolumeAutomation: ((UUID) -> Void)?
    var onNormalizeClip: ((UUID) -> Void)?
    var onCopy: (() -> Void)?
    var onCut: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onDuplicateSelectionForDrag: ((UUID) -> UUID?)?
    var onDelete: (() -> Void)?
    var onDeleteTrack: ((UUID) -> Void)?
    var onRippleDelete: (() -> Void)?
    var onStatusMessage: ((String) -> Void)?
    var onBeginContinuousEdit: ((String) -> Void)?
    var onEndContinuousEdit: (() -> Void)?

    private let rulerHeight: CGFloat = 28
    private let collapsedTrackHeight: CGFloat = 36
    private let trackHeaderWidth: CGFloat = 150
    private let maxAutoCreatedTracksPerDrop = 4
    private var dragState: DragState?
    private var marqueeStart: NSPoint?
    private var marqueeCurrent: NSPoint?
    private var marqueeAddsToSelection = false
    private var snapGuideX: CGFloat?
    private var trackMixDrag: TrackMixDrag?
    private var dropPreview: DropPreview?
    private var trackReorderDrag: TrackReorderDrag?
    private var selectedVolumeKeyframe: VolumeKeyframeSelection?
    private var volumeKeyframeDrag: VolumeKeyframeSelection?
    private var fadeHandleDrag: FadeHandleDrag?
    private var hoverTrimEdge: TrimEdgeHover?
    private var trimDragPreview: TrimDragPreview?
    private var timelineTrackingArea: NSTrackingArea?
    private var pinchZoomState: PinchZoomState?
    private var isContinuousEditActive = false
    private weak var observedScrollClipView: NSClipView?
    private var scrollBoundsObserver: NSObjectProtocol?
    private var lastObservedScrollBounds: NSRect?
    private var trackOrigins: [CGFloat] = []
    private var cachedTrackHeights: [CGFloat] = []
    private var tracksBottom: CGFloat = 28
    private var assetsByID: [UUID: MediaAsset] = [:]
    private var crossfadesByTrackID: [UUID: [Crossfade]] = [:]
    private var waveformReferencePeakCache: [String: Float] = [:]

    private struct DragState {
        var clipID: UUID
        var offset: CGFloat
        var edge: TrimEdge?
    }

    private func beginContinuousEdit(_ actionName: String) {
        guard !isContinuousEditActive else { return }
        isContinuousEditActive = true
        onBeginContinuousEdit?(actionName)
    }

    private func endContinuousEdit() {
        guard isContinuousEditActive else { return }
        isContinuousEditActive = false
        onEndContinuousEdit?()
    }

    private struct TrackMixDrag {
        enum Control {
            case volume
            case pan
        }

        var trackID: UUID
        var trackIndex: Int
        var control: Control
    }

    private struct DropPreview {
        var assetID: UUID
        var time: TimeInterval
        var trackIndex: Int
        var allowed: Bool
        var clamped: Bool
        var isHeaderDrop: Bool
    }

    private struct PinchZoomState {
        let initialZoom: Double
        let anchorTime: TimeInterval
        let anchorViewportX: CGFloat
    }

    private struct TrackReorderDrag {
        var trackID: UUID
        var sourceIndex: Int
        var currentIndex: Int
        var startY: CGFloat
        var hasMoved: Bool = false
    }

    private struct VolumeKeyframeSelection: Equatable {
        var clipID: UUID
        var keyframeID: UUID
    }

    private struct FadeHandleDrag {
        var clipID: UUID
        var edge: TrimEdge
        var trackIndex: Int
    }

    private struct TrimEdgeHover: Equatable {
        var clipID: UUID
        var edge: TrimEdge
    }

    private struct TrimDragPreview {
        var clipID: UUID
        var edge: TrimEdge
        var timelineTime: TimeInterval
        var duration: TimeInterval
        var isValid: Bool
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rebuildProjectCaches()
        registerForDraggedTypes([mediaAssetPasteboardType])
        installMagnificationGesture()
        window?.acceptsMouseMovedEvents = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        rebuildProjectCaches()
        registerForDraggedTypes([mediaAssetPasteboardType])
        installMagnificationGesture()
        window?.acceptsMouseMovedEvents = true
    }

    private func installMagnificationGesture() {
        addGestureRecognizer(NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnification(_:))))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        observeScrollBounds()
    }

    deinit {
        if let scrollBoundsObserver {
            NotificationCenter.default.removeObserver(scrollBoundsObserver)
        }
    }

    private func observeScrollBounds() {
        guard let clipView = enclosingScrollView?.contentView, observedScrollClipView !== clipView else { return }
        if let scrollBoundsObserver {
            NotificationCenter.default.removeObserver(scrollBoundsObserver)
        }
        observedScrollClipView = clipView
        lastObservedScrollBounds = clipView.bounds
        clipView.postsBoundsChangedNotifications = true
        scrollBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.scrollBoundsDidChange(to: clipView.bounds)
        }
    }

    private func scrollBoundsDidChange(to newBounds: NSRect) {
        let oldBounds = lastObservedScrollBounds ?? newBounds
        lastObservedScrollBounds = newBounds

        for rect in TimelineScrollInvalidation.newlyExposedRects(from: oldBounds, to: newBounds) {
            setNeedsDisplay(rect.intersection(bounds))
        }

        let oldHeader = NSRect(x: oldBounds.minX, y: oldBounds.minY, width: trackHeaderWidth + 1, height: oldBounds.height)
        let newHeader = NSRect(x: newBounds.minX, y: newBounds.minY, width: trackHeaderWidth + 1, height: newBounds.height)
        setNeedsDisplay(oldHeader.union(newHeader))
    }

    override func updateTrackingAreas() {
        if let timelineTrackingArea = timelineTrackingArea {
            removeTrackingArea(timelineTrackingArea)
        }
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        timelineTrackingArea = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    var secondsPerPoint: Double {
        1.0 / TimelineViewState.clampedZoom(project.viewState.zoom)
    }

    private var expandedTrackHeight: CGFloat {
        CGFloat(TimelineViewState.clampedTrackHeight(project.viewState.trackHeight))
    }

    private func rebuildProjectCaches() {
        var indexedAssets: [UUID: MediaAsset] = [:]
        for asset in project.assets where indexedAssets[asset.id] == nil {
            indexedAssets[asset.id] = asset
        }
        assetsByID = indexedAssets
        trackOrigins.removeAll(keepingCapacity: true)
        cachedTrackHeights.removeAll(keepingCapacity: true)
        trackOrigins.reserveCapacity(project.timeline.tracks.count)
        cachedTrackHeights.reserveCapacity(project.timeline.tracks.count)

        var y = rulerHeight
        var clipTrackIDs: [UUID: UUID] = [:]
        for track in project.timeline.tracks {
            let trackHeight = height(for: track)
            trackOrigins.append(y)
            cachedTrackHeights.append(trackHeight)
            y += trackHeight
            for clip in track.clips {
                clipTrackIDs[clip.id] = track.id
            }
        }
        tracksBottom = y

        var indexedCrossfades: [UUID: [Crossfade]] = [:]
        for crossfade in project.timeline.crossfades {
            guard let trackID = clipTrackIDs[crossfade.leadingClipID],
                  clipTrackIDs[crossfade.trailingClipID] == trackID else {
                continue
            }
            indexedCrossfades[trackID, default: []].append(crossfade)
        }
        crossfadesByTrackID = indexedCrossfades
    }

    private func height(for track: Track) -> CGFloat {
        track.isCollapsed ? collapsedTrackHeight : expandedTrackHeight
    }

    private var stickyHeaderX: CGFloat {
        max(0, viewportBounds.minX)
    }

    private var viewportBounds: NSRect {
        let viewport = observedScrollClipView?.bounds ?? visibleRect
        let clipped = viewport.intersection(bounds)
        return clipped.isNull || clipped.isEmpty ? bounds : clipped
    }

    private var stickyHeaderMaxX: CGFloat {
        stickyHeaderX + trackHeaderWidth
    }

    private func isPointInStickyHeader(_ point: NSPoint) -> Bool {
        point.x >= stickyHeaderX && point.x < stickyHeaderMaxX
    }

    private func heightForTrack(at index: Int) -> CGFloat {
        guard index >= 0 && index < cachedTrackHeights.count else { return expandedTrackHeight }
        return cachedTrackHeights[index]
    }

    private func trackY(for index: Int) -> CGFloat {
        guard index > 0 else { return rulerHeight }
        if index < trackOrigins.count {
            return trackOrigins[index]
        }
        return tracksBottom + CGFloat(max(0, index - trackOrigins.count)) * expandedTrackHeight
    }

    func preferredContentHeight() -> CGFloat {
        max(520, tracksBottom + 24)
    }

    private func invalidatePlayhead(from oldTime: TimeInterval, to newTime: TimeInterval) {
        let oldX = x(for: oldTime)
        let newX = x(for: newTime)
        let viewport = viewportBounds
        let rect = NSRect(
            x: min(oldX, newX) - 4,
            y: viewport.minY,
            width: abs(newX - oldX) + 8,
            height: max(1, viewport.height)
        )
        setNeedsDisplay(rect)
    }

    private func invalidateVisibleTrackHeaders() {
        let viewport = viewportBounds
        let rect = NSRect(
            x: stickyHeaderX,
            y: viewport.minY,
            width: trackHeaderWidth + 2,
            height: max(1, viewport.height)
        )
        setNeedsDisplay(rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        // On Catalina, visibleRect can lag behind the dirty rectangle by one scroll
        // event. The dirty rectangle is already in document coordinates and is the
        // authoritative region AppKit needs redrawn.
        let renderRect = dirtyRect.intersection(bounds)
        guard !renderRect.isNull, !renderRect.isEmpty else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: renderRect).addClip()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }

        NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
        renderRect.fill()
        drawRuler(in: renderRect)
        drawTracks(in: renderRect)
        drawInOutRange(in: renderRect)
        drawDropPreview(in: renderRect)
        drawSnapGuide(in: renderRect)
        drawPlayhead(in: renderRect)
        drawMarquee(in: renderRect)
        drawEmptyTimelineHintIfNeeded()
        drawStickyHeaderChrome(in: renderRect)
    }

    @discardableResult
    func deleteSelectedAutomationKeyframe() -> Bool {
        guard let selected = selectedVolumeKeyframe else { return false }
        onDeleteVolumeKeyframe?(selected.clipID, selected.keyframeID)
        selectedVolumeKeyframe = nil
        needsDisplay = true
        return true
    }

    private func drawRuler(in renderRect: NSRect) {
        let rulerRect = renderRect.intersection(NSRect(x: 0, y: 0, width: bounds.width, height: rulerHeight))
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        rulerRect.fill()
        let context = NSStringDrawingContext()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.lightGray]
        let step = niceStep()
        let firstX = max(stickyHeaderMaxX, renderRect.minX)
        var time = max(0, floor(time(forX: firstX) / step) * step)
        while x(for: time) <= renderRect.maxX + 1 {
            let x = self.x(for: time)
            NSColor.darkGray.setStroke()
            NSBezierPath.strokeLine(
                from: NSPoint(x: x, y: max(rulerHeight - 8, renderRect.minY)),
                to: NSPoint(x: x, y: renderRect.maxY)
            )
            if !rulerRect.isEmpty {
                (Timecode.string(time) as NSString).draw(
                    with: NSRect(x: x + 4, y: 6, width: 80, height: 16),
                    options: .usesLineFragmentOrigin,
                    attributes: attrs,
                    context: context
                )
            }
            time += step
        }
        drawMarkers(in: renderRect)
    }

    private func drawInOutRange(in renderRect: NSRect) {
        let inPoint = project.viewState.inPoint
        let outPoint = project.viewState.outPoint
        guard inPoint != nil || outPoint != nil else { return }

        if let range = project.viewState.validRange {
            let startX = x(for: range.start)
            let endX = x(for: range.end)
            let rect = NSRect(x: startX, y: 0, width: max(1, endX - startX), height: bounds.height)
            let visibleRangeRect = rect.intersection(renderRect)
            if !visibleRangeRect.isEmpty {
                NSColor.systemBlue.withAlphaComponent(0.08).setFill()
                visibleRangeRect.fill()
            }
            NSColor.systemBlue.withAlphaComponent(0.65).setStroke()
            if startX >= renderRect.minX - 1 && startX <= renderRect.maxX + 1 {
                NSBezierPath.strokeLine(from: NSPoint(x: startX, y: renderRect.minY), to: NSPoint(x: startX, y: renderRect.maxY))
                drawRangeFlag(title: "IN", x: startX, in: renderRect)
            }
            if endX >= renderRect.minX - 1 && endX <= renderRect.maxX + 1 {
                NSBezierPath.strokeLine(from: NSPoint(x: endX, y: renderRect.minY), to: NSPoint(x: endX, y: renderRect.maxY))
                drawRangeFlag(title: "OUT", x: endX, in: renderRect)
            }
        } else {
            if let inPoint = inPoint {
                let markerX = x(for: inPoint)
                if markerX >= renderRect.minX - 1 && markerX <= renderRect.maxX + 1 {
                    NSColor.systemBlue.withAlphaComponent(0.75).setStroke()
                    NSBezierPath.strokeLine(from: NSPoint(x: markerX, y: renderRect.minY), to: NSPoint(x: markerX, y: renderRect.maxY))
                    drawRangeFlag(title: "IN", x: markerX, in: renderRect)
                }
            }
            if let outPoint = outPoint {
                let markerX = x(for: outPoint)
                if markerX >= renderRect.minX - 1 && markerX <= renderRect.maxX + 1 {
                    NSColor.systemPurple.withAlphaComponent(0.75).setStroke()
                    NSBezierPath.strokeLine(from: NSPoint(x: markerX, y: renderRect.minY), to: NSPoint(x: markerX, y: renderRect.maxY))
                    drawRangeFlag(title: "OUT", x: markerX, in: renderRect)
                }
            }
        }
    }

    private func drawRangeFlag(title: String, x: CGFloat, in renderRect: NSRect) {
        guard x >= stickyHeaderMaxX else { return }
        let rect = NSRect(x: x + 3, y: 4, width: title == "IN" ? 22 : 32, height: 14)
        guard rect.intersects(renderRect) else { return }
        NSColor.systemBlue.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        (title as NSString).draw(in: rect.insetBy(dx: 4, dy: 1), withAttributes: attrs)
    }

    private func drawMarkers(in renderRect: NSRect) {
        for marker in project.timeline.markers {
            let markerX = x(for: marker.time)
            guard markerX >= stickyHeaderMaxX,
                  markerX >= renderRect.minX - 104,
                  markerX <= renderRect.maxX + 8 else {
                continue
            }
            if renderRect.minY < rulerHeight {
                NSColor.systemOrange.setFill()
                let triangle = NSBezierPath()
                triangle.move(to: NSPoint(x: markerX, y: rulerHeight - 3))
                triangle.line(to: NSPoint(x: markerX - 5, y: rulerHeight - 13))
                triangle.line(to: NSPoint(x: markerX + 5, y: rulerHeight - 13))
                triangle.close()
                triangle.fill()
            }
            NSColor.systemOrange.withAlphaComponent(0.45).setStroke()
            NSBezierPath.strokeLine(from: NSPoint(x: markerX, y: max(rulerHeight, renderRect.minY)), to: NSPoint(x: markerX, y: renderRect.maxY))
            if renderRect.minY < rulerHeight {
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.systemOrange]
                (marker.name as NSString).draw(in: NSRect(x: markerX + 4, y: 5, width: 100, height: 14), withAttributes: attrs)
            }
        }
    }

    private func drawTracks(in renderRect: NSRect) {
        let bodyBounds = NSRect(
            x: stickyHeaderMaxX + 1,
            y: renderRect.minY,
            width: max(0, bounds.maxX - stickyHeaderMaxX - 1),
            height: renderRect.height
        )
        let bodyRenderRect = renderRect.intersection(bodyBounds)
        guard !bodyRenderRect.isNull, !bodyRenderRect.isEmpty else {
            drawTrackReorderPreview(in: renderRect)
            return
        }
        for (trackIndex, track) in project.timeline.tracks.enumerated() {
            let y = trackY(for: trackIndex)
            let laneHeight = height(for: track)
            let laneRect = NSRect(x: 0, y: y, width: bounds.width, height: laneHeight)
            guard laneRect.intersects(bodyRenderRect) else { continue }
            NSColor(calibratedWhite: trackIndex % 2 == 0 ? 0.135 : 0.12, alpha: 1).setFill()
            laneRect.intersection(bodyRenderRect).fill()
            NSColor(calibratedWhite: 0.24, alpha: 1).setStroke()
            if y >= bodyRenderRect.minY - 1 && y <= bodyRenderRect.maxY + 1 {
                NSBezierPath.strokeLine(from: NSPoint(x: bodyRenderRect.minX, y: y), to: NSPoint(x: bodyRenderRect.maxX, y: y))
            }
            for clip in track.clips {
                if rect(for: clip, trackIndex: trackIndex).intersects(bodyRenderRect) {
                    drawClip(clip, trackIndex: trackIndex, renderRect: bodyRenderRect)
                }
            }
            drawCrossfades(for: track, trackIndex: trackIndex, in: bodyRenderRect)
        }
        drawTrackReorderPreview(in: bodyRenderRect)
    }

    private func drawDropPreview(in renderRect: NSRect) {
        guard let preview = dropPreview else { return }
        let y = trackY(for: preview.trackIndex)
        let laneHeight = preview.trackIndex < project.timeline.tracks.count ? heightForTrack(at: preview.trackIndex) : expandedTrackHeight
        let laneRect = NSRect(x: stickyHeaderMaxX, y: y, width: max(0, bounds.maxX - stickyHeaderMaxX), height: laneHeight)
        guard laneRect.intersects(renderRect) else { return }
        let accent = preview.allowed ? NSColor.controlAccentColor : NSColor.systemRed

        accent.withAlphaComponent(preview.allowed ? 0.16 : 0.12).setFill()
        laneRect.intersection(renderRect).fill()
        accent.withAlphaComponent(preview.allowed ? 0.85 : 0.75).setStroke()
        let laneOutline = NSBezierPath(rect: laneRect.intersection(renderRect).insetBy(dx: 1, dy: 1))
        laneOutline.lineWidth = 1.5
        laneOutline.stroke()

        guard preview.allowed else { return }
        let assetDuration = project.asset(id: preview.assetID)?.metadata.duration ?? 4
        let ghostWidth = min(max(36, CGFloat(assetDuration / secondsPerPoint)), max(48, viewportBounds.width * 0.65))
        let inset: CGFloat = laneHeight < 50 ? 6 : 10
        let ghostRect = NSRect(x: x(for: preview.time), y: y + inset, width: ghostWidth, height: max(18, laneHeight - inset * 2))
        guard ghostRect.intersects(renderRect) else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: ghostRect, xRadius: 5, yRadius: 5).fill()
        NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()
        let ghostOutline = NSBezierPath(roundedRect: ghostRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        ghostOutline.lineWidth = 2
        ghostOutline.stroke()
    }

    private func drawTrackHeader(_ track: Track, y: CGFloat) {
        let laneHeight = height(for: track)
        NSColor(calibratedWhite: 0.155, alpha: 1).setFill()
        NSRect(x: stickyHeaderX, y: y, width: trackHeaderWidth, height: laneHeight).fill()
        NSColor(calibratedWhite: 0.26, alpha: 1).setStroke()
        NSBezierPath.strokeLine(from: NSPoint(x: stickyHeaderMaxX, y: y), to: NSPoint(x: stickyHeaderMaxX, y: y + laneHeight))

        let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]
        (track.name as NSString).draw(in: trackNameRect(y: y), withAttributes: nameAttrs)
        drawCollapseButton(collapsed: track.isCollapsed, rect: collapseButtonRect(y: y))

        drawTrackButton(title: "M", active: track.isMuted, rect: buttonRect(index: 0, y: y))
        drawTrackButton(title: "S", active: track.isSolo, rect: buttonRect(index: 1, y: y))
        drawTrackButton(title: "L", active: track.isLocked, rect: buttonRect(index: 2, y: y))
        if track.isCollapsed {
            drawMeter(level: trackLevels[track.id] ?? 0, rect: trackMeterRect(y: y))
        } else {
            drawTrackMixControls(track, y: y)
        }
    }

    private func drawStickyHeaderChrome(in renderRect: NSRect) {
        let headerRect = NSRect(x: stickyHeaderX, y: renderRect.minY, width: trackHeaderWidth, height: renderRect.height)
        guard headerRect.intersects(renderRect) else { return }
        NSColor(calibratedWhite: 0.145, alpha: 1).setFill()
        headerRect.intersection(renderRect).fill()
        let headerRulerRect = headerRect.intersection(NSRect(x: stickyHeaderX, y: 0, width: trackHeaderWidth, height: rulerHeight))
        if !headerRulerRect.isEmpty {
            NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
            headerRulerRect.fill()
        }

        for (index, track) in project.timeline.tracks.enumerated() {
            let y = trackY(for: index)
            let laneRect = NSRect(x: stickyHeaderX, y: y, width: trackHeaderWidth, height: height(for: track))
            if laneRect.intersects(renderRect) {
                drawTrackHeader(track, y: y)
            }
        }

        drawStickyDropTargetIfNeeded(in: renderRect)
        NSColor(calibratedWhite: 0.26, alpha: 1).setStroke()
        NSBezierPath.strokeLine(
            from: NSPoint(x: stickyHeaderMaxX, y: renderRect.minY),
            to: NSPoint(x: stickyHeaderMaxX, y: renderRect.maxY)
        )
    }

    private func drawStickyDropTargetIfNeeded(in renderRect: NSRect) {
        guard let preview = dropPreview else { return }
        let isVirtualTrack = preview.trackIndex >= project.timeline.tracks.count
        guard preview.isHeaderDrop || isVirtualTrack else { return }

        let y = trackY(for: preview.trackIndex)
        let laneHeight = preview.trackIndex < project.timeline.tracks.count ? heightForTrack(at: preview.trackIndex) : expandedTrackHeight
        let accent = preview.allowed ? NSColor.controlAccentColor : NSColor.systemRed
        let headerRect = NSRect(x: stickyHeaderX, y: y, width: trackHeaderWidth, height: laneHeight)
        guard headerRect.intersects(renderRect) else { return }
        accent.withAlphaComponent(preview.allowed ? 0.12 : 0.08).setFill()
        headerRect.intersection(renderRect).fill()

        guard isVirtualTrack else { return }
        let name = preview.clamped ? "Create A\(preview.trackIndex + 1) max" : "Create A\(preview.trackIndex + 1)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: accent
        ]
        (name as NSString).draw(
            in: NSRect(x: stickyHeaderX + 10, y: y + 9, width: trackHeaderWidth - 20, height: 18),
            withAttributes: attrs
        )
    }

    private func drawTrackMixControls(_ track: Track, y: CGFloat) {
        drawMiniSlider(label: "V", value: (track.volumeDB + 60) / 72, text: String(format: "%.0f dB", track.volumeDB), rect: volumeSliderRect(y: y))
        drawMiniSlider(label: "P", value: (track.pan + 1) / 2, text: String(format: "%+.0f", track.pan * 100), rect: panSliderRect(y: y))
        drawMeter(level: trackLevels[track.id] ?? 0, rect: trackMeterRect(y: y))
    }

    private func drawMiniSlider(label: String, value: Double, text: String, rect: NSRect) {
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
        (label as NSString).draw(in: NSRect(x: rect.minX - 16, y: rect.minY - 4, width: 12, height: 12), withAttributes: labelAttrs)
        NSColor(calibratedWhite: 0.26, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        NSColor.systemTeal.withAlphaComponent(0.75).setFill()
        let knobX = rect.minX + CGFloat(min(1, max(0, value))) * rect.width
        NSBezierPath(ovalIn: NSRect(x: knobX - 3, y: rect.minY - 2, width: 6, height: rect.height + 4)).fill()
        let textAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        (text as NSString).draw(in: NSRect(x: rect.maxX + 4, y: rect.minY - 4, width: 42, height: 12), withAttributes: textAttrs)
    }

    private func drawMeter(level: Double, rect: NSRect) {
        NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        let clamped = min(1.2, max(0, level))
        let width = rect.width * CGFloat(min(1, clamped))
        let color: NSColor = clamped >= 1 ? .systemRed : (clamped > 0.75 ? .systemYellow : .systemGreen)
        color.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height), xRadius: 1.5, yRadius: 1.5).fill()
    }

    private func drawEmptyTimelineHintIfNeeded() {
        guard project.timeline.tracks.flatMap({ $0.clips }).isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.65)
        ]
        let text = "Drag media here to start editing" as NSString
        let size = text.size(withAttributes: attrs)
        let visible = viewportBounds
        let x = max(stickyHeaderMaxX + 24, visible.midX - size.width / 2)
        let y = max(rulerHeight + 40, visible.midY - size.height / 2)
        text.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }

    private func drawTrackButton(title: String, active: Bool, rect: NSRect) {
        (active ? NSColor.systemYellow : NSColor(calibratedWhite: 0.24, alpha: 1)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: active ? NSColor.black : NSColor.white
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
    }

    private func color(for label: ClipColorLabel) -> NSColor {
        switch label {
        case .default:
            return NSColor(calibratedRed: 0.18, green: 0.36, blue: 0.58, alpha: 1)
        case .blue:
            return NSColor.systemBlue.withAlphaComponent(0.82)
        case .green:
            return NSColor.systemGreen.withAlphaComponent(0.74)
        case .purple:
            return NSColor.systemPurple.withAlphaComponent(0.78)
        case .orange:
            return NSColor.systemOrange.withAlphaComponent(0.82)
        case .red:
            return NSColor.systemRed.withAlphaComponent(0.78)
        case .gray:
            return NSColor.systemGray.withAlphaComponent(0.82)
        }
    }

    private func drawCollapseButton(collapsed: Bool, rect: NSRect) {
        NSColor(calibratedWhite: 0.24, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        let path = NSBezierPath()
        if collapsed {
            path.move(to: NSPoint(x: rect.minX + 6, y: rect.minY + 5))
            path.line(to: NSPoint(x: rect.maxX - 5, y: rect.midY))
            path.line(to: NSPoint(x: rect.minX + 6, y: rect.maxY - 5))
        } else {
            path.move(to: NSPoint(x: rect.minX + 5, y: rect.minY + 7))
            path.line(to: NSPoint(x: rect.midX, y: rect.maxY - 5))
            path.line(to: NSPoint(x: rect.maxX - 5, y: rect.minY + 7))
        }
        path.close()
        NSColor.secondaryLabelColor.setFill()
        path.fill()
    }

    private func drawTrackReorderPreview(in renderRect: NSRect) {
        guard let drag = trackReorderDrag, drag.hasMoved else { return }
        let y = trackY(for: drag.currentIndex)
        guard y >= renderRect.minY - 1 && y <= renderRect.maxY + 1 else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: stickyHeaderMaxX, y: y))
        path.line(to: NSPoint(x: renderRect.maxX, y: y))
        path.lineWidth = 2
        path.stroke()
    }

    private func drawClip(_ clip: Clip, trackIndex: Int, renderRect: NSRect) {
        let rect = rect(for: clip, trackIndex: trackIndex)
        let asset = assetsByID[clip.sourceAssetID]
        let offline = asset?.isMissing ?? true
        let selected = selectedClipIDs.contains(clip.id) || clip.id == selectedClipID
        let compact = rect.height < 36

        (offline ? NSColor(calibratedRed: 0.55, green: 0.13, blue: 0.15, alpha: 1) : color(for: clip.colorLabel)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        (selected ? NSColor.systemYellow : NSColor(calibratedWhite: 0.55, alpha: 1)).setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        outline.lineWidth = selected ? 2 : 1
        outline.stroke()
        drawTrimFeedbackIfNeeded(for: clip, in: rect)

        if !compact {
            let waveformRect = rect.insetBy(dx: 0, dy: 24)
            if offline {
                drawPlaceholderWaveform(in: waveformRect, style: .offline, renderRect: renderRect)
            } else if let waveform = waveforms[clip.sourceAssetID] {
                drawWaveform(waveform, clip: clip, in: waveformRect, renderRect: renderRect)
            } else {
                let style: PlaceholderWaveformStyle = asset?.waveformStatus == .failed ? .failed : .generating
                drawPlaceholderWaveform(in: waveformRect, style: style, renderRect: renderRect)
            }
            drawFadeGuides(for: clip, in: rect)
            drawVolumeEnvelope(for: clip, in: rect, selected: selected)
        }

        let title = offline ? "\(clip.customName ?? asset?.displayName ?? "Missing") - MISSING" : (clip.customName ?? asset?.displayName ?? "Clip")
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: compact ? 10 : 12, weight: .medium), .foregroundColor: NSColor.white]
        (title as NSString).draw(in: rect.insetBy(dx: 8, dy: 5), withAttributes: attrs)

        if !compact {
            let detail = String(format: "clip %.0f dB  pan %+.0f", MixMath.db(forLinearGain: clip.gain), clip.pan * 100)
            let detailAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.75)]
            (detail as NSString).draw(in: NSRect(x: rect.minX + 8, y: rect.maxY - 18, width: rect.width - 16, height: 14), withAttributes: detailAttrs)
        }
    }

    private func drawFadeGuides(for clip: Clip, in rect: NSRect) {
        let maxWidth = max(0, rect.width - 16)
        if clip.fadeIn.duration > 0 {
            let width = min(maxWidth, CGFloat(clip.fadeIn.duration / secondsPerPoint))
            let path = fadeGuidePath(
                startX: rect.minX + 6,
                width: width,
                topY: rect.minY + 22,
                bottomY: rect.maxY - 8,
                curve: clip.fadeIn.curve,
                rising: true
            )
            NSColor.white.withAlphaComponent(0.65).setStroke()
            path.lineWidth = 2
            path.stroke()
        }
        if clip.fadeOut.duration > 0 {
            let width = min(maxWidth, CGFloat(clip.fadeOut.duration / secondsPerPoint))
            let path = fadeGuidePath(
                startX: rect.maxX - 6 - width,
                width: width,
                topY: rect.minY + 22,
                bottomY: rect.maxY - 8,
                curve: clip.fadeOut.curve,
                rising: false
            )
            NSColor.white.withAlphaComponent(0.65).setStroke()
            path.lineWidth = 2
            path.stroke()
        }
        drawFadeHandles(for: clip, in: rect)
    }

    private func drawTrimFeedbackIfNeeded(for clip: Clip, in rect: NSRect) {
        let preview = trimDragPreview?.clipID == clip.id ? trimDragPreview : nil
        let hover = hoverTrimEdge?.clipID == clip.id ? hoverTrimEdge : nil
        guard let edge = preview?.edge ?? hover?.edge else { return }

        let accent: NSColor = preview?.isValid == false ? .systemRed : .systemYellow
        let edgeX = edge == .left ? rect.minX : rect.maxX
        let edgeLine = NSBezierPath()
        edgeLine.move(to: NSPoint(x: edgeX, y: rect.minY + 4))
        edgeLine.line(to: NSPoint(x: edgeX, y: rect.maxY - 4))
        accent.withAlphaComponent(preview == nil ? 0.8 : 0.95).setStroke()
        edgeLine.lineWidth = preview == nil ? 1.5 : 2
        edgeLine.stroke()

        drawTrimHandle(edge: edge, in: rect, color: accent, active: preview != nil)

        guard let preview = preview else { return }
        drawTrimPreviewLine(preview, clipRect: rect, color: accent)
        drawTrimTooltip(preview, clipRect: rect, color: accent)
    }

    private func drawTrimHandle(edge: TrimEdge, in rect: NSRect, color: NSColor, active: Bool) {
        let height = min(max(18, rect.height * 0.46), 34)
        let centerY = rect.midY
        let insetWidth: CGFloat = active ? 13 : 10
        let halfHeight = height / 2
        let path = NSBezierPath()
        if edge == .left {
            path.move(to: NSPoint(x: rect.minX + 1, y: centerY - halfHeight))
            path.line(to: NSPoint(x: rect.minX + insetWidth, y: centerY - halfHeight + 5))
            path.line(to: NSPoint(x: rect.minX + insetWidth, y: centerY + halfHeight - 5))
            path.line(to: NSPoint(x: rect.minX + 1, y: centerY + halfHeight))
        } else {
            path.move(to: NSPoint(x: rect.maxX - 1, y: centerY - halfHeight))
            path.line(to: NSPoint(x: rect.maxX - insetWidth, y: centerY - halfHeight + 5))
            path.line(to: NSPoint(x: rect.maxX - insetWidth, y: centerY + halfHeight - 5))
            path.line(to: NSPoint(x: rect.maxX - 1, y: centerY + halfHeight))
        }
        path.close()
        color.withAlphaComponent(active ? 0.72 : 0.42).setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.32).setStroke()
        path.lineWidth = 1
        path.stroke()

        let gripX = edge == .left ? rect.minX + insetWidth * 0.56 : rect.maxX - insetWidth * 0.56
        NSColor.white.withAlphaComponent(0.7).setStroke()
        let grip = NSBezierPath()
        grip.move(to: NSPoint(x: gripX, y: centerY - 7))
        grip.line(to: NSPoint(x: gripX, y: centerY + 7))
        grip.lineWidth = 1
        grip.stroke()
    }

    private func drawTrimPreviewLine(_ preview: TrimDragPreview, clipRect: NSRect, color: NSColor) {
        let previewX = x(for: preview.timelineTime)
        let viewport = viewportBounds
        guard previewX >= viewport.minX - 4, previewX <= viewport.maxX + 4 else { return }
        let line = NSBezierPath()
        line.move(to: NSPoint(x: previewX, y: clipRect.minY + 3))
        line.line(to: NSPoint(x: previewX, y: clipRect.maxY - 3))
        line.lineWidth = 1.5
        line.setLineDash([4, 3], count: 2, phase: 0)
        color.withAlphaComponent(0.78).setStroke()
        line.stroke()
    }

    private func drawTrimTooltip(_ preview: TrimDragPreview, clipRect: NSRect, color: NSColor) {
        let title = preview.edge == .left ? "Start" : "End"
        let text = "\(title) \(Timecode.string(preview.timelineTime))\nDuration \(Timecode.string(preview.duration))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.boundingRect(
            with: NSSize(width: 220, height: 42),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        ).size
        let padding = NSSize(width: 8, height: 6)
        let width = ceil(textSize.width + padding.width * 2)
        let height = ceil(textSize.height + padding.height * 2)
        let previewX = x(for: preview.timelineTime)
        let proposedX = preview.edge == .left ? previewX + 10 : previewX - width - 10
        let visible = viewportBounds
        let tooltipX = min(max(proposedX, visible.minX + 6), visible.maxX - width - 6)
        let tooltipY = min(max(clipRect.minY + 6, visible.minY + 6), visible.maxY - height - 6)
        let rect = NSRect(x: tooltipX, y: tooltipY, width: width, height: height)

        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        color.withAlphaComponent(0.72).setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        outline.lineWidth = 1
        outline.stroke()
        text.draw(in: rect.insetBy(dx: padding.width, dy: padding.height - 1), withAttributes: attrs)
    }

    private func fadeGuidePath(startX: CGFloat, width: CGFloat, topY: CGFloat, bottomY: CGFloat, curve: FadeCurve, rising: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        let samples = max(4, min(36, Int(width / 6)))
        for index in 0...samples {
            let fraction = Double(index) / Double(samples)
            let gain = FadeMath.curveGain(progress: rising ? fraction : 1 - fraction, curve: curve)
            let x = startX + CGFloat(fraction) * width
            let y = bottomY - CGFloat(gain) * (bottomY - topY)
            if index == 0 {
                path.move(to: NSPoint(x: x, y: y))
            } else {
                path.line(to: NSPoint(x: x, y: y))
            }
        }
        return path
    }

    private func drawFadeHandles(for clip: Clip, in rect: NSRect) {
        for edge in [TrimEdge.left, TrimEdge.right] {
            let handle = fadeHandleRect(for: clip, edge: edge, in: rect)
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: handle.insetBy(dx: -1, dy: -1)).fill()
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: handle).fill()
        }
    }

    private func drawCrossfades(for track: Track, trackIndex: Int, in renderRect: NSRect) {
        for crossfade in crossfadesByTrackID[track.id] ?? [] {
            let startX = x(for: crossfade.startTime)
            let endX = x(for: crossfade.startTime + crossfade.duration)
            guard endX > startX else { continue }
            let y = trackY(for: trackIndex)
            let laneHeight = height(for: track)
            let topInset: CGFloat = laneHeight < 50 ? 7 : 24
            let bottomInset: CGFloat = laneHeight < 50 ? 7 : 18
            let rect = NSRect(x: startX, y: y + topInset, width: endX - startX, height: max(16, laneHeight - topInset - bottomInset))
            guard rect.intersects(renderRect) else { continue }
            NSColor.systemPurple.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            NSColor.systemPurple.withAlphaComponent(0.85).setStroke()
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            outline.lineWidth = 1.25
            outline.stroke()

            let inPath = NSBezierPath()
            let outPath = NSBezierPath()
            let samples = max(4, min(48, Int(rect.width / 5)))
            for index in 0...samples {
                let progress = Double(index) / Double(samples)
                let x = rect.minX + CGFloat(progress) * rect.width
                let inGain = FadeMath.crossfadeGain(progress: progress, curve: crossfade.curve)
                let outGain = FadeMath.crossfadeGain(progress: 1 - progress, curve: crossfade.curve)
                let inY = rect.maxY - CGFloat(inGain) * rect.height
                let outY = rect.maxY - CGFloat(outGain) * rect.height
                if index == 0 {
                    inPath.move(to: NSPoint(x: x, y: inY))
                    outPath.move(to: NSPoint(x: x, y: outY))
                } else {
                    inPath.line(to: NSPoint(x: x, y: inY))
                    outPath.line(to: NSPoint(x: x, y: outY))
                }
            }
            NSColor.white.withAlphaComponent(0.72).setStroke()
            inPath.lineWidth = 1.3
            outPath.lineWidth = 1.3
            inPath.stroke()
            outPath.stroke()
        }
    }

    private func drawVolumeEnvelope(for clip: Clip, in rect: NSRect, selected: Bool) {
        let envelopeRect = volumeEnvelopeRect(in: rect)
        guard envelopeRect.width > 8, envelopeRect.height > 8 else { return }
        guard selected || !clip.volumeAutomationKeyframes.isEmpty else { return }

        let path = NSBezierPath()
        let sampleTimes = envelopeSampleTimes(for: clip)
        for (index, time) in sampleTimes.enumerated() {
            let point = volumeEnvelopePoint(clip: clip, time: time, gainDB: AutomationMath.volumeAutomationDB(for: clip, atClipTime: time), in: envelopeRect)
            if index == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }
        NSColor.white.withAlphaComponent(clip.volumeAutomationKeyframes.isEmpty ? 0.28 : 0.78).setStroke()
        path.lineWidth = clip.volumeAutomationKeyframes.isEmpty ? 1 : 1.5
        path.stroke()

        for keyframe in clip.volumeAutomationKeyframes {
            let point = volumeEnvelopePoint(clip: clip, time: keyframe.time, gainDB: keyframe.gainDB, in: envelopeRect)
            let keyRect = NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            let isSelected = selectedVolumeKeyframe == VolumeKeyframeSelection(clipID: clip.id, keyframeID: keyframe.id)
            (isSelected ? NSColor.systemYellow : NSColor.white).setFill()
            NSBezierPath(ovalIn: keyRect).fill()
            NSColor.black.withAlphaComponent(0.65).setStroke()
            NSBezierPath(ovalIn: keyRect.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    private func envelopeSampleTimes(for clip: Clip) -> [TimeInterval] {
        var times = [0, clip.duration]
        times.append(contentsOf: clip.volumeAutomationKeyframes.map { min(max(0, $0.time), clip.duration) })
        return Array(Set(times)).sorted()
    }

    private enum PlaceholderWaveformStyle {
        case generating
        case offline
        case failed
    }

    private func drawWaveform(_ waveform: WaveformData, clip: Clip, in rect: NSRect, renderRect: NSRect) {
        guard !waveform.peaks.isEmpty, waveform.duration > 0, rect.width > 1 else {
            drawPlaceholderWaveform(in: rect, style: .failed, renderRect: renderRect)
            return
        }

        let drawRect = rect
            .intersection(renderRect.insetBy(dx: -2, dy: 0))
        guard drawRect.width > 1, drawRect.height > 1 else { return }

        let fullSourceStart = max(0, min(clip.sourceStart, waveform.duration))
        let fullSourceEnd = max(fullSourceStart, min(clip.sourceEnd, waveform.duration))
        let leftFraction = min(1, max(0, Double((drawRect.minX - rect.minX) / max(rect.width, 1))))
        let rightFraction = min(1, max(leftFraction, Double((drawRect.maxX - rect.minX) / max(rect.width, 1))))
        let sourceStart = fullSourceStart + (fullSourceEnd - fullSourceStart) * leftFraction
        let sourceEnd = fullSourceStart + (fullSourceEnd - fullSourceStart) * rightFraction
        guard sourceEnd > sourceStart else {
            drawPlaceholderWaveform(in: rect, style: .failed, renderRect: renderRect)
            return
        }

        let previousAntialias = NSGraphicsContext.current?.shouldAntialias
        NSGraphicsContext.current?.shouldAntialias = true

        struct VisiblePeak {
            let min: Float
            let max: Float
            let amplitude: Float
        }

        let waveformNoiseFloor: Float = 0.0007
        let waveformMaxBoost: Float = 22
        let waveformTargetFill: Float = 0.84

        var visiblePeaks: [VisiblePeak] = []
        let bars = WaveformRenderMetrics.barCount(peakCount: waveform.peaks.count, dirtyWidth: drawRect.width)
        visiblePeaks.reserveCapacity(bars)
        for bar in 0..<bars {
            let leftTime = sourceStart + (sourceEnd - sourceStart) * Double(bar) / Double(bars)
            let rightTime = sourceStart + (sourceEnd - sourceStart) * Double(bar + 1) / Double(bars)
            let startIndex = peakIndex(for: leftTime, waveform: waveform)
            let endIndex = min(waveform.peaks.count - 1, max(startIndex, peakIndex(for: rightTime, waveform: waveform)))
            var minPeak: Float = 1
            var maxPeak: Float = -1

            for index in startIndex...endIndex {
                minPeak = min(minPeak, waveform.peaks[index].min)
                maxPeak = max(maxPeak, waveform.peaks[index].max)
            }

            let amplitude = max(abs(minPeak), abs(maxPeak))
            visiblePeaks.append(VisiblePeak(min: minPeak, max: maxPeak, amplitude: amplitude))
        }

        let referencePeak = waveformReferencePeak(for: waveform, noiseFloor: waveformNoiseFloor)
        let visualScale = min(waveformMaxBoost, max(1, waveformTargetFill / referencePeak))
        let halfHeight = drawRect.height * 0.5
        let usableHalfHeight = halfHeight * 0.92
        let minimumHalfHeight: CGFloat = 2.2

        let path = NSBezierPath()
        let mid = drawRect.midY
        let drawableWidth = max(0, drawRect.width - 1)
        for (bar, peak) in visiblePeaks.enumerated() {
            let fraction = bars > 1 ? CGFloat(bar) / CGFloat(bars - 1) : 0.5
            let x = drawRect.minX + 0.5 + fraction * drawableWidth
            var topOffset = CGFloat(max(0, peak.max) * visualScale) * usableHalfHeight
            var bottomOffset = CGFloat(max(0, -peak.min) * visualScale) * usableHalfHeight
            if peak.amplitude > waveformNoiseFloor {
                topOffset = max(topOffset, minimumHalfHeight)
                bottomOffset = max(bottomOffset, minimumHalfHeight)
            }
            let top = max(rect.minY, mid - min(topOffset, usableHalfHeight))
            let bottom = min(rect.maxY, mid + min(bottomOffset, usableHalfHeight))
            path.move(to: NSPoint(x: x, y: top))
            path.line(to: NSPoint(x: x, y: bottom))
        }

        NSColor(calibratedWhite: 0.95, alpha: 0.72).setStroke()
        path.lineWidth = 1
        path.stroke()
        NSGraphicsContext.current?.shouldAntialias = previousAntialias ?? true
    }

    private func waveformReferencePeak(for waveform: WaveformData, noiseFloor: Float) -> Float {
        if let cached = waveformReferencePeakCache[waveform.cacheKey] {
            return cached
        }
        let reference = WaveformRenderMetrics.referencePeak(
            peaks: waveform.peaks,
            percentile: 0.95,
            noiseFloor: noiseFloor
        )
        waveformReferencePeakCache[waveform.cacheKey] = reference
        return reference
    }

    private func peakIndex(for time: TimeInterval, waveform: WaveformData) -> Int {
        guard waveform.duration > 0, !waveform.peaks.isEmpty else { return 0 }
        let fraction = min(1, max(0, time / waveform.duration))
        return min(waveform.peaks.count - 1, max(0, Int(fraction * Double(waveform.peaks.count - 1))))
    }

    private func drawPlaceholderWaveform(in rect: NSRect, style: PlaceholderWaveformStyle, renderRect: NSRect? = nil) {
        let drawRect = rect
            .intersection(renderRect ?? rect)
        guard !drawRect.isNull, drawRect.width > 1, drawRect.height > 1 else { return }
        let path = NSBezierPath()
        let mid = drawRect.midY
        let bars = max(2, Int(ceil(drawRect.width / 4)) + 1)
        for i in 0..<bars {
            let x = drawRect.minX + CGFloat(i) / CGFloat(bars - 1) * drawRect.width
            let phase = Double(max(0, x - rect.minX) / 4) * 0.75
            let amp = CGFloat((sin(phase) + 1) * 0.35 + 0.15)
            path.move(to: NSPoint(x: x, y: mid - drawRect.height * amp * 0.5))
            path.line(to: NSPoint(x: x, y: mid + drawRect.height * amp * 0.5))
        }
        switch style {
        case .generating:
            NSColor(calibratedWhite: 0.95, alpha: 0.42).setStroke()
        case .offline:
            NSColor(calibratedWhite: 0.85, alpha: 0.35).setStroke()
        case .failed:
            NSColor.systemOrange.withAlphaComponent(0.65).setStroke()
        }
        path.lineWidth = 1
        path.stroke()
    }

    private func drawPlayhead(in renderRect: NSRect) {
        let x = self.x(for: playheadTime)
        guard x >= renderRect.minX - 2 && x <= renderRect.maxX + 2 else { return }
        NSColor.systemRed.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: renderRect.minY))
        path.line(to: NSPoint(x: x, y: renderRect.maxY))
        path.lineWidth = 2
        path.stroke()
    }

    private func drawSnapGuide(in renderRect: NSRect) {
        guard let snapGuideX = snapGuideX else { return }
        guard snapGuideX >= renderRect.minX - 1 && snapGuideX <= renderRect.maxX + 1 else { return }
        NSColor.systemYellow.withAlphaComponent(0.45).setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: snapGuideX, y: max(rulerHeight, renderRect.minY)))
        path.line(to: NSPoint(x: snapGuideX, y: renderRect.maxY))
        path.lineWidth = 1
        path.stroke()
    }

    private func drawMarquee(in renderRect: NSRect) {
        guard let start = marqueeStart, let current = marqueeCurrent else { return }
        let rect = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(start.x - current.x),
            height: abs(start.y - current.y)
        )
        guard rect.intersects(renderRect) else { return }
        NSColor.systemBlue.withAlphaComponent(0.16).setFill()
        rect.intersection(renderRect).fill()
        NSColor.systemBlue.withAlphaComponent(0.8).setStroke()
        NSBezierPath(rect: rect).stroke()
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoverCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        clearTrimHover()
    }

    @objc private func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            guard location.x >= stickyHeaderMaxX else { return }
            pinchZoomState = PinchZoomState(
                initialZoom: project.viewState.zoom,
                anchorTime: time(forX: location.x),
                anchorViewportX: location.x - viewportBounds.minX
            )
        case .changed:
            guard let state = pinchZoomState else { return }
            let zoom = state.initialZoom * exp(Double(gesture.magnification) * 2.2)
            onPinchZoom?(zoom, state.anchorTime, state.anchorViewportX)
        case .ended, .cancelled, .failed:
            pinchZoomState = nil
        default:
            break
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y < rulerHeight {
            if point.x >= stickyHeaderMaxX {
                if let marker = hitMarker(at: point) {
                    onSetPlayhead?(marker.time)
                } else {
                    onSetPlayhead?(time(forX: point.x))
                }
            }
            return
        }
        if isPointInStickyHeader(point) {
            if !handleTrackHeaderClick(at: point, clickCount: event.clickCount),
               let index = trackIndexIfExisting(forY: point.y) {
                trackReorderDrag = TrackReorderDrag(trackID: project.timeline.tracks[index].id, sourceIndex: index, currentIndex: index, startY: point.y)
            }
            return
        }
        if let fadeHit = hitFadeHandle(at: point) {
            selectedVolumeKeyframe = nil
            onSelectClipWithModifiers?(fadeHit.clip.id, false, selectedClipIDs.contains(fadeHit.clip.id))
            if event.clickCount >= 2 {
                onSetClipFade?(fadeHit.clip.id, fadeHit.edge, 0)
                onStatusMessage?(fadeHit.edge == .left ? "Fade in: 0.00s" : "Fade out: 0.00s")
                return
            }
            beginContinuousEdit(fadeHit.edge == .left ? "Fade In" : "Fade Out")
            fadeHandleDrag = FadeHandleDrag(clipID: fadeHit.clip.id, edge: fadeHit.edge, trackIndex: fadeHit.trackIndex)
            return
        }
        if let keyHit = hitVolumeKeyframe(at: point) {
            selectedVolumeKeyframe = VolumeKeyframeSelection(clipID: keyHit.clip.id, keyframeID: keyHit.keyframe.id)
            beginContinuousEdit("Move Volume Keyframe")
            volumeKeyframeDrag = selectedVolumeKeyframe
            onSelectClipWithModifiers?(keyHit.clip.id, false, selectedClipIDs.contains(keyHit.clip.id))
            needsDisplay = true
            return
        }
        guard let hit = hitClip(at: point) else {
            selectedVolumeKeyframe = nil
            marqueeStart = point
            marqueeCurrent = point
            marqueeAddsToSelection = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift)
            if !marqueeAddsToSelection {
                onSelectClip?(nil)
            }
            needsDisplay = true
            return
        }
        let toggling = event.modifierFlags.contains(.command)
        let extending = event.modifierFlags.contains(.shift)
        if !selectedClipIDs.contains(hit.clip.id) || toggling || extending {
            onSelectClipWithModifiers?(hit.clip.id, toggling, extending)
        }
        if tool == .razor {
            onSplitClip?(hit.clip.id, time(forX: point.x))
            return
        }
        let rect = self.rect(for: hit.clip, trackIndex: hit.trackIndex)
        if event.clickCount >= 2, volumeEnvelopeRect(in: rect).insetBy(dx: -2, dy: -4).contains(point) {
            let values = volumeEnvelopeValues(at: point, clip: hit.clip, in: volumeEnvelopeRect(in: rect))
            onAddVolumeKeyframe?(hit.clip.id, values.time, values.gainDB)
            onStatusMessage?("Added volume keyframe")
            return
        }
        let edge: TrimEdge?
        if !hitCrossfadeRegion(at: point),
           let trimHit = hitTrimEdge(at: point),
           trimHit.clip.id == hit.clip.id {
            edge = trimHit.edge
            hoverTrimEdge = TrimEdgeHover(clipID: hit.clip.id, edge: trimHit.edge)
        } else {
            edge = nil
        }
        var dragClipID = hit.clip.id
        if edge == nil, event.modifierFlags.contains(.option) {
            // Begin before duplicating so the duplicate and its drag are one undoable action.
            beginContinuousEdit("Option-Drag Duplicate")
            guard let duplicatedID = onDuplicateSelectionForDrag?(hit.clip.id) else {
                endContinuousEdit()
                return
            }
            dragClipID = duplicatedID
            onStatusMessage?("Duplicating selected clips")
        } else {
            beginContinuousEdit(edge == nil ? "Move Clip" : "Trim Clip")
        }
        dragState = DragState(clipID: dragClipID, offset: point.x - rect.minX, edge: edge)
    }

    override func mouseDragged(with event: NSEvent) {
        if let fadeDrag = fadeHandleDrag,
           let hit = clipAndTrack(forClipID: fadeDrag.clipID) {
            let point = convert(event.locationInWindow, from: nil)
            let duration = fadeDuration(at: point, clip: hit.clip, edge: fadeDrag.edge)
            onSetClipFade?(fadeDrag.clipID, fadeDrag.edge, duration)
            onStatusMessage?(fadeDrag.edge == .left ? "Fade in: \(String(format: "%.2fs", duration))" : "Fade out: \(String(format: "%.2fs", duration))")
            return
        }
        if let keyDrag = volumeKeyframeDrag,
           let hit = clipAndTrack(forClipID: keyDrag.clipID) {
            let point = convert(event.locationInWindow, from: nil)
            let values = volumeEnvelopeValues(at: point, clip: hit.clip, in: volumeEnvelopeRect(in: rect(for: hit.clip, trackIndex: hit.trackIndex)))
            onMoveVolumeKeyframe?(keyDrag.clipID, keyDrag.keyframeID, values.time, values.gainDB)
            onStatusMessage?("Volume keyframe \(String(format: "%.1f dB", values.gainDB))")
            return
        }
        if let trackMixDrag = trackMixDrag {
            let point = convert(event.locationInWindow, from: nil)
            updateTrackMixDrag(trackMixDrag, at: point)
            return
        }
        if var reorder = trackReorderDrag {
            let point = convert(event.locationInWindow, from: nil)
            reorder.hasMoved = reorder.hasMoved || abs(point.y - reorder.startY) > 6
            reorder.currentIndex = trackInsertionIndex(forY: point.y)
            trackReorderDrag = reorder
            needsDisplay = true
            return
        }
        if marqueeStart != nil {
            marqueeCurrent = convert(event.locationInWindow, from: nil)
            needsDisplay = true
            return
        }
        guard let dragState = dragState else { return }
        let point = convert(event.locationInWindow, from: nil)
        let snapped = snap(time(forX: dragState.edge == nil ? point.x - dragState.offset : point.x))
        if let edge = dragState.edge {
            trimCursor(for: edge).set()
            if let hit = clipAndTrack(forClipID: dragState.clipID) {
                let preview = trimPreview(for: hit.clip, edge: edge, timelineTime: snapped)
                trimDragPreview = preview
                hoverTrimEdge = TrimEdgeHover(clipID: dragState.clipID, edge: edge)
            }
            onTrimClip?(dragState.clipID, edge, snapped)
            let label = edge == .left ? "Start" : "End"
            onStatusMessage?("\(label) \(Timecode.string(snapped))")
            needsDisplay = true
        } else {
            trimDragPreview = nil
            onMoveClip?(dragState.clipID, snapped, trackIndex(forY: point.y))
            onStatusMessage?("Moving clip to \(Timecode.string(snapped))")
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let start = marqueeStart, let current = marqueeCurrent {
            let rect = NSRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(start.x - current.x), height: abs(start.y - current.y))
            if rect.width > 3 || rect.height > 3 {
                onSelectClips?(clipIDs(intersecting: rect), marqueeAddsToSelection)
            } else if !marqueeAddsToSelection {
                onSelectClip?(nil)
            }
            marqueeStart = nil
            marqueeCurrent = nil
            needsDisplay = true
        }
        dragState = nil
        trimDragPreview = nil
        fadeHandleDrag = nil
        volumeKeyframeDrag = nil
        snapGuideX = nil
        trackMixDrag = nil
        endContinuousEdit()
        if let reorder = trackReorderDrag {
            if reorder.hasMoved {
                onReorderTrack?(reorder.trackID, reorder.currentIndex)
            }
            trackReorderDrag = nil
            needsDisplay = true
        }
        if let event = NSApp.currentEvent {
            updateHoverCursor(at: convert(event.locationInWindow, from: nil))
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropPreview = nil
        snapGuideX = nil
        needsDisplay = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropPreview = nil
        snapGuideX = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let idString = sender.draggingPasteboard.string(forType: mediaAssetPasteboardType),
              let assetID = UUID(uuidString: idString) else {
            return false
        }
        let point = convert(sender.draggingLocation, from: nil)
        guard point.y >= rulerHeight else { return false }
        let targetTrack = dropTrackIndex(forY: point.y)
        if targetTrack < project.timeline.tracks.count, project.timeline.tracks[targetTrack].isLocked {
            onStatusMessage?("Cannot drop onto locked track")
            dropPreview = nil
            needsDisplay = true
            return false
        }
        onDropAsset?(assetID, dropTime(for: point), targetTrack)
        dropPreview = nil
        snapGuideX = nil
        needsDisplay = true
        return true
    }

    private func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        guard let idString = sender.draggingPasteboard.string(forType: mediaAssetPasteboardType),
              let assetID = UUID(uuidString: idString),
              point.y >= rulerHeight else {
            dropPreview = nil
            needsDisplay = true
            return []
        }
        let requestedIndex = rawDropTrackIndex(forY: point.y)
        let index = dropTrackIndex(forY: point.y)
        let snappedTime = dropTime(for: point)
        let clamped = requestedIndex != index
        if index < project.timeline.tracks.count, project.timeline.tracks[index].isLocked {
            dropPreview = DropPreview(assetID: assetID, time: snappedTime, trackIndex: index, allowed: false, clamped: clamped, isHeaderDrop: isPointInStickyHeader(point))
            onStatusMessage?("Cannot drop onto locked track")
            needsDisplay = true
            return []
        }
        dropPreview = DropPreview(assetID: assetID, time: snappedTime, trackIndex: index, allowed: true, clamped: clamped, isHeaderDrop: isPointInStickyHeader(point))
        needsDisplay = true
        return .copy
    }

    private func hitClip(at point: NSPoint) -> (clip: Clip, trackIndex: Int)? {
        for (trackIndex, track) in project.timeline.tracks.enumerated() {
            for clip in track.clips.reversed() where rect(for: clip, trackIndex: trackIndex).contains(point) {
                return (clip, trackIndex)
            }
        }
        return nil
    }

    private func clipAndTrack(forClipID clipID: UUID) -> (clip: Clip, trackIndex: Int)? {
        for (trackIndex, track) in project.timeline.tracks.enumerated() {
            if let clip = track.clips.first(where: { $0.id == clipID }) {
                return (clip, trackIndex)
            }
        }
        return nil
    }

    private func hitVolumeKeyframe(at point: NSPoint) -> (clip: Clip, trackIndex: Int, keyframe: ClipVolumeAutomationKeyframe)? {
        for (trackIndex, track) in project.timeline.tracks.enumerated() {
            for clip in track.clips.reversed() {
                let clipRect = rect(for: clip, trackIndex: trackIndex)
                guard clipRect.contains(point), clipRect.height >= 36 else { continue }
                let envelopeRect = volumeEnvelopeRect(in: clipRect)
                for keyframe in clip.volumeAutomationKeyframes {
                    let keyPoint = volumeEnvelopePoint(clip: clip, time: keyframe.time, gainDB: keyframe.gainDB, in: envelopeRect)
                    if abs(point.x - keyPoint.x) <= 7 && abs(point.y - keyPoint.y) <= 7 {
                        return (clip, trackIndex, keyframe)
                    }
                }
            }
        }
        return nil
    }

    private func hitFadeHandle(at point: NSPoint) -> (clip: Clip, trackIndex: Int, edge: TrimEdge)? {
        for (trackIndex, track) in project.timeline.tracks.enumerated() {
            for clip in track.clips.reversed() {
                let clipRect = rect(for: clip, trackIndex: trackIndex)
                guard clipRect.contains(point), clipRect.height >= 36 else { continue }
                if fadeHandleRect(for: clip, edge: .left, in: clipRect).insetBy(dx: -5, dy: -5).contains(point) {
                    return (clip, trackIndex, .left)
                }
                if fadeHandleRect(for: clip, edge: .right, in: clipRect).insetBy(dx: -5, dy: -5).contains(point) {
                    return (clip, trackIndex, .right)
                }
            }
        }
        return nil
    }

    private func hitTrimEdge(at point: NSPoint) -> (clip: Clip, trackIndex: Int, edge: TrimEdge)? {
        let trimHitZone: CGFloat = 9
        for (trackIndex, track) in project.timeline.tracks.enumerated() {
            guard !track.isLocked, !track.isCollapsed else { continue }
            for clip in track.clips.reversed() {
                let clipRect = rect(for: clip, trackIndex: trackIndex)
                guard clipRect.contains(point), clipRect.height >= 36 else { continue }
                if abs(point.x - clipRect.minX) <= trimHitZone {
                    return (clip, trackIndex, .left)
                }
                if abs(point.x - clipRect.maxX) <= trimHitZone {
                    return (clip, trackIndex, .right)
                }
            }
        }
        return nil
    }

    private func hitCrossfadeRegion(at point: NSPoint) -> Bool {
        for (trackIndex, track) in project.timeline.tracks.enumerated() {
            for crossfade in crossfadesByTrackID[track.id] ?? [] {
                let startX = x(for: crossfade.startTime)
                let endX = x(for: crossfade.startTime + crossfade.duration)
                let y = trackY(for: trackIndex)
                let laneHeight = height(for: track)
                let topInset: CGFloat = laneHeight < 50 ? 7 : 24
                let bottomInset: CGFloat = laneHeight < 50 ? 7 : 18
                let rect = NSRect(x: startX, y: y + topInset, width: max(1, endX - startX), height: max(16, laneHeight - topInset - bottomInset))
                if rect.contains(point) {
                    return true
                }
            }
        }
        return false
    }

    private func updateHoverCursor(at point: NSPoint) {
        guard fadeHandleDrag == nil, volumeKeyframeDrag == nil, dragState == nil else { return }
        guard !isPointInStickyHeader(point) else {
            clearTrimHover()
            return
        }
        if hitFadeHandle(at: point) != nil || hitVolumeKeyframe(at: point) != nil || hitCrossfadeRegion(at: point) {
            clearTrimHover()
            return
        }
        guard let trimHit = hitTrimEdge(at: point) else {
            clearTrimHover()
            return
        }
        let hover = TrimEdgeHover(clipID: trimHit.clip.id, edge: trimHit.edge)
        if hoverTrimEdge != hover {
            hoverTrimEdge = hover
            needsDisplay = true
        }
        trimCursor(for: trimHit.edge).set()
    }

    private func clearTrimHover() {
        if hoverTrimEdge != nil {
            hoverTrimEdge = nil
            trimDragPreview = nil
            needsDisplay = true
        }
        NSCursor.arrow.set()
    }

    private func trimCursor(for edge: TrimEdge) -> NSCursor {
        NSCursor.resizeLeftRight
    }

    private func clipIDs(intersecting rect: NSRect) -> Set<UUID> {
        var result = Set<UUID>()
        for (trackIndex, track) in project.timeline.tracks.enumerated() {
            for clip in track.clips where rect.intersects(self.rect(for: clip, trackIndex: trackIndex)) {
                result.insert(clip.id)
            }
        }
        return result
    }

    private func hitMarker(at point: NSPoint) -> TimelineMarker? {
        guard point.x >= stickyHeaderMaxX else { return nil }
        return project.timeline.markers.first { marker in
            abs(x(for: marker.time) - point.x) < 7
        }
    }

    @discardableResult
    private func handleTrackHeaderClick(at point: NSPoint, clickCount: Int) -> Bool {
        guard let index = trackIndexIfExisting(forY: point.y) else { return false }
        let track = project.timeline.tracks[index]
        let trackY = trackY(for: index)
        if clickCount >= 2, trackNameRect(y: trackY).contains(point) {
            onRenameTrack?(track.id)
            return true
        }
        if collapseButtonRect(y: trackY).contains(point) {
            onToggleTrackCollapse?(track.id)
            return true
        }
        if buttonRect(index: 0, y: trackY).contains(point) {
            onToggleTrackMute?(track.id)
            return true
        } else if buttonRect(index: 1, y: trackY).contains(point) {
            onToggleTrackSolo?(track.id)
            return true
        } else if buttonRect(index: 2, y: trackY).contains(point) {
            onToggleTrackLock?(track.id)
            return true
        } else if volumeSliderRect(y: trackY).insetBy(dx: -4, dy: -6).contains(point) {
            beginContinuousEdit("Track Volume")
            trackMixDrag = TrackMixDrag(trackID: track.id, trackIndex: index, control: .volume)
            updateTrackMixDrag(trackMixDrag!, at: point)
            return true
        } else if panSliderRect(y: trackY).insetBy(dx: -4, dy: -6).contains(point) {
            beginContinuousEdit("Track Pan")
            trackMixDrag = TrackMixDrag(trackID: track.id, trackIndex: index, control: .pan)
            updateTrackMixDrag(trackMixDrag!, at: point)
            return true
        }
        return false
    }

    private func updateTrackMixDrag(_ drag: TrackMixDrag, at point: NSPoint) {
        let track = project.timeline.tracks[drag.trackIndex]
        guard !track.isLocked else {
            onStatusMessage?("Cannot change mix controls on a locked track")
            return
        }
        switch drag.control {
        case .volume:
            let rect = volumeSliderRect(y: trackY(for: drag.trackIndex))
            let fraction = min(1, max(0, (point.x - rect.minX) / rect.width))
            let db = Double(fraction) * 72 - 60
            onSetTrackVolume?(drag.trackID, db)
            onStatusMessage?("Track volume \(String(format: "%.0f dB", db))")
        case .pan:
            let rect = panSliderRect(y: trackY(for: drag.trackIndex))
            let fraction = min(1, max(0, (point.x - rect.minX) / rect.width))
            let pan = Double(fraction) * 2 - 1
            onSetTrackPan?(drag.trackID, pan)
            onStatusMessage?("Track pan \(String(format: "%+.0f", pan * 100))")
        }
    }

    private func buttonRect(index: Int, y: CGFloat) -> NSRect {
        guard let track = trackAt(y: y) else {
            return NSRect(x: stickyHeaderX + 10 + CGFloat(index) * 34, y: y + 56, width: 27, height: 21)
        }
        guard track.isCollapsed else {
            let laneHeight = height(for: track)
            return NSRect(x: stickyHeaderX + 10 + CGFloat(index) * 34, y: y + min(56, laneHeight - 24), width: 27, height: 21)
        }
        return NSRect(x: stickyHeaderX + 50 + CGFloat(index) * 30, y: y + 8, width: 24, height: 20)
    }

    private func trackNameRect(y: CGFloat) -> NSRect {
        let width: CGFloat = trackAt(y: y)?.isCollapsed == true ? 36 : trackHeaderWidth - 44
        return NSRect(x: stickyHeaderX + 10, y: y + 8, width: width, height: 17)
    }

    private func collapseButtonRect(y: CGFloat) -> NSRect {
        NSRect(x: stickyHeaderX + trackHeaderWidth - 24, y: y + 7, width: 16, height: 16)
    }

    private func volumeSliderRect(y: CGFloat) -> NSRect {
        let compactOffset: CGFloat = (trackAt(y: y).map { height(for: $0) < 82 } ?? false) ? 28 : 32
        return NSRect(x: stickyHeaderX + 26, y: y + compactOffset, width: 66, height: 6)
    }

    private func panSliderRect(y: CGFloat) -> NSRect {
        let compactOffset: CGFloat = (trackAt(y: y).map { height(for: $0) < 82 } ?? false) ? 39 : 45
        return NSRect(x: stickyHeaderX + 26, y: y + compactOffset, width: 66, height: 6)
    }

    private func trackMeterRect(y: CGFloat) -> NSRect {
        guard let track = trackAt(y: y), track.isCollapsed else {
            return NSRect(x: stickyHeaderX + 10, y: y + expandedTrackHeight - 6, width: trackHeaderWidth - 20, height: 4)
        }
        return NSRect(x: stickyHeaderX + 10, y: y + 29, width: trackHeaderWidth - 20, height: 4)
    }

    private func trackIndex(forY y: CGFloat) -> Int {
        trackIndexIfExisting(forY: y) ?? min(max(rawDropTrackIndex(forY: y), 0), max(project.timeline.tracks.count - 1, 0))
    }

    private func dropTime(for point: NSPoint) -> TimeInterval {
        if isPointInStickyHeader(point) {
            return max(0, playheadTime)
        }
        return snap(time(forX: point.x))
    }

    private func trackIndexIfExisting(forY y: CGFloat) -> Int? {
        guard y >= rulerHeight, !project.timeline.tracks.isEmpty else { return nil }
        var currentY = rulerHeight
        for index in project.timeline.tracks.indices {
            let nextY = currentY + heightForTrack(at: index)
            if y >= currentY && y < nextY {
                return index
            }
            currentY = nextY
        }
        return nil
    }

    private func rawDropTrackIndex(forY y: CGFloat) -> Int {
        if let existing = trackIndexIfExisting(forY: y) {
            return existing
        }
        let tracksBottom = trackY(for: project.timeline.tracks.count)
        guard y >= tracksBottom else { return 0 }
        return project.timeline.tracks.count + max(0, Int((y - tracksBottom) / expandedTrackHeight))
    }

    private func dropTrackIndex(forY y: CGFloat) -> Int {
        let existingCount = max(project.timeline.tracks.count, 1)
        let maximumIndex = min(63, existingCount + maxAutoCreatedTracksPerDrop - 1)
        return min(rawDropTrackIndex(forY: y), maximumIndex)
    }

    private func trackInsertionIndex(forY y: CGFloat) -> Int {
        guard y >= rulerHeight else { return 0 }
        for index in project.timeline.tracks.indices {
            let yOrigin = trackY(for: index)
            if y < yOrigin + heightForTrack(at: index) / 2 {
                return index
            }
        }
        return max(0, project.timeline.tracks.count - 1)
    }

    private func trackAt(y: CGFloat) -> Track? {
        guard let index = trackIndexIfExisting(forY: y) else { return nil }
        return project.timeline.tracks[index]
    }

    private func rect(for clip: Clip, trackIndex: Int) -> NSRect {
        let x = self.x(for: clip.timelineStart)
        let width = max(16, CGFloat(clip.duration / secondsPerPoint))
        let laneY = trackY(for: trackIndex)
        let laneHeight = heightForTrack(at: trackIndex)
        let inset: CGFloat = laneHeight < 50 ? 6 : 10
        return NSRect(x: x, y: laneY + inset, width: width, height: max(18, laneHeight - inset * 2))
    }

    private func volumeEnvelopeRect(in clipRect: NSRect) -> NSRect {
        let topInset: CGFloat = clipRect.height < 58 ? 17 : 22
        let bottomInset: CGFloat = clipRect.height < 58 ? 12 : 18
        return NSRect(
            x: clipRect.minX + 8,
            y: clipRect.minY + topInset,
            width: max(1, clipRect.width - 16),
            height: max(1, clipRect.height - topInset - bottomInset)
        )
    }

    private func fadeHandleRect(for clip: Clip, edge: TrimEdge, in clipRect: NSRect) -> NSRect {
        let duration = edge == .left ? clip.fadeIn.duration : clip.fadeOut.duration
        let maxWidth = max(0, clipRect.width - 16)
        let offset = min(maxWidth, CGFloat(max(0, duration) / secondsPerPoint))
        let x = edge == .left ? clipRect.minX + 6 + offset : clipRect.maxX - 6 - offset
        let y = clipRect.minY + 16
        return NSRect(x: x - 4.5, y: y - 4.5, width: 9, height: 9)
    }

    private func fadeDuration(at point: NSPoint, clip: Clip, edge: TrimEdge) -> TimeInterval {
        let raw: TimeInterval
        switch edge {
        case .left:
            raw = time(forX: point.x) - clip.timelineStart
        case .right:
            raw = clip.timelineStart + clip.duration - time(forX: point.x)
        }
        return min(max(0, raw), clip.duration)
    }

    private func trimPreview(for clip: Clip, edge: TrimEdge, timelineTime: TimeInterval) -> TrimDragPreview {
        let duration: TimeInterval
        switch edge {
        case .left:
            duration = clip.timelineStart + clip.duration - timelineTime
        case .right:
            duration = timelineTime - clip.timelineStart
        }
        return TrimDragPreview(
            clipID: clip.id,
            edge: edge,
            timelineTime: max(0, timelineTime),
            duration: max(0, duration),
            isValid: timelineTime >= 0 && duration > 0.001
        )
    }

    private func volumeEnvelopePoint(clip: Clip, time: TimeInterval, gainDB: Double, in envelopeRect: NSRect) -> NSPoint {
        let xFraction = clip.duration > 0 ? min(1, max(0, time / clip.duration)) : 0
        let yFraction = (MixMath.clampClipAutomationDB(gainDB) + 60) / 72
        return NSPoint(
            x: envelopeRect.minX + CGFloat(xFraction) * envelopeRect.width,
            y: envelopeRect.maxY - CGFloat(yFraction) * envelopeRect.height
        )
    }

    private func volumeEnvelopeValues(at point: NSPoint, clip: Clip, in envelopeRect: NSRect) -> (time: TimeInterval, gainDB: Double) {
        let xFraction = min(1, max(0, (point.x - envelopeRect.minX) / max(1, envelopeRect.width)))
        let yFraction = min(1, max(0, (envelopeRect.maxY - point.y) / max(1, envelopeRect.height)))
        return (
            time: Double(xFraction) * clip.duration,
            gainDB: MixMath.clampClipAutomationDB(Double(yFraction) * 72 - 60)
        )
    }

    private func x(for time: TimeInterval) -> CGFloat {
        trackHeaderWidth + CGFloat(time / secondsPerPoint)
    }

    func xPosition(for time: TimeInterval) -> CGFloat {
        x(for: time)
    }

    private func time(forX x: CGFloat) -> TimeInterval {
        max(0, Double(x - trackHeaderWidth) * secondsPerPoint)
    }

    private func snap(_ time: TimeInterval) -> TimeInterval {
        guard project.viewState.snappingEnabled else {
            snapGuideX = nil
            return max(0, time)
        }
        let grid = niceStep() / 4
        var candidates = [(time / grid).rounded() * grid, playheadTime]
        candidates.append(contentsOf: project.timeline.markers.map { $0.time })
        for track in project.timeline.tracks {
            for clip in track.clips {
                candidates.append(clip.timelineStart)
                candidates.append(clip.timelineStart + clip.duration)
            }
        }
        let threshold = secondsPerPoint * 8
        let nearest = candidates.min { abs($0 - time) < abs($1 - time) } ?? time
        if abs(nearest - time) <= threshold {
            snapGuideX = x(for: nearest)
            return max(0, nearest)
        }
        snapGuideX = nil
        return max(0, time)
    }

    private func niceStep() -> TimeInterval {
        let pixelsPerSecond = 1 / secondsPerPoint
        if pixelsPerSecond > 160 { return 0.5 }
        if pixelsPerSecond > 80 { return 1 }
        if pixelsPerSecond > 35 { return 5 }
        if pixelsPerSecond > 12 { return 10 }
        if pixelsPerSecond > 5 { return 30 }
        if pixelsPerSecond > 2 { return 60 }
        if pixelsPerSecond > 0.5 { return 300 }
        if pixelsPerSecond > 0.15 { return 600 }
        if pixelsPerSecond > 0.05 { return 1800 }
        return 7200
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if point.y < rulerHeight, let marker = hitMarker(at: point) {
            let menu = NSMenu()
            menu.addItem(withTitle: "Rename Marker", action: #selector(renameMarkerMenu(_:)), keyEquivalent: "").representedObject = marker.id
            menu.addItem(withTitle: "Delete Marker", action: #selector(deleteMarkerMenu(_:)), keyEquivalent: "").representedObject = marker.id
            menu.items.forEach { $0.target = self }
            return menu
        }
        if isPointInStickyHeader(point), point.y >= rulerHeight {
            let index = trackIndex(forY: point.y)
            guard index < project.timeline.tracks.count else { return nil }
            let track = project.timeline.tracks[index]
            let menu = NSMenu()
            menu.addItem(withTitle: "Rename Track", action: #selector(renameTrackMenu(_:)), keyEquivalent: "").representedObject = track.id
            menu.addItem(withTitle: "Add Track Above", action: #selector(addTrackAboveMenu(_:)), keyEquivalent: "").representedObject = track.id
            menu.addItem(withTitle: "Add Track Below", action: #selector(addTrackBelowMenu(_:)), keyEquivalent: "").representedObject = track.id
            menu.addItem(withTitle: "Duplicate Track", action: #selector(duplicateTrackMenu(_:)), keyEquivalent: "").representedObject = track.id
            menu.addItem(withTitle: "Delete Track", action: #selector(deleteTrackMenu(_:)), keyEquivalent: "").representedObject = track.id
            menu.addItem(withTitle: track.isCollapsed ? "Expand Track" : "Collapse Track", action: #selector(toggleCollapseMenu(_:)), keyEquivalent: "").representedObject = track.id
            menu.addItem(withTitle: "Reset Track Height", action: #selector(resetTrackHeightMenu(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: track.isMuted ? "Unmute" : "Mute", action: #selector(toggleMuteMenu(_:)), keyEquivalent: "").representedObject = track.id
            menu.addItem(withTitle: track.isSolo ? "Unsolo" : "Solo", action: #selector(toggleSoloMenu(_:)), keyEquivalent: "").representedObject = track.id
            menu.addItem(withTitle: track.isLocked ? "Unlock" : "Lock", action: #selector(toggleLockMenu(_:)), keyEquivalent: "").representedObject = track.id
            menu.items.forEach { $0.target = self }
            return menu
        }
        if let hit = hitClip(at: point) {
            onSelectClipWithModifiers?(hit.clip.id, false, selectedClipIDs.contains(hit.clip.id))
            let menu = NSMenu()
            menu.addItem(withTitle: "Source: \(project.asset(id: hit.clip.sourceAssetID)?.displayName ?? "Missing")", action: nil, keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Rename Clip", action: #selector(renameClipMenu(_:)), keyEquivalent: "").representedObject = hit.clip.id
            let colorMenu = NSMenu(title: "Clip Color")
            for color in ClipColorLabel.allCases {
                let item = NSMenuItem(title: color.displayName, action: #selector(setClipColorMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ClipColorMenuPayload(clipID: hit.clip.id, color: color)
                item.state = hit.clip.colorLabel == color ? .on : .off
                colorMenu.addItem(item)
            }
            let colorItem = NSMenuItem(title: "Clip Color", action: nil, keyEquivalent: "")
            colorItem.submenu = colorMenu
            menu.addItem(colorItem)
            menu.addItem(fadeCurveMenu(title: "Fade In Curve", clipID: hit.clip.id, edge: .left, selectedCurve: hit.clip.fadeIn.curve))
            menu.addItem(fadeCurveMenu(title: "Fade Out Curve", clipID: hit.clip.id, edge: .right, selectedCurve: hit.clip.fadeOut.curve))
            menu.addItem(.separator())
            menu.addItem(withTitle: "Add Volume Keyframe at Playhead", action: #selector(addVolumeKeyframeMenu(_:)), keyEquivalent: "").representedObject = hit.clip.id
            let clearAutomation = NSMenuItem(title: "Clear Clip Volume Automation", action: #selector(clearVolumeAutomationMenu(_:)), keyEquivalent: "")
            clearAutomation.representedObject = hit.clip.id
            clearAutomation.isEnabled = !hit.clip.volumeAutomationKeyframes.isEmpty
            menu.addItem(clearAutomation)
            menu.addItem(withTitle: "Normalize Clip...", action: #selector(normalizeClipMenu(_:)), keyEquivalent: "").representedObject = hit.clip.id
            menu.addItem(.separator())
            menu.addItem(withTitle: "Create Crossfade", action: #selector(createCrossfadeMenu(_:)), keyEquivalent: "").representedObject = hit.clip.id
            menu.addItem(crossfadeCurveMenu(clipID: hit.clip.id))
            let removeCrossfades = NSMenuItem(title: "Remove Crossfades", action: #selector(removeCrossfadesMenu(_:)), keyEquivalent: "")
            removeCrossfades.representedObject = hit.clip.id
            removeCrossfades.isEnabled = project.timeline.crossfades.contains { $0.leadingClipID == hit.clip.id || $0.trailingClipID == hit.clip.id }
            menu.addItem(removeCrossfades)
            menu.addItem(.separator())
            menu.addItem(withTitle: "Copy", action: #selector(copyMenu(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Cut", action: #selector(cutMenu(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Duplicate", action: #selector(duplicateMenu(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Delete", action: #selector(deleteMenu(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Ripple Delete", action: #selector(rippleDeleteMenu(_:)), keyEquivalent: "")
            if hit.clip.timelineStart < playheadTime && playheadTime < hit.clip.timelineStart + hit.clip.duration {
                menu.addItem(withTitle: "Split at Playhead", action: #selector(splitAtPlayheadMenu(_:)), keyEquivalent: "").representedObject = hit.clip.id
            }
            menu.items.forEach { $0.target = self }
            return menu
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Add Marker at Playhead", action: #selector(addMarkerMenu(_:)), keyEquivalent: "").target = self
        return menu
    }

    private func fadeCurveMenu(title: String, clipID: UUID, edge: TrimEdge, selectedCurve: FadeCurve) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        for curve in FadeCurve.allCases {
            let item = NSMenuItem(title: curve.displayName, action: #selector(setFadeCurveMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = FadeCurveMenuPayload(clipID: clipID, edge: edge, curve: curve)
            item.state = selectedCurve == curve ? .on : .off
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func crossfadeCurveMenu(clipID: UUID) -> NSMenuItem {
        let hasCrossfade = project.timeline.crossfades.contains { $0.leadingClipID == clipID || $0.trailingClipID == clipID }
        let selectedCurve = project.timeline.crossfades.first { $0.leadingClipID == clipID || $0.trailingClipID == clipID }?.curve
        let submenu = NSMenu(title: "Crossfade Curve")
        for curve in CrossfadeCurve.allCases {
            let item = NSMenuItem(title: curve.displayName, action: #selector(setCrossfadeCurveMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = CrossfadeCurveMenuPayload(clipID: clipID, curve: curve)
            item.state = selectedCurve == curve ? .on : .off
            item.isEnabled = hasCrossfade
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Crossfade Curve", action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.isEnabled = hasCrossfade
        return item
    }

    @objc private func copyMenu(_ sender: NSMenuItem) { onCopy?() }
    @objc private func cutMenu(_ sender: NSMenuItem) { onCut?() }
    @objc private func duplicateMenu(_ sender: NSMenuItem) { onDuplicate?() }
    @objc private func deleteMenu(_ sender: NSMenuItem) { onDelete?() }
    @objc private func rippleDeleteMenu(_ sender: NSMenuItem) { onRippleDelete?() }
    @objc private func addMarkerMenu(_ sender: NSMenuItem) { onAddMarker?() }
    @objc private func splitAtPlayheadMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onSplitClip?(id, playheadTime)
    }
    @objc private func renameClipMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onRenameClip?(id)
    }
    @objc private func setClipColorMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ClipColorMenuPayload else { return }
        onSetClipColor?(payload.clipID, payload.color)
    }
    @objc private func setFadeCurveMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? FadeCurveMenuPayload else { return }
        onSetClipFadeCurve?(payload.clipID, payload.edge, payload.curve)
    }
    @objc private func createCrossfadeMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onCreateCrossfade?(id)
    }
    @objc private func setCrossfadeCurveMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? CrossfadeCurveMenuPayload else { return }
        onSetCrossfadeCurve?(payload.clipID, payload.curve)
    }
    @objc private func removeCrossfadesMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onRemoveCrossfades?(id)
    }
    @objc private func addVolumeKeyframeMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onAddVolumeKeyframeAtPlayhead?(id)
    }
    @objc private func clearVolumeAutomationMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onClearVolumeAutomation?(id)
    }
    @objc private func normalizeClipMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onNormalizeClip?(id)
    }
    @objc private func renameMarkerMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onRenameMarker?(id)
    }
    @objc private func deleteMarkerMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onDeleteMarker?(id)
    }
    @objc private func renameTrackMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onRenameTrack?(id)
    }
    @objc private func addTrackAboveMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else {
            onAddTrack?()
            return
        }
        onAddTrackAbove?(id)
    }
    @objc private func addTrackBelowMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else {
            onAddTrack?()
            return
        }
        onAddTrackBelow?(id)
    }
    @objc private func duplicateTrackMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onDuplicateTrack?(id)
    }
    @objc private func deleteTrackMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onDeleteTrack?(id)
    }
    @objc private func toggleCollapseMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onToggleTrackCollapse?(id)
    }
    @objc private func resetTrackHeightMenu(_ sender: NSMenuItem) {
        onResetTrackHeight?()
    }
    @objc private func toggleMuteMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onToggleTrackMute?(id)
    }
    @objc private func toggleSoloMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onToggleTrackSolo?(id)
    }
    @objc private func toggleLockMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onToggleTrackLock?(id)
    }

}

private struct ClipColorMenuPayload {
    var clipID: UUID
    var color: ClipColorLabel
}

private struct FadeCurveMenuPayload {
    var clipID: UUID
    var edge: TimelineView.TrimEdge
    var curve: FadeCurve
}

private struct CrossfadeCurveMenuPayload {
    var clipID: UUID
    var curve: CrossfadeCurve
}
