import AppKit
import XCTest
@testable import LightAudio_Editor

final class AppearanceTests: XCTestCase {
    func testOpenEditorSurfacesRedrawWhenSwitchingAppearance() throws {
        let previousPreference = UserDefaults.standard.object(forKey: "EditorAppearance")
        let previousAppearance = NSApp.appearance
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 780),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            UserDefaults.standard.set(previousPreference, forKey: "EditorAppearance")
            NSApp.appearance = previousAppearance
        }

        let root = EditorSurfaceView(frame: NSRect(x: 0, y: 0, width: 1000, height: 780))
        window.contentView = root
        let timeline = TimelineView(frame: NSRect(x: 0, y: 400, width: 1000, height: 380))
        let project = previewProject()
        timeline.project = project
        timeline.selectedClipID = project.timeline.tracks[1].clips[0].id
        timeline.waveforms[project.assets[0].id] = WaveformData(
            cacheKey: "appearance-preview", duration: 10, sampleRate: 44100, channelCount: 1,
            peaks: (0..<1000).map { index in
                let amplitude = Float(0.15 + 0.6 * abs(sin(Double(index) * 0.031)))
                return WaveformPeak(min: -amplitude, max: amplitude)
            }, createdAt: Date())
        root.addSubview(timeline)
        let inspector = InspectorViewController()
        inspector.view.frame = NSRect(x: 0, y: 26, width: 1000, height: 374)
        root.addSubview(inspector.view)
        inspector.update(project: project, selectedClipID: timeline.selectedClipID)
        let status = EditorSurfaceView(frame: NSRect(x: 0, y: 0, width: 1000, height: 26))
        root.addSubview(status)
        let meter = LevelMeterView(frame: NSRect(x: 850, y: 6, width: 100, height: 14))
        status.addSubview(meter)
        let preferences = PreferencesWindowController { _ in XCTFail("Appearance must not clear caches") }
        defer { preferences.close() }
        let preferencesContent = try XCTUnwrap(preferences.window?.contentView)
        let control = try XCTUnwrap(descendants(preferencesContent).compactMap { $0 as? NSSegmentedControl }
            .first { $0.identifier?.rawValue == "editorAppearance" })

        // Start from a known appearance so every iteration is a real change,
        // regardless of the user's saved preference when the test host starts.
        EditorAppearance.preferred = .light
        EditorAppearance.apply()
        for preference in [EditorAppearance.dark, .light, .dark, .light] {
            timeline.needsDisplay = false
            meter.needsDisplay = false
            control.selectedSegment = try XCTUnwrap(EditorAppearance.allCases.firstIndex(of: preference))
            control.sendAction(control.action, to: control.target)
            XCTAssertEqual(EditorAppearance.preferred, preference)
            XCTAssertTrue(timeline.needsDisplay, "An existing timeline must redraw immediately")
            XCTAssertTrue(meter.needsDisplay, "An idle meter must redraw without waiting for playback")
            root.layoutSubtreeIfNeeded()

            let isLight = preference == .light
            let bitmap = try render(timeline)
            // Sample chrome, both alternating lanes, and the unused timeline area.
            for point in [NSPoint(x: 20, y: 12), NSPoint(x: 5, y: 80),
                          NSPoint(x: 980, y: 50), NSPoint(x: 980, y: 150), NSPoint(x: 980, y: 350)] {
                try assertBrightness(bitmap, at: point, viewSize: timeline.bounds.size, isLight: isLight)
            }
            try assertBrightness(render(meter), at: NSPoint(x: 50, y: 7), viewSize: meter.bounds.size, isLight: isLight)
            try assertBrightness(render(status), at: NSPoint(x: 20, y: 12), viewSize: status.bounds.size, isLight: isLight)
            let sections = descendants(inspector.view).compactMap { $0 as? EditorSurfaceView }
            XCTAssertFalse(sections.isEmpty)
            for section in sections {
                try assertBrightness(render(section), at: NSPoint(x: section.bounds.width - 12, y: 6),
                                     viewSize: section.bounds.size, isLight: isLight)
            }
            let snapshot = try render(root)
            let image = NSImage(size: root.bounds.size)
            image.addRepresentation(snapshot)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Editor-\(preference.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
            preferences.window?.layoutIfNeeded()
            let preferencesFrame = preferencesContent.superview ?? preferencesContent
            let preferencesImage = NSImage(size: preferencesFrame.bounds.size)
            preferencesImage.addRepresentation(try render(preferencesFrame))
            let preferencesAttachment = XCTAttachment(image: preferencesImage)
            preferencesAttachment.name = "Preferences-\(preference.rawValue)"
            preferencesAttachment.lifetime = .keepAlways
            add(preferencesAttachment)
        }
        control.selectedSegment = 0
        control.sendAction(control.action, to: control.target)
        XCTAssertNil(NSApp.appearance, "System Default must clear the app override")
        XCTAssertEqual(timeline.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
                       NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
    }

    func testLightClipLabelsHaveReadableContrastForEveryColor() throws {
        let previous = NSAppearance.current
        NSAppearance.current = try XCTUnwrap(NSAppearance(named: .aqua))
        defer { NSAppearance.current = previous }
        let ink = try XCTUnwrap(EditorColors.clipText.usingColorSpace(.sRGB))
        for label in ClipColorLabel.allCases {
            let fill = try XCTUnwrap(EditorColors.clipBackground(for: label).usingColorSpace(.sRGB))
            XCTAssertGreaterThanOrEqual((luminance(fill) + 0.05) / (luminance(ink) + 0.05), 4.5,
                                        "\(label) clip labels must remain readable")
        }
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func assertBrightness(_ bitmap: NSBitmapImageRep, at point: NSPoint, viewSize: NSSize,
                                  isLight: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let x = Int(point.x * CGFloat(bitmap.pixelsWide) / viewSize.width)
        let y = Int(point.y * CGFloat(bitmap.pixelsHigh) / viewSize.height)
        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), file: file, line: line)
        let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
        if isLight {
            XCTAssertGreaterThan(brightness, 0.75, "Light surface at \(point)", file: file, line: line)
        } else {
            XCTAssertLessThan(brightness, 0.4, "Dark surface at \(point)", file: file, line: line)
        }
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func previewProject() -> Project {
        let asset = MediaAsset(displayName: "Preview", originalPath: "/tmp/appearance-preview.wav", relativePath: nil,
                               kind: .audio, metadata: MediaFileMetadata(fileName: "Preview.wav", duration: 10,
                                   sampleRate: 44100, channelCount: 1), waveformCacheKey: "appearance-preview")
        var project = Project.empty(name: "Appearance preview")
        project.assets = [asset]
        project.viewState.zoom = 80
        project.viewState.trackHeight = 100
        let clips = ClipColorLabel.allCases.enumerated().map { index, color -> Clip in
            var clip = Clip(sourceAssetID: asset.id, timelineStart: 0.5 + Double(index) * 1.25, sourceStart: 0, sourceEnd: 1)
            clip.colorLabel = color
            clip.customName = color.rawValue.capitalized
            return clip
        }
        var selected = Clip(sourceAssetID: asset.id, timelineStart: 1, sourceStart: 0, sourceEnd: 5)
        selected.customName = "Fade and automation"
        selected.fadeIn.duration = 0.8
        selected.fadeOut.duration = 1
        project.timeline.tracks = [Track(name: "Color labels", clips: clips),
                                   Track(name: "Dialogue", clips: [selected]),
                                   Track(name: "Muted track", isMuted: true, isCollapsed: true)]
        project.recalculateDuration()
        return project
    }
}
