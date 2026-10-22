import AppKit

enum EditorAppearance: String, CaseIterable {
    case system, light, dark

    static var preferred: Self {
        get { Self(rawValue: UserDefaults.standard.string(forKey: "EditorAppearance") ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "EditorAppearance") }
    }

    static func apply() {
        switch preferred {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// Resolve custom colors using the drawing view's effective appearance, including
// System Default and the accessibility variants of Aqua and Dark Aqua.
enum EditorColors {
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    private static func gray(light: CGFloat, dark: CGFloat) -> NSColor {
        adaptive(light: NSColor(calibratedWhite: light, alpha: 1),
                 dark: NSColor(calibratedWhite: dark, alpha: 1))
    }

    static let timelineBackground = gray(light: 0.96, dark: 0.11)
    static let rulerBackground = gray(light: 0.92, dark: 0.16)
    static let rulerText = adaptive(light: .secondaryLabelColor, dark: .lightGray)
    static let gridLine = adaptive(light: NSColor(calibratedWhite: 0.78, alpha: 1), dark: .darkGray)
    static let trackBackground = gray(light: 0.985, dark: 0.135)
    static let alternateTrackBackground = gray(light: 0.96, dark: 0.12)
    static let trackSeparator = gray(light: 0.80, dark: 0.24)
    static let trackHeader = gray(light: 0.94, dark: 0.155)
    static let headerBackground = gray(light: 0.92, dark: 0.145)
    static let headerRuler = gray(light: 0.90, dark: 0.13)
    static let headerDivider = gray(light: 0.77, dark: 0.26)
    static let trackButton = gray(light: 0.85, dark: 0.24)
    static let trackButtonText = adaptive(light: .labelColor, dark: .white)
    static let sliderTrack = gray(light: 0.72, dark: 0.26)
    static let meterBackground = gray(light: 0.84, dark: 0.22)
    static let inspectorBackground = adaptive(
        light: NSColor(calibratedWhite: 1, alpha: 0.86),
        dark: NSColor(calibratedWhite: 0.18, alpha: 0.86))
    static let inspectorBorder = adaptive(
        light: NSColor.black.withAlphaComponent(0.10),
        dark: NSColor.white.withAlphaComponent(0.07))

    // Pale clip fills and dark ink keep names, waveforms, and automation legible
    // in Light mode while retaining the existing Dark mode palette.
    static let clipText = gray(light: 0.16, dark: 1)
    static let clipDetail = adaptive(
        light: NSColor(calibratedWhite: 0.22, alpha: 0.85),
        dark: NSColor.white.withAlphaComponent(0.75))
    static let waveform = adaptive(
        light: NSColor(calibratedWhite: 0.20, alpha: 0.80),
        dark: NSColor(calibratedWhite: 0.95, alpha: 0.72))
    static let pendingWaveform = adaptive(
        light: NSColor(calibratedWhite: 0.20, alpha: 0.55),
        dark: NSColor(calibratedWhite: 0.95, alpha: 0.42))
    static let offlineWaveform = adaptive(
        light: NSColor(calibratedWhite: 0.20, alpha: 0.50),
        dark: NSColor(calibratedWhite: 0.85, alpha: 0.35))
    static let selectionAccent = adaptive(light: .systemBlue, dark: .systemYellow)
    static let snapGuide = adaptive(light: NSColor.systemBlue.withAlphaComponent(0.8),
                                    dark: NSColor.systemYellow.withAlphaComponent(0.45))
    static let offlineClip = adaptive(
        light: NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.80, alpha: 1),
        dark: NSColor(calibratedRed: 0.55, green: 0.13, blue: 0.15, alpha: 1))

    private static let clipColors: [ClipColorLabel: NSColor] = [
        .default: adaptive(light: NSColor(calibratedRed: 0.80, green: 0.88, blue: 0.97, alpha: 1),
                           dark: NSColor(calibratedRed: 0.18, green: 0.36, blue: 0.58, alpha: 1)),
        .blue: adaptive(light: NSColor(calibratedRed: 0.78, green: 0.88, blue: 1, alpha: 1),
                        dark: NSColor.systemBlue.withAlphaComponent(0.82)),
        .green: adaptive(light: NSColor(calibratedRed: 0.80, green: 0.93, blue: 0.83, alpha: 1),
                         dark: NSColor.systemGreen.withAlphaComponent(0.74)),
        .purple: adaptive(light: NSColor(calibratedRed: 0.90, green: 0.83, blue: 0.97, alpha: 1),
                          dark: NSColor.systemPurple.withAlphaComponent(0.78)),
        .orange: adaptive(light: NSColor(calibratedRed: 1, green: 0.88, blue: 0.72, alpha: 1),
                          dark: NSColor.systemOrange.withAlphaComponent(0.82)),
        .red: adaptive(light: NSColor(calibratedRed: 0.98, green: 0.81, blue: 0.81, alpha: 1),
                       dark: NSColor.systemRed.withAlphaComponent(0.78)),
        .gray: adaptive(light: NSColor(calibratedWhite: 0.86, alpha: 1),
                        dark: NSColor.systemGray.withAlphaComponent(0.82))
    ]

    static func clipBackground(for label: ClipColorLabel) -> NSColor {
        clipColors[label] ?? clipColors[.default]!
    }
}

class AppearanceAwareView: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// Draw dynamic colors at display time instead of storing a resolved CGColor on
// a layer, which would otherwise retain the old appearance after a theme change.
class EditorSurfaceView: AppearanceAwareView {
    var backgroundColor: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
    var borderColor: NSColor = .clear { didSet { needsDisplay = true } }
    var borderWidth: CGFloat = 0 { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
                                xRadius: cornerRadius, yRadius: cornerRadius)
        backgroundColor.setFill()
        path.fill()
        if borderWidth > 0 {
            borderColor.setStroke()
            path.lineWidth = borderWidth
            path.stroke()
        }
    }
}
