import AppKit

/// Scripted behaviour checks that need AppKit (windows, pasteboard, rendering) and so can't live in SnapCore's tests.
/// Each check prints PASS/FAIL lines and the process exits non-zero if any expectation failed.
///
///   Snap --check <name|all> [output-directory]
enum FeatureChecks {
    @MainActor private static var failures = 0
    @MainActor static var outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snap-checks")

    @MainActor static func expect(_ condition: Bool, _ message: String) {
        print(condition ? "PASS  \(message)" : "FAIL  \(message)")
        if !condition { failures += 1 }
    }

    @MainActor static let checks: [(String, @MainActor () async -> Void)] = [
        ("pins-hide", pinsHide),
        ("pin-keys", pinKeys),
        ("pin-clipboard", pinClipboard),
        ("countdown", countdown),
        ("highlighter", highlighter),
        ("eraser", eraser),
        ("polyline", polyline),
    ]

    @MainActor
    static func run(_ name: String, output: URL?) async -> Int32 {
        if let output { outputDirectory = output }
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let selected = name == "all" ? checks : checks.filter { $0.0 == name }
        guard !selected.isEmpty else {
            print("unknown check \(name); available: \(checks.map(\.0).joined(separator: ", "))")
            return 2
        }
        for (checkName, body) in selected {
            print("== \(checkName)")
            await body()
        }
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }

    /// A small solid-color image, `size` in points at 2x.
    static func sampleRep(_ size: CGSize = CGSize(width: 120, height: 80), color: NSColor = .systemTeal) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        CGRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    @MainActor static func write(_ rep: NSBitmapImageRep, _ name: String) {
        try? rep.representation(using: .png, properties: [:])?.write(to: outputDirectory.appendingPathComponent(name))
    }

    // MARK: - Checks

    @MainActor static func pinsHide() async {
        let manager = PinManager.shared
        let a = manager.pin(sampleRep(), frame: CGRect(x: -4000, y: -4000, width: 120, height: 80))
        let b = manager.pin(sampleRep(), frame: CGRect(x: -3800, y: -4000, width: 120, height: 80))
        expect(a.isVisible && b.isVisible, "new pins are visible")
        manager.toggleHidden()
        expect(manager.isHidingAll && !a.isVisible && !b.isVisible, "toggle hides every pin")
        expect(!manager.hasHistory, "hidden pins are not moved to the restore history")
        manager.toggleHidden()
        expect(!manager.isHidingAll && a.isVisible && b.isVisible, "toggle again shows them")
        manager.toggleHidden()
        let c = manager.pin(sampleRep(), frame: CGRect(x: -3600, y: -4000, width: 120, height: 80))
        expect(!manager.isHidingAll && a.isVisible && c.isVisible, "a new pin while hidden brings the others back")
        manager.closeAll()
        expect(!manager.hasPins, "close all empties the list")
    }

    @MainActor static func key(_ window: NSWindow, _ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        window.keyDown(with: event)
    }

    @MainActor static func pinKeys() async {
        let manager = PinManager.shared
        let pin = manager.pin(sampleRep(CGSize(width: 120, height: 80)), frame: CGRect(x: -4000, y: -4000, width: 120, height: 80))
        key(pin, "1", code: 18)
        expect(pin.rep.size == CGSize(width: 80, height: 120), "1 rotates clockwise (size \(pin.rep.size))")
        key(pin, "2", code: 19)
        expect(pin.rep.size == CGSize(width: 120, height: 80), "2 rotates back")
        key(pin, "=", code: 24)
        expect(abs(pin.zoom - 1.1) < 0.001, "= zooms in (zoom \(pin.zoom))")
        key(pin, "-", code: 27)
        expect(abs(pin.zoom - 1) < 0.001, "- zooms out")
        let before = manager.hasHistory
        key(pin, "\u{1b}", code: 53, flags: .shift)
        expect(!manager.pins.contains { $0 === pin }, "⇧Esc closes the pin")
        expect(manager.hasHistory == before, "⇧Esc does not keep it for restore")
    }

