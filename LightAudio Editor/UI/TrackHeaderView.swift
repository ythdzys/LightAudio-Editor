import AppKit

final class TrackHeaderView: NSView {
    var track: Track? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.14, alpha: 1).setFill()
        bounds.fill()
        guard let track = track else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]
        track.name.draw(in: bounds.insetBy(dx: 8, dy: 8), withAttributes: attrs)
    }
}
