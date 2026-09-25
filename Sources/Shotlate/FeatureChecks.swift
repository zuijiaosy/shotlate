import AppKit
import Carbon.HIToolbox
import CoreImage
import ShotlateCore
import SwiftUI

/// Scripted behaviour checks that need AppKit (windows, pasteboard, rendering) and so can't live in ShotlateCore's tests.
/// Each check prints PASS/FAIL lines and the process exits non-zero if any expectation failed.
///
///   Shotlate --check <name|all> [output-directory]
enum FeatureChecks {
    @MainActor private static var failures = 0
    @MainActor static var outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shotlate-checks")

    @MainActor static func expect(_ condition: Bool, _ message: String) {
        print(condition ? "PASS  \(message)" : "FAIL  \(message)")
        if !condition { failures += 1 }
    }

    @MainActor static let checks: [(String, @MainActor () async -> Void)] = [
        ("pins-hide", pinsHide),
        ("pin-keys", pinKeys),
        ("pin-clipboard", pinClipboard),
        ("countdown", countdown),
        ("tool-colors", toolColors),
        ("item-styles", itemStyles),
        ("scan-code", scanCode),
        ("pin-annotate", pinAnnotate),
        ("hotkeys", hotkeys),
        ("magnifier", magnifierTool),
        ("loupe", loupe),
        ("pin-translate", pinTranslate),
        ("pin-text", pinText),
        ("toolbar-placement", toolbarPlacement),
        ("toolbar-keys", toolbarKeys),
        ("ocr", ocr),
        ("secret-file", secretFile),
    ]