    @MainActor static func pinClipboard() async {
        let manager = PinManager.shared
        let pb = NSPasteboard(name: NSPasteboard.Name("app.snap.check"))
        func pinned(_ fill: () -> Void) -> [PinWindow] {
            pb.clearContents()
            fill()
            let before = manager.pins.count
            manager.pinClipboard(pb)
            return Array(manager.pins.dropFirst(before))
        }
        func pixel(_ pin: PinWindow, _ x: Int, _ y: Int) -> NSColor? { pin.rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) }

        let color = pinned { pb.setString("#FF8000", forType: .string) }
        expect(color.count == 1 && color[0].sourceText == "#FF8000", "hex text becomes a color card")
        if let c = color.first.flatMap({ pixel($0, 20, 20) }) {
            expect(abs(c.redComponent - 1) < 0.02 && abs(c.greenComponent - 0.5) < 0.02 && c.blueComponent < 0.02, "card swatch is the color (\(c))")
        }
        color.first.map { write($0.rep, "pin-color.png") }

        let code = "func add(a: Int) -> Int {\n    return a + 1\n}"
        let text = pinned { pb.setString(code, forType: .string) }
        expect(text.count == 1 && text[0].sourceText == code, "plain text becomes a text pin that keeps its text")
        if let t = text.first {
            expect(t.rep.size.width > 100 && t.rep.size.width <= ClipboardPinSource.maxTextWidth + 24, "text pin wraps within the max width (\(t.rep.size))")
            let corner = pixel(t, 2, 2)
            expect(corner.map { $0.redComponent > 0.98 && $0.greenComponent > 0.98 } ?? false, "text pin has a white card background")
            write(t.rep, "pin-code.png")
        }

        let long = String(repeating: "中文段落会按宽度换行，不会无限拉长。", count: 30)
        if let p = pinned({ pb.setString(long, forType: .string) }).first {
            expect(p.rep.size.width <= ClipboardPinSource.maxTextWidth + 24 && p.rep.size.height > 100, "long prose wraps (\(p.rep.size))")
            write(p.rep, "pin-prose.png")
        }

        let html = pinned { pb.setString("<b>Bold</b> and <i>italic</i> <span style='color:red'>red</span>", forType: .html); pb.setString("Bold and italic red", forType: .string) }
        expect(html.count == 1 && html[0].sourceText == "Bold and italic red", "HTML is rendered and keeps the plain text")
        html.first.map { write($0.rep, "pin-html.png") }

        let dir = outputDirectory.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.png"), b = dir.appendingPathComponent("b.png"), txt = dir.appendingPathComponent("notes.txt")
        try? sampleRep(color: .systemRed).representation(using: .png, properties: [:])?.write(to: a)
        try? sampleRep(color: .systemBlue).representation(using: .png, properties: [:])?.write(to: b)
        try? "hello".write(to: txt, atomically: true, encoding: .utf8)
        let images = pinned { pb.writeObjects([a as NSURL, b as NSURL]) }
        expect(images.count == 2, "two copied image files become two pins")
        let paths = pinned { pb.writeObjects([txt as NSURL]) }
        expect(paths.count == 1 && paths[0].sourceText == txt.path, "a non-image file pins its path as text")

