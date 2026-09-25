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
}