    @MainActor
    static func run(_ name: String, output: URL?) async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        // Start from default preferences so one run's choices (colors, dashes, ratios) can't leak into the next.
        // Only when running unbundled from .build: then the domain is the executable's, never the app's.
        if Bundle.main.bundleIdentifier == nil {
            UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
        }
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
        key(pin, "=", code: 24)
        expect(abs(pin.zoom - 1.1) < 0.001, "= zooms in (zoom \(pin.zoom))")
        key(pin, "-", code: 27)
        expect(abs(pin.zoom - 1) < 0.001, "- zooms out")
        key(pin, "0", code: 29)
        pin.setZoom(2)
        key(pin, "0", code: 29)
        expect(abs(pin.zoom - 1) < 0.001, "0 goes back to 100%")
        key(pin, "\u{1b}", code: 53)
        expect(!manager.pins.contains { $0 === pin }, "Esc closes the pin")
    }

    @MainActor static func pinClipboard() async {
        let manager = PinManager.shared
        let pb = NSPasteboard(name: NSPasteboard.Name("app.shotlate.check"))
        func pinned(_ fill: () -> Void) -> [PinWindow] {
            pb.clearContents()
            fill()
            let before = manager.pins.count
            manager.pinClipboard(pb)
            return Array(manager.pins.dropFirst(before))
        }
        func pixel(_ pin: PinWindow, _ x: Int, _ y: Int) -> NSColor? { pin.rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) }

        let dir = outputDirectory.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.png"), b = dir.appendingPathComponent("b.png"), txt = dir.appendingPathComponent("notes.txt")
        try? sampleRep(color: .systemRed).representation(using: .png, properties: [:])?.write(to: a)
        try? sampleRep(color: .systemBlue).representation(using: .png, properties: [:])?.write(to: b)
        try? "hello".write(to: txt, atomically: true, encoding: .utf8)
        let images = pinned { pb.writeObjects([a as NSURL, b as NSURL]) }
        expect(images.count == 2, "two copied image files become two pins")
        if let c = images.first.flatMap({ pixel($0, 20, 20) }) {
            expect(c.redComponent > 0.8 && c.blueComponent < 0.4, "the pin shows the file's image (\(c))")
        }
        let picture = NSImage(size: CGSize(width: 60, height: 40))
        picture.addRepresentation(sampleRep(CGSize(width: 60, height: 40)))
        let bitmap = pinned { pb.writeObjects([picture]) }
        expect(bitmap.count == 1 && bitmap[0].rep.size == CGSize(width: 60, height: 40), "copied image data becomes a pin")
        let text = pinned { pb.setString("#FF8000", forType: .string) }
        expect(text.isEmpty, "text is not pinned")
        let paths = pinned { pb.writeObjects([txt as NSURL]) }
        expect(paths.isEmpty, "a non-image file is not pinned")

        let empty = pinned { }
        expect(empty.isEmpty, "empty clipboard pins nothing")
        manager.closeAll()
    }

    @MainActor static func toolbarPlacement() async {
        func chrome(_ h: CaptureHarness) -> (ToolbarView, StyleBarView) {
            (h.view.subviews.compactMap { $0 as? ToolbarView }.first!, h.view.subviews.compactMap { $0 as? StyleBarView }.first!)
        }
        let size = CGSize(width: 1200, height: 860)

        var h = CaptureHarness(size: size)
        h.select(CGRect(x: 100, y: 100, width: 600, height: 300))
        var (bar, style) = chrome(h)
        expect(!bar.isVertical && bar.frame.minY >= 400, "room below: the toolbar is a row under the selection")
        let card = bar.hoverCard
        expect(card.isHidden, "no hover card until the pointer is on a button")
        bar.toolButtons[.mosaic]?.onHover?(true)
        let mosaic = bar.toolButtons[.mosaic]!.convert(bar.toolButtons[.mosaic]!.bounds, to: h.view)
        expect(!card.isHidden && card.frame.maxY <= bar.frame.minY && abs(card.frame.midX - mosaic.midX) < 1,
               "hovering a button shows its card above it (\(card.frame))")
        h.screenshot().map { write($0, "toolbar-hover.png") }
        bar.toolButtons[.mosaic]?.onHover?(false)
        expect(!card.isHidden, "leaving the button leaves time to reach the card")
        try? await Task.sleep(for: .milliseconds(600))
        expect(card.isHidden, "and then hides it")

        h = CaptureHarness(size: size)
        let low = CGRect(x: 100, y: 300, width: 700, height: 540)
        h.select(low)
        h.key("1", code: 18)
        (bar, style) = chrome(h)
        expect(bar.isVertical && bar.frame.minX == low.maxX + 8, "no room below: a column against the right edge (\(bar.frame))")
        expect(bar.frame.maxY <= size.height - 4 && bar.frame.minY >= 4, "the column stays on screen")
        let icon = bar.anchor(for: .rectangle)!.y + bar.frame.minY
        expect(!style.isHidden && style.frame.maxX <= bar.frame.minX && abs(style.frame.midY - icon) < 2,
               "the style bar sits left of the column, level with its tool (\(style.frame))")
        bar.toolButtons[.arrow]?.onHover?(true)
        expect(!bar.hoverCard.isHidden && bar.hoverCard.frame.minX >= bar.frame.maxX, "in a column the card goes beside it (\(bar.hoverCard.frame))")
        h.screenshot().map { write($0, "toolbar-right.png") }

        h = CaptureHarness(size: size)
        let wide = CGRect(x: 400, y: 300, width: 790, height: 540)
        h.select(wide)
        h.key("1", code: 18)
        (bar, style) = chrome(h)
        expect(bar.isVertical && bar.frame.maxX == wide.minX - 8, "no room right: the column goes left (\(bar.frame))")
        expect(style.frame.minX >= bar.frame.maxX, "with the style bar right of it")
        h.screenshot().map { write($0, "toolbar-left.png") }

        h = CaptureHarness(size: size)
        h.select(CGRect(x: 2, y: 2, width: 1196, height: 856))
        (bar, style) = chrome(h)
        expect(bar.isVertical && bar.frame.maxX == 1198 - 8, "no room outside: a column inside the right edge (\(bar.frame))")

        // A narrow full-height selection at the right edge: the column goes outside, on its left.
        h = CaptureHarness(size: size)
        h.select(CGRect(x: 1100, y: 2, width: 98, height: 856))
        (bar, style) = chrome(h)
        expect(bar.isVertical && bar.frame.maxX == 1100 - 8, "a narrow selection at the edge gets the column on its left (\(bar.frame))")

        // Back from a column to a row when the selection moves up.
        h = CaptureHarness(size: size)
        h.select(low)
        for _ in 0..<100 { h.key("", code: 126) }
        (bar, style) = chrome(h)
        expect(!bar.isVertical, "moving the selection up turns the column back into a row (\(bar.frame))")
    }

    @MainActor static func toolbarKeys() async {
        ToolbarKeys.reset()
        defer { ToolbarKeys.reset() }
        let h = CaptureHarness()
        h.select(CGRect(x: 100, y: 100, width: 600, height: 200))
        let bar = h.view.subviews.compactMap { $0 as? ToolbarView }.first!
        let card = bar.hoverCard
        let rect = bar.toolButtons[.rectangle]!

        rect.onHover?(true)
        rect.onHover?(false)
        card.onHover?(true) // the pointer arrives on the card within the grace time
        try? await Task.sleep(for: .milliseconds(600))
        expect(!card.isHidden, "the card stays while the pointer is on it")

        h.window.makeFirstResponder(h.view)
        let cap = card.subviews.first { $0.layer?.cornerRadius == 4 }!
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: card.convert(CGPoint(x: cap.frame.midX, y: cap.frame.midY), to: nil),
                                      modifierFlags: [], timestamp: 0, windowNumber: h.window.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)!
        card.mouseDown(with: down)
        expect(card.isRecording && h.window.firstResponder === card, "clicking the key cap waits for a new key")
        h.screenshot().map { write($0, "toolbar-key-recording.png") }
        h.key("e", code: 14)
        expect(!card.isRecording && ToolbarKeys.key(for: "rectangle") == "e" && h.window.firstResponder === h.view,
               "pressing E makes it the rectangle's key and gives the keyboard back")
        h.key("e", code: 14)
        expect(bar.toolButtons[.rectangle]!.isActive, "E now picks the rectangle")
        h.key("1", code: 18)
        expect(bar.toolButtons[.rectangle]!.isActive, "1 no longer does anything")

        card.startRecording()
        h.key("2", code: 19)
        expect(ToolbarKeys.key(for: "rectangle") == "2" && ToolbarKeys.key(for: "arrow") == "e", "a taken key swaps with its owner")
        h.screenshot().map { write($0, "toolbar-key-swapped.png") }
        card.startRecording()
        h.key("\u{1b}", code: 53)
        expect(!card.isRecording && ToolbarKeys.key(for: "rectangle") == "2", "Esc cancels without changing the key")
        card.startRecording()
        h.key("a", code: 0, flags: .command)
        expect(card.isRecording && ToolbarKeys.key(for: "rectangle") == "2", "keys with ⌘ are refused")
        h.window.makeFirstResponder(h.view)
        expect(!card.isRecording, "clicking elsewhere stops waiting")
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

    /// Left half red, right half blue.
    @MainActor static func splitRep(_ size: CGSize) -> NSBitmapImageRep {
        let rep = sampleRep(size, color: .systemRed)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemBlue.setFill()
        CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    @MainActor static func render(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    @MainActor static func toolColors() async {
        UserDefaults.standard.removeObject(forKey: "style.colors")
        UserDefaults.standard.removeObject(forKey: "style.sizes")
        expect(StyleMemory.color(for: .rectangle).isApproximately(StyleState.palette[0]), "tools start red")

        let h = CaptureHarness()
        h.select(CGRect(x: 40, y: 40, width: 600, height: 360))
        h.key("1", code: 18)
        h.view.testing_applyStyle(.color(StyleState.palette[3]))
        h.view.testing_applyStyle(.size(8))
        h.key("2", code: 19)
        h.view.testing_applyStyle(.color(StyleState.palette[5]))
        h.key("1", code: 18)
        h.drag(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 200))
        let rect = h.view.testing_items.last
        expect(rect?.color.isApproximately(StyleState.palette[3]) == true && rect?.size == 8, "rectangle keeps its own green and size 8")
        h.key("2", code: 19)
        h.drag(CGPoint(x: 300, y: 100), CGPoint(x: 400, y: 200))
        expect(h.view.testing_items.last?.color.isApproximately(StyleState.palette[5]) == true, "arrow keeps its own purple")
        expect(StyleMemory.color(for: .rectangle).isApproximately(StyleState.palette[3]) && StyleMemory.size(for: .rectangle) == 8,
               "choices are saved for the next launch")

        h.export().map { write($0, "tool-colors.png") }
    }

    @MainActor static func itemStyles() async {
        UserDefaults.standard.removeObject(forKey: "style.options")
        for tool in Tool.allCases { StyleMemory.setColor(StyleState.palette[0], for: tool) }
        StyleMemory.sizes = [:]
        let h = CaptureHarness()
        h.select(CGRect(x: 20, y: 20, width: 760, height: 460))
        func option(_ change: @escaping (inout ItemStyle) -> Void) { h.view.testing_applyStyle(.options(change)) }

        h.key("1", code: 18)
        option { $0.dash = .dashed }
        option { $0.rounded = true }
        h.drag(CGPoint(x: 60, y: 60), CGPoint(x: 260, y: 160))
        // Esc first each time: an option change applies to the selected annotation, and the last one drawn is selected.
        h.key("\u{1b}", code: 53)
        h.key("2", code: 19)
        option { $0.arrowHead = .open }
        h.drag(CGPoint(x: 300, y: 160), CGPoint(x: 450, y: 70))
        h.key("\u{1b}", code: 53)
        option { $0.arrowHead = .double }
        h.drag(CGPoint(x: 480, y: 120), CGPoint(x: 700, y: 120))
        h.key("\u{1b}", code: 53)
        h.key("3", code: 20)
        option { $0.dash = .dotted }
        h.drag(CGPoint(x: 60, y: 220), CGPoint(x: 400, y: 220))
        h.key("\u{1b}", code: 53)
        h.key("6", code: 22)
        option { $0.text = .background }
        h.click(CGPoint(x: 460, y: 200))
        (h.window.firstResponder as? NSTextView)?.insertText("底色文字", replacementRange: NSRange(location: NSNotFound, length: 0))
        h.key("\u{1b}", code: 53)
        h.key("\u{1b}", code: 53)
        option { $0.text = .outline }
        h.click(CGPoint(x: 460, y: 330))
        (h.window.firstResponder as? NSTextView)?.insertText("描边文字", replacementRange: NSRange(location: NSNotFound, length: 0))
        h.key("\u{1b}", code: 53)

        let items = h.view.testing_items
        expect(items.count == 6, "six styled annotations (\(items.count))")
        expect(items[0].style.dash == .dashed && items[0].style.rounded, "rectangle is dashed and rounded")
        expect(items[1].style.arrowHead == .open && items[2].style.arrowHead == .double, "arrow heads are remembered per new arrow")
        expect(items[4].style.text == .background && items[5].style.text == .outline, "text decorations applied")
        expect(StyleMemory.style(for: .rectangle).dash == .dashed && StyleMemory.style(for: .text).text == .outline, "options are remembered per tool")

        h.key("\u{1b}", code: 53)
        h.key("\u{1b}", code: 53)
        h.key("2", code: 19)
        h.screenshot().map { write($0, "item-styles-bar.png") }
        guard let rep = h.export() else { return expect(false, "export") }
        write(rep, "item-styles.png")
        func out(_ x: CGFloat, _ y: CGFloat) -> NSColor { rep.color(atPoint: CGPoint(x: x - 20, y: y - 20))! }
        func red(_ c: NSColor) -> Bool { c.redComponent > 0.8 && c.greenComponent < 0.45 }
        let edge = (0..<60).map { out(100 + CGFloat($0), 60) }
        expect(edge.contains(where: red) && edge.contains(where: { !red($0) }), "dashed edge has both ink and gaps")
        expect(!red(out(61, 61)), "rounded rectangle leaves the sharp corner empty")
        expect(red(out(486, 120)), "double arrow has a head at the start too")
        // Inside the background pill, between glyphs.
        let text = items[4]
        expect(red(out(text.bounds.minX + 2, text.bounds.midY)), "text background is filled with the color")
    }

    @MainActor static func scanCode() async {
        func qr(_ text: String) -> CIImage {
            let filter = CIFilter(name: "CIQRCodeGenerator")!
            filter.setValue(Data(text.utf8), forKey: "inputMessage")
            return filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        }
        // Two codes placed on a big light "screen", like a web page with a QR code on it.
        let size = CGSize(width: 1600, height: 1000)
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.95, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let ci = CIContext()
        ctx.draw(ci.createCGImage(qr("https://shotlate.example/app"), from: qr("https://shotlate.example/app").extent)!, in: CGRect(x: 200, y: 300, width: 264, height: 264))
        ctx.draw(ci.createCGImage(qr("WIFI:S:Office;P:12345678;;"), from: qr("WIFI:S:Office;P:12345678;;").extent)!, in: CGRect(x: 1000, y: 500, width: 296, height: 296))
        let screen = ctx.makeImage()!
        let codes = await CodeScanner.scan([screen, screen])
        expect(codes.count == 2 && codes.contains("https://shotlate.example/app") && codes.contains("WIFI:S:Office;P:12345678;;"),
               "finds both codes on the screen, without duplicates across screens (\(codes))")
        let blank = sampleRep(CGSize(width: 400, height: 300), color: .white).cgImage!
        let none = await CodeScanner.scan([blank])
        expect(none.isEmpty, "a screen without codes finds nothing")
    }

    @MainActor static func pinAnnotate() async {
        let screen = CGRect(x: -4100, y: -4100, width: 800, height: 600)
        let pin = PinManager.shared.pin(sampleRep(CGSize(width: 200, height: 100), color: .white), frame: CGRect(x: -4000, y: -4000, width: 200, height: 100))
        pin.setZoom(1.5, anchor: CGPoint(x: -4000, y: -3900), flash: false)
        let zoomedFrame = pin.frame
        guard let session = CaptureSession.beginPinEdit(pin, in: screen) else { return expect(false, "pin editing starts") }
        let view = session.testing_views[0]
        expect(!pin.isVisible, "the pin hides while its copy is being edited")
        let local = view.testing_selection ?? .zero
        expect(local.size == CGSize(width: 200, height: 100), "editing happens at 100% (\(local))")
        StyleMemory.setColor(StyleState.palette[0], for: .rectangle)
        StyleMemory.setStyle(ItemStyle(), for: .rectangle) // earlier checks may have left it dashed
        StyleMemory.sizes[.rectangle] = 4
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func key(_ chars: String, _ code: UInt16) {
            view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!)
        }
        key("1", 18)
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: local.minX + 20, y: local.minY + 20)))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: local.minX + 120, y: local.minY + 70)))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: local.minX + 120, y: local.minY + 70)))
        let oldRep = pin.rep
        key("\r", 36)
        expect(session.isFinished && pin.isVisible, "Return finishes and shows the pin again")
        expect(pin.rep !== oldRep && pin.rep.size == CGSize(width: 200, height: 100), "the pin now has the annotated image at full size")
        let c = pin.rep.color(atPoint: CGPoint(x: 20, y: 45))!
        expect(c.redComponent > 0.8 && c.greenComponent < 0.4, "the rectangle is baked into the pin (\(c))")
        expect(abs(pin.zoom - 1.5) < 0.001 && abs(pin.frame.minX - zoomedFrame.minX) < 0.5 && abs(pin.frame.maxY - zoomedFrame.maxY) < 0.5,
               "the pin is back at 150% in the same place")
        write(pin.rep, "pin-annotated.png")

        // Esc throws edits away.
        let before = pin.rep
        guard let second = CaptureSession.beginPinEdit(pin, in: screen) else { return expect(false, "second edit") }
        let v2 = second.testing_views[0]
        v2.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                          characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
        expect(second.isFinished && pin.rep === before && pin.isVisible, "Esc leaves the pin unchanged")
        PinManager.shared.closeAll()
    }

    @MainActor static func hotkeys() async {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        // An unusual combination so it is free: ⌃⌥⇧⌘ + F13.
        let shortcut = Shortcut(keyCode: 105, carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey), keyLabel: "F13")
        var fired = 0
        let ok = center.register(.scanCode, shortcut: shortcut) { fired += 1 }
        expect(ok && center.registeredCount == 1, "a shortcut registers with the system")
        center.testing_fire(HotKeyCenter.Action.scanCode.rawValue)
        expect(fired == 1, "it runs its action")
        center.register(.scanCode, shortcut: nil) { fired += 1 }
        expect(center.registeredCount == 0, "a cleared shortcut is released")
        center.unregisterAll()

        // Settings take effect as they change; there is no save button.
        let model = SettingsModel(loadSecrets: false)
        var notified = 0
        let token = NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: nil) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        model.imageFormat = .jpeg
        expect(Settings.shared.imageFormat == .jpeg, "changing the format saves it at once")
        model.imageFormat = .png
        model.targetLanguage = "English"
        expect(Settings.shared.targetLanguage == "English", "so does the target language")
        model.targetLanguage = "简体中文"
        model.scanCodeShortcut = shortcut
        expect(Settings.shared.scanCodeShortcut == shortcut && notified == 1, "a new global shortcut is saved and re-registered")
        model.scanCodeShortcut = nil
        center.unregisterAll()

        // Every pane, rendered offscreen for a look (without reading the API key).
        for pane in SettingsPane.allCases {
            let hosting = NSHostingView(rootView: SettingsView(model: model, pane: pane))
            hosting.frame = CGRect(x: 0, y: 0, width: 680, height: 460)
            let window = NSWindow(contentRect: CGRect(x: -8000, y: -8000, width: 680, height: 460), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                write(rep, "settings-\(pane.rawValue).png")
            }
        }
    }

    @MainActor static func magnifierTool() async {
        StyleMemory.setColor(StyleState.palette[0], for: .magnifier)
        let h = CaptureHarness()
        h.select(CGRect(x: 40, y: 40, width: 700, height: 400))
        h.key("5", code: 23)
        let source = CGPoint(x: 110, y: 88)
        h.drag(source, CGPoint(x: 134, y: 88))
        guard case let .magnifier(s0, target, radius)? = h.view.testing_items.last?.shape else { return expect(false, "draws a magnifier") }
        expect(s0 == source && abs(radius - 24) < 0.5 && target.x > source.x + radius, "circle where dragged, lens beside it (\(target))")
        guard let rep = h.export() else { return expect(false, "export") }
        write(rep, "magnifier.png")
        // Every probe near the source (skipping the ring) must look the same inside the lens, at twice the offset.
        var matches = 0, total = 0
        for dx in stride(from: -14, through: 14, by: 2) {
            for dy in stride(from: -8, through: 8, by: 2) {
                let q = CGPoint(x: source.x + CGFloat(dx), y: source.y + CGFloat(dy))
                guard let original = h.original(q) else { continue }
                let lensPoint = CGPoint(x: target.x + CGFloat(dx) * 2 - 40, y: target.y + CGFloat(dy) * 2 - 40)
                guard let shown = rep.color(atPoint: lensPoint) else { continue }
                total += 1
                if abs(original.brightnessComponent - shown.brightnessComponent) < 0.2 { matches += 1 }
            }
        }
        // Anti-aliased glyph edges don't land on exactly doubled points, so allow some disagreement there.
        expect(total > 100 && Double(matches) / Double(total) > 0.8, "the lens shows the source area at 2× (\(matches)/\(total))")
        // Drag the lens elsewhere by its handle.
        h.drag(target, CGPoint(x: target.x + 60, y: target.y + 150))
        if case let .magnifier(_, moved, _)? = h.view.testing_items.last?.shape {
            expect(abs(moved.y - target.y - 150) < 0.5, "the lens can be moved on its own")
        }
        h.screenshot().map { write($0, "magnifier-overlay.png") }
    }

    @MainActor static func loupe() async {
        let h = CaptureHarness()
        h.view.mouseMoved(with: h.mouse(.mouseMoved, CGPoint(x: 70, y: 70)))
        expect(h.view.testing_magnifierVisible, "the loupe follows the pointer while choosing")
        expect(h.view.testing_magnifier.colorString == "#FFFFFF", "it samples the pixel under the pointer (\(h.view.testing_magnifier.colorString))")
        NSPasteboard.general.clearContents()
        h.key("c", code: 8)
        expect(NSPasteboard.general.string(forType: .string) == "#FFFFFF", "C copies the color")
        let shift = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!
        h.view.flagsChanged(with: shift)
        expect(h.view.testing_magnifier.colorString == "255, 255, 255", "⇧ switches to RGB")
        let release = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                       characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!
        h.view.flagsChanged(with: release)
        h.view.flagsChanged(with: shift)
        h.view.flagsChanged(with: release)
        expect(h.view.testing_magnifier.colorString == "#FFFFFF", "and back to HEX")
    }

    @MainActor static func pinTranslate() async {
        let h = CaptureHarness(lines: ["Settings", "Automatically check for updates", "Save screenshots to Pictures"])
        h.select(CGRect(x: 60, y: 60, width: 420, height: 110))
        guard let rep = h.export() else { return expect(false, "export") }
        let pin = PinManager.shared.pin(rep, frame: CGRect(origin: CGPoint(x: -4000, y: -4000), size: rep.size))
        var sent: [String] = []
        pin.translateUsesDefault = false
        pin.translate = { rep in
            try await ImageTranslator.translate(rep) { items in
                sent = items.map(\.text)
                return Dictionary(uniqueKeysWithValues: items.map { ($0.id, "译文\($0.id)：检查更新") })
            }
        }
        let original = pin.rep
        key(pin, "y", code: 16)
        for _ in 0..<400 where !pin.showsTranslation { try? await Task.sleep(for: .milliseconds(100)) }
        expect(pin.showsTranslation && pin.rep !== original, "Y translates the pin in place")
        expect(sent.contains { $0.contains("Automatically check for updates") }, "the pin's text was sent for translation (\(sent))")
        expect(pin.rep.size == original.size && pin.frame.size == original.size, "the translated pin keeps its size")
        write(pin.rep, "pin-translated.png")
        key(pin, "y", code: 16)
        expect(!pin.showsTranslation && pin.rep === original, "Y again shows the original")
        key(pin, "y", code: 16)
        expect(pin.showsTranslation, "and back to the translation without translating again")
        PinManager.shared.closeAll()
    }

    @MainActor static func secretFile() async {
        let name = "check-secret"
        defer { SecretFile.write("", name) }
        SecretFile.write("sk-first", name)
        SecretFile.write("sk-second", name)
        expect(SecretFile.read(name) == "sk-second", "the saved key reads back")
        let path = SecretFile.directory.appendingPathComponent(name).path
        let mode = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? 0
        expect(mode == 0o600, "only the user can read it (mode \(String(mode, radix: 8)))")
        SecretFile.write("", name)
        expect(SecretFile.read(name) == nil, "an empty key removes the file")
    }

    @MainActor static func ocr() async {
        let h = CaptureHarness(lines: ["Settings", "Automatically check for updates", "识别截图里的文字"])
        h.select(CGRect(x: 60, y: 60, width: 420, height: 110))
        NSPasteboard.general.clearContents()
        h.key("x", code: 7)
        for _ in 0..<300 where h.view.testing_ocrText == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let text = h.view.testing_ocrText else { return expect(false, "X shows the recognized text") }
        expect(text.contains("Automatically check for updates") && text.contains("截图"), "X recognizes the text (\(text.debugDescription))")
        expect(NSPasteboard.general.string(forType: .string) == nil, "without copying it by itself")
        let panel = h.view.subviews.compactMap { $0 as? OCRPanelView }.first!
        panel.textView.string = text + "（已修改）"
        panel.copyText()
        expect(NSPasteboard.general.string(forType: .string) == text + "（已修改）", "the copy button copies the edited text")
        h.screenshot().map { write($0, "ocr.png") }
        h.key("\u{1b}", code: 53)
        expect(h.view.testing_ocrText == nil && h.view.testing_selection != nil, "Esc closes the panel first, keeping the selection")
    }

    @MainActor static func pinText() async {
        let h = CaptureHarness(lines: ["Settings", "Automatically check for updates", "直接在贴图上选择文字"])
        h.select(CGRect(x: 60, y: 60, width: 420, height: 110))
        guard let rep = h.export() else { return expect(false, "export") }
        let pin = PinManager.shared.pin(rep, frame: CGRect(origin: CGPoint(x: -4000, y: -4000), size: rep.size))
        let view = pin.testing_view
        for _ in 0..<300 where view.textLayout == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let layout = view.textLayout else { return expect(false, "a new pin recognizes its text") }
        expect(layout.lines.count == 3, "three lines recognized (\(layout.lines.map(\.text)))")
        guard let auto = layout.lines.firstIndex(where: { $0.text.contains("check") }), auto + 1 < layout.lines.count else { return }
        let line = layout.lines[auto]
        let start = line.text.distance(from: line.text.startIndex, to: line.text.range(of: "check")!.lowerBound)
        // At 100% the view shows the image one to one.
        func point(_ l: Int, _ k: Int) -> CGPoint { CGPoint(x: layout.lines[l].boxes[k].minX + 0.5, y: layout.lines[l].rect.midY) }
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: pin.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        let last = layout.lines[auto + 1]
        let end = CGPoint(x: last.rect.maxX + 30, y: last.rect.midY)
        view.mouseDown(with: mouse(.leftMouseDown, point(auto, start)))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 200, y: 60)))
        view.mouseDragged(with: mouse(.leftMouseDragged, end))
        view.mouseUp(with: mouse(.leftMouseUp, end))
        let origin = pin.frame.origin
        expect(pin.frame.origin == origin && view.textSelection != nil, "dragging on text selects instead of moving the pin")
        NSPasteboard.general.clearContents()
        key(pin, "c", code: 8, flags: .command)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        expect(copied == "check for updates\n" + last.text, "⌘C copies the selected text across lines (\(copied.debugDescription))")
        write(render(view) ?? rep, "pin-text-selection.png")

        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 100)))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 400, y: 100)))
        expect(view.textSelection == nil, "clicking off the text clears the selection")
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 100), clicks: 2))
        expect(pin.isVisible, "double-clicking a pin no longer closes it")
        let settings = layout.lines.firstIndex { $0.text == "Settings" } ?? 0
        view.mouseDown(with: mouse(.leftMouseDown, point(settings, 2), clicks: 2))
        expect(view.selectedText == layout.lines[settings].text, "double-click selects a word (\(view.selectedText ?? "nil"))")
        view.mouseDown(with: mouse(.leftMouseDown, point(auto, 2), clicks: 3))
        expect(view.selectedText == line.text, "triple-click selects the line")
        key(pin, "\u{1b}", code: 53)
        expect(view.textSelection == nil && pin.isVisible, "Esc first clears the selection")

        key(pin, "\u{1b}", code: 53)
        expect(!pin.isVisible, "Esc then closes the pin")
        PinManager.shared.closeAll()
    }
}