        let empty = pinned { }
        expect(empty.isEmpty, "empty clipboard pins nothing")
        manager.closeAll()
    }

    @MainActor static func countdown() async {
        let countdown = Countdown()
        var ticks: [Int] = []
        var fired = false
        let started = Date()
        countdown.start(seconds: 2, tick: { ticks.append($0) }, fire: { fired = true })
        expect(countdown.isRunning && ticks == [2], "starts at the full count")
        while !fired, Date().timeIntervalSince(started) < 4 { try? await Task.sleep(for: .milliseconds(50)) }
        let elapsed = Date().timeIntervalSince(started)
        expect(fired && ticks == [2, 1], "ticks down and fires (ticks \(ticks))")
        expect(elapsed > 1.8 && elapsed < 2.6, "fires after about 2 s (\(String(format: "%.2f", elapsed)) s)")
        expect(!countdown.isRunning, "stops after firing")

        fired = false
        countdown.start(seconds: 1, tick: { _ in }, fire: { fired = true })
        countdown.cancel()
        try? await Task.sleep(for: .milliseconds(1300))
        expect(!fired, "cancel prevents firing")
    }

    @MainActor static func highlighter() async {
        let h = CaptureHarness()
        h.select(CGRect(x: 40, y: 40, width: 600, height: 360))
        h.key("h", code: 4)
        StyleMemory.color = StyleState.palette[2] // yellow
        // Across the first text line, then a straight ⇧ stroke that ends off-axis and should snap to horizontal.
        h.drag(CGPoint(x: 80, y: 88), CGPoint(x: 400, y: 90))
        h.drag(CGPoint(x: 80, y: 150), CGPoint(x: 400, y: 158), flags: .shift)
        // A red rectangle first, then a marker across it: the rectangle must survive under the marker.
        h.key("r", code: 15)
        StyleMemory.color = StyleState.palette[0]
        h.drag(CGPoint(x: 450, y: 180), CGPoint(x: 520, y: 240))
        h.key("h", code: 4)
        StyleMemory.color = StyleState.palette[2]
        h.drag(CGPoint(x: 420, y: 180), CGPoint(x: 560, y: 180))
        guard let rep = h.export() else { return expect(false, "export") }
        write(rep, "highlighter.png")
        // Export is relative to the selection origin (40, 40).
        func out(_ x: CGFloat, _ y: CGFloat) -> NSColor? { rep.color(atPoint: CGPoint(x: x - 40, y: y - 40)) }
        let white = out(560, 130)!, marked = out(300, 90)!
        expect(white.blueComponent > 0.95, "outside the stroke stays white")
        expect(marked.blueComponent < 0.6 && marked.redComponent > 0.85 && marked.greenComponent > 0.7, "white paper under the stroke turns yellow (\(marked))")
        let straight = out(380, 150)!, offLine = out(380, 158 + 12)!
        expect(straight.blueComponent < 0.6, "⇧ stroke stays on the starting row")
        expect(offLine.blueComponent > 0.9, "⇧ stroke does not follow the mouse off the row")
        // Multiply keeps dark pixels dark: the glyph ink must not turn yellow-bright.
        let darkBand = out(300, 330)!
        expect(darkBand.redComponent < 0.3, "dark background stays dark under a marker (multiply)")
        let underMarker = out(485, 180)!
        expect(underMarker.redComponent > 0.8 && underMarker.greenComponent < 0.4, "an annotation under the marker is kept (\(underMarker))")
        if let screen = h.screenshot() {
            write(screen, "highlighter-overlay.png")
            let onScreen = screen.color(atPoint: CGPoint(x: 485, y: 180))!, exported = underMarker
            expect(abs(onScreen.redComponent - exported.redComponent) < 0.08 && abs(onScreen.greenComponent - exported.greenComponent) < 0.08,
                   "on-screen overlay matches the export (\(onScreen) vs \(exported))")
        }
    }

    @MainActor static func eraser() async {
        let h = CaptureHarness()
        h.select(CGRect(x: 40, y: 40, width: 600, height: 360))
        StyleMemory.color = StyleState.palette[0]
        h.key("r", code: 15)
        h.drag(CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 250))
        h.key("e", code: 14)
        StyleMemory.eraserMode = .brush
        // Brush across the top edge of the rectangle.
        h.drag(CGPoint(x: 150, y: 100), CGPoint(x: 350, y: 100))
        // Box over the bottom-right corner.
        StyleMemory.eraserMode = .rect
        h.drag(CGPoint(x: 360, y: 220), CGPoint(x: 420, y: 270))
        guard let rep = h.export() else { return expect(false, "export") }
        write(rep, "eraser.png")
        func out(_ x: CGFloat, _ y: CGFloat) -> NSColor { rep.color(atPoint: CGPoint(x: x - 40, y: y - 40))! }
        func same(_ a: NSColor, _ b: NSColor) -> Bool {
            abs(a.redComponent - b.redComponent) < 0.03 && abs(a.greenComponent - b.greenComponent) < 0.03 && abs(a.blueComponent - b.blueComponent) < 0.03
        }
        let keptEdge = out(100, 175)
        expect(keptEdge.redComponent > 0.8 && keptEdge.greenComponent < 0.4, "left edge outside the eraser stays red")
        expect(same(out(250, 100), h.original(CGPoint(x: 250, y: 100))!), "brush restores the original pixels on the top edge")
        expect(same(out(400, 240), h.original(CGPoint(x: 400, y: 240))!), "box restores the original pixels at the corner")
        let items = h.view.testing_items
        expect(items.filter { $0.tool == .eraser }.count == 2, "both eraser strokes are annotations (undoable, movable)")
        h.key("z", code: 6, flags: .command)
        h.key("z", code: 6, flags: .command)
        let undone = h.export()!.color(atPoint: CGPoint(x: 250 - 40, y: 100 - 40))!
        expect(undone.redComponent > 0.8 && undone.greenComponent < 0.4, "undo brings the erased edge back")
        h.screenshot().map { write($0, "eraser-overlay.png") }
    }

    @MainActor static func polyline() async {
        let h = CaptureHarness()
        h.select(CGRect(x: 40, y: 40, width: 600, height: 360))
        StyleMemory.color = StyleState.palette[4]
        h.key("l", code: 37)
        h.click(CGPoint(x: 100, y: 100))
        h.click(CGPoint(x: 300, y: 100))
        h.click(CGPoint(x: 300, y: 250))
        h.click(CGPoint(x: 450, y: 250))
        h.click(CGPoint(x: 450, y: 250), clicks: 2)
        var items = h.view.testing_items
        if case let .polyline(points, arrow) = items.last?.shape {
            expect(points.count == 4 && !arrow, "clicks make a 4-corner polyline, double-click ends it (\(points.count) corners)")
        } else {
            expect(false, "clicks make a polyline (got \(String(describing: items.last?.shape)))")
        }

        h.key("a", code: 0)
        h.click(CGPoint(x: 120, y: 330))
        h.click(CGPoint(x: 250, y: 300))
        h.click(CGPoint(x: 400, y: 340))
        h.key("\r", code: 36)
        items = h.view.testing_items
        if case let .polyline(points, arrow) = items.last?.shape {
            expect(points.count == 3 && arrow, "arrow tool clicks make a polyline arrow, Return ends it")
        } else {
            expect(false, "arrow polyline")
        }

        h.key("l", code: 37)
        h.drag(CGPoint(x: 500, y: 120), CGPoint(x: 600, y: 180))
        if case .line = h.view.testing_items.last?.shape {
            expect(true, "dragging still draws a single line")
        } else {
            expect(false, "dragging still draws a single line")
        }

        guard let rep = h.export() else { return expect(false, "export") }
        write(rep, "polyline.png")
        func out(_ x: CGFloat, _ y: CGFloat) -> NSColor { rep.color(atPoint: CGPoint(x: x - 40, y: y - 40))! }
        func isBlue(_ c: NSColor) -> Bool { c.blueComponent > 0.8 && c.redComponent < 0.35 }
        expect(isBlue(out(200, 100)) && isBlue(out(300, 180)) && isBlue(out(380, 250)), "all three segments are drawn")
        expect(isBlue(out(398, 339)), "arrow head is drawn at the last corner")

        // Drag the second corner of the first polyline down by 30.
        h.key("\u{1b}", code: 53)
        h.key("\u{1b}", code: 53)
        h.click(CGPoint(x: 200, y: 100))
        h.drag(CGPoint(x: 300, y: 100), CGPoint(x: 300, y: 130))
        if case let .polyline(points, _) = h.view.testing_items.first?.shape {
            expect(abs(points[1].y - 130) < 0.5, "a corner handle moves just that corner (y \(points[1].y))")
        }
        h.screenshot().map { write($0, "polyline-overlay.png") }
    }
}
