import AppKit
import SwiftUI
import Carbon.HIToolbox
import SwiftUI
import CoreImage
import SnapCore

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
        ("copy-file", copyAsFile),
        ("auto-save", autoSave),
        ("history", history),
        ("pin-thumbnail", pinThumbnail),
        ("pin-groups", pinGroups),
        ("pin-restore", pinRestore),
        ("selection-size", selectionSize),
        ("tool-colors", toolColors),
        ("item-styles", itemStyles),
        ("cursor", cursorCapture),
        ("refresh", refreshCapture),
        ("scan-code", scanCode),
        ("share", shareFile),
        ("boards", boards),
        ("elements", elements),
        ("pin-annotate", pinAnnotate),
        ("automation", automation),
        ("hotkeys", hotkeys),
        ("magnifier", magnifierTool),
        ("pin-filters", pinFilters),
        ("pin-multi", pinMulti),
        ("super-snip", superSnip),
        ("print", printing),
        ("loupe", loupe),
        ("hot-corners", hotCorners),
        ("redact", redact),
        ("ocr-structure", ocrStructure),
        ("pin-translate", pinTranslate),
    ]

    @MainActor
    static func run(_ name: String, output: URL?) async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        // Start from default preferences so one run's choices (colors, dashes, ratios) can't leak into the next.
        // Only when running unbundled from .build: then the domain is the executable's, never the app's.
        if Bundle.main.bundleIdentifier == nil {
            UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
        }
        PinStore.shared = PinStore(directory: outputDirectory.appendingPathComponent("pin-store", isDirectory: true))
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
        StyleMemory.setColor(StyleState.palette[2], for: .highlighter)
        // Across the first text line, then a straight ⇧ stroke that ends off-axis and should snap to horizontal.
        h.drag(CGPoint(x: 80, y: 88), CGPoint(x: 400, y: 90))
        h.drag(CGPoint(x: 80, y: 150), CGPoint(x: 400, y: 158), flags: .shift)
        // A red rectangle first, then a marker across it: the rectangle must survive under the marker.
        h.key("r", code: 15)
        StyleMemory.setColor(StyleState.palette[0], for: .rectangle)
        h.drag(CGPoint(x: 450, y: 180), CGPoint(x: 520, y: 240))
        h.key("h", code: 4)
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
        StyleMemory.setColor(StyleState.palette[0], for: .rectangle)
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
        StyleMemory.setColor(StyleState.palette[4], for: .line)
        StyleMemory.setColor(StyleState.palette[4], for: .arrow)
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

    @MainActor static func copyAsFile() async {
        let pb = NSPasteboard(name: NSPasteboard.Name("app.snap.check"))
        let rep = sampleRep()
        Exporter.copy(rep, to: pb, asFile: false)
        expect(pb.data(forType: .png) != nil && pb.string(forType: .fileURL) == nil, "plain copy has the image and no file")
        let pasted = pb.readObjects(forClasses: [NSImage.self])?.first as? NSImage
        expect(pasted?.size == rep.size, "a 2x image pastes back at its point size (\(String(describing: pasted?.size)) vs \(rep.size))")

        Exporter.copy(rep, to: pb, asFile: true)
        expect(pb.data(forType: .png) != nil, "copy as file still has the image")
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        expect(urls.count == 1, "copy as file adds one file URL")
        if let url = urls.first {
            let data = try? Data(contentsOf: url)
            expect(url.pathExtension == "png" && data?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]), "the file exists and is a PNG (\(url.lastPathComponent))")
            expect(url.path.hasPrefix(Exporter.clipboardDirectory.path), "the file lives in Snap's clipboard cache")
        }
        expect(pb.pasteboardItems?.count == 1, "image and file are one pasteboard item, so apps don't paste twice")
        // Pinning the clipboard back reads the file and gets the same picture.
        let before = PinManager.shared.pins.count
        PinManager.shared.pinClipboard(pb)
        expect(PinManager.shared.pins.count == before + 1, "a copied-as-file image can be pinned again")
        PinManager.shared.closeAll()
    }

    @MainActor static func autoSave() async {
        let settings = Settings.shared
        let saved = (settings.autoSave, settings.fileNameTemplate, settings.saveDirectory)
        defer { (settings.autoSave, settings.fileNameTemplate, settings.saveDirectory) = saved }
        let dir = outputDirectory.appendingPathComponent("autosave", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        settings.saveDirectory = dir
        settings.fileNameTemplate = "{app}_{yyyyMMdd}"
        Exporter.sourceAppName = "Safari"
        let expected = "Safari_" + { let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; return f.string(from: Date()) }()

        settings.autoSave = false
        var h = CaptureHarness()
        h.select(CGRect(x: 40, y: 40, width: 300, height: 200))
        h.key("\r", code: 36)
        var files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        expect(files.isEmpty, "copy without auto-save writes no file")

        settings.autoSave = true
        h = CaptureHarness()
        h.select(CGRect(x: 40, y: 40, width: 300, height: 200))
        h.key("\r", code: 36)
        files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        expect(files.count == 1, "copy with auto-save writes one file (\(files))")
        expect(files.first?.hasPrefix(expected) ?? false, "file name follows the template (\(files.first ?? "-"))")

        h = CaptureHarness()
        h.select(CGRect(x: 40, y: 40, width: 300, height: 200))
        h.key("t", code: 17, flags: .command)
        files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        expect(files.count == 2 && files.contains("\(expected) 2.png"), "pinning also auto-saves, with a numbered name on collision (\(files.sorted()))")
        PinManager.shared.closeAll()
    }

    @MainActor static func history() async {
        let dir = outputDirectory.appendingPathComponent("history", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        let store = CaptureHistory(directory: dir)
        let settings = Settings.shared
        let savedLimit = settings.historyLimit
        defer { settings.historyLimit = savedLimit }
        settings.historyLimit = 3

        // Draw on a capture, then keep it.
        let h = CaptureHarness()
        h.select(CGRect(x: 40, y: 40, width: 400, height: 250))
        StyleMemory.setColor(StyleState.palette[0], for: .rectangle)
        StyleMemory.setColor(StyleState.palette[0], for: .arrow)
        h.key("r", code: 15)
        h.drag(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200))
        h.key("a", code: 0)
        h.drag(CGPoint(x: 350, y: 250), CGPoint(x: 200, y: 150))
        guard let entry = h.view.historyEntry() else { return expect(false, "a selection gives a history entry") }
        let exported = h.export()
        store.record(entry, snapshot: h.view.snapshotImage)
        for i in 0..<3 {
            store.record(HistoryEntry(displayID: 0, screenSize: h.size, selection: CGRect(x: i * 10, y: 0, width: 50, height: 50), items: []),
                         snapshot: h.view.snapshotImage)
        }
        store.waitForWrites()
        expect(store.entries.count == 3, "keeps only the newest \(settings.historyLimit)")
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        expect(folders.count == 3, "older entries are deleted from disk (\(folders.count) folders)")

        // Reload from disk, as after a restart.
        settings.historyLimit = 5
        var fresh = entry
        fresh.id = UUID()
        fresh.date = Date()
        store.record(fresh, snapshot: h.view.snapshotImage)
        store.waitForWrites()
        let reloaded = CaptureHistory(directory: dir)
        let newest = reloaded.entries.first
        expect(reloaded.entries.count == 4 && newest == fresh, "entries survive a reload with annotations intact")
        expect(newest?.items.count == 2 && newest?.items[0].color.isApproximately(StyleState.palette[0]) == true, "annotation colors round-trip")

        // Restore into a fresh overlay: same picture as the original export.
        guard let newest, let image = reloaded.image(for: newest) else { return expect(false, "screen image loads") }
        let replay = CaptureHarness()
        let view = CaptureView(frame: CGRect(origin: .zero, size: replay.size), snapshot: image, windowRects: [], displayID: 0)
        replay.window.contentView = CaptureRootView(frame: CGRect(origin: .zero, size: replay.size), snapshot: image, captureView: view)
        view.restore(newest)
        let restored = view.exportImage(format: .png, shadow: false)
        if let a = exported, let b = restored {
            let pa = a.color(atPoint: CGPoint(x: 60, y: 60))!, pb = b.color(atPoint: CGPoint(x: 60, y: 60))!
            expect(a.size == b.size && abs(pa.redComponent - pb.redComponent) < 0.02, "restored capture exports the same image")
            write(b, "history-restored.png")
        }
        expect(view.historyEntry() == nil, "outputting a replayed capture unchanged does not store it again")
        // Step through history in a session: , goes older, . comes back to the live screen.
        let live = CaptureHarness()
        let session = CaptureSession.makeForTesting(image: live.snapshot, size: live.size, history: reloaded)
        let first = session.testing_views[0]
        first.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                             characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43)!)
        let shown = session.testing_views[0]
        expect(shown !== first && shown.testing_selection == newest.selection && shown.testing_items.count == 2,
               ", shows the newest capture with its selection and annotations")
        shown.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                             characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43)!)
        let older = session.testing_views[0]
        expect(older.testing_selection == reloaded.entries[1].selection, ", again steps to the next older one")
        for _ in 0..<2 {
            session.testing_views[0].keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                                    context: nil, characters: ".", charactersIgnoringModifiers: ".",
                                                                    isARepeat: false, keyCode: 47)!)
        }
        let back = session.testing_views[0]
        expect(back.testing_selection == nil && back.snapshotImage === live.snapshot, ". twice returns to the live screen without a selection")
        session.finish()

        store.clear()
        store.waitForWrites()
        expect(!FileManager.default.fileExists(atPath: dir.path) && store.entries.isEmpty, "clear removes everything")
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

    @MainActor static func pinThumbnail() async {
        let original = CGRect(x: -4000, y: -4000, width: 200, height: 100)
        let pin = PinManager.shared.pin(splitRep(original.size), frame: original)
        pin.testing_view.testing_rightDrag(from: CGPoint(x: 120, y: 20), to: CGPoint(x: 180, y: 80))
        expect(pin.thumbnail != nil && pin.frame.size == CGSize(width: 60, height: 60), "right-drag collapses to the dragged box (\(pin.frame.size))")
        expect(pin.frame.minX == original.minX + 120 && pin.frame.maxY == original.maxY - 20, "the region stays where it was on screen")
        if let shot = render(pin.testing_view), let c = shot.color(atPoint: CGPoint(x: 30, y: 30)) {
            expect(c.blueComponent > 0.8 && c.redComponent < 0.4, "thumbnail shows the right half (blue) (\(c))")
            write(shot, "pin-thumbnail.png")
        }
        pin.exitThumbnail()
        expect(pin.thumbnail == nil && pin.frame == original, "exiting restores the full pin in place (\(pin.frame))")

        pin.enterFixedThumbnail(around: CGPoint(x: 10, y: 50))
        expect(pin.frame.size == CGSize(width: 64, height: 64) && pin.frame.minX == original.minX, "fixed thumbnail is a 64pt square clamped inside the image")
        if let shot = render(pin.testing_view), let c = shot.color(atPoint: CGPoint(x: 20, y: 30)) {
            expect(c.redComponent > 0.8 && c.blueComponent < 0.4, "fixed thumbnail shows the left half (red)")
        }
        pin.setZoom(1)
        expect(pin.thumbnail == nil && pin.frame.size == original.size, "zooming leaves thumbnail mode")
        PinManager.shared.closeAll()
    }

    @MainActor static func pinGroups() async {
        let m = PinManager.shared
        let savedGroups = UserDefaults.standard.stringArray(forKey: "pin.groups")
        defer { UserDefaults.standard.set(savedGroups, forKey: "pin.groups") }
        UserDefaults.standard.removeObject(forKey: "pin.groups")
        m.switchGroup(to: PinManager.defaultGroup)
        func frame(_ i: Int) -> CGRect { CGRect(x: -4000 + i * 150, y: -4000, width: 120, height: 80) }
        let a1 = m.pin(sampleRep(), frame: frame(0)), a2 = m.pin(sampleRep(), frame: frame(1))
        expect(m.groups == [PinManager.defaultGroup] && a1.group == PinManager.defaultGroup, "pins start in the default group")

        let b = m.createGroup("项目 B")
        expect(m.currentGroup == b && !a1.isVisible && !a2.isVisible, "creating a group switches to it and hides the others")
        let b1 = m.pin(sampleRep(), frame: frame(2))
        expect(b1.group == b && b1.isVisible, "new pins go into the current group")
        expect(m.createGroup("项目 B") == "项目 B 2", "duplicate names get a number")

        m.switchGroup(to: PinManager.defaultGroup)
        expect(a1.isVisible && a2.isVisible && !b1.isVisible, "switching back shows that group's pins only")

        m.toggleSolo(a1)
        expect(a1.isVisible && !a2.isVisible, "solo shows only that pin")
        m.toggleSolo(a1)
        expect(a1.isVisible && a2.isVisible, "solo off shows the group again")
        m.toggleSolo(a2)
        a2.close(keepInHistory: true)
        expect(a1.isVisible && m.soloPin == nil, "closing the solo pin brings the others back")

        m.toggleHidden()
        expect(!a1.isVisible, "hide all hides the current group")
        m.toggleHidden()
        expect(a1.isVisible && !b1.isVisible, "show all only shows the current group")

        m.move(a1, to: b)
        expect(!a1.isVisible && a1.group == b, "moving a pin to another group hides it here")
        m.renameGroup(b, to: "客户")
        expect(m.groups.contains("客户") && a1.group == "客户" && b1.group == "客户", "renaming keeps the pins in the group")
        expect(UserDefaults.standard.stringArray(forKey: "pin.groups")?.contains("客户") == true, "group names are saved")
        m.switchGroup(to: "客户")
        m.deleteGroup("客户")
        expect(!m.pins.contains { $0 === a1 || $0 === b1 } && !m.groups.contains("客户"), "deleting a group closes its pins")
        m.deleteGroup(PinManager.defaultGroup)
        m.deleteGroup("项目 B 2")
        expect(m.groups.count == 1, "the last group can't be deleted")
        m.closeAll()
    }

    @MainActor static func pinRestore() async {
        let m = PinManager.shared
        m.closeAll()
        let store = PinStore(directory: outputDirectory.appendingPathComponent("pin-restore", isDirectory: true))
        store.clear()
        let savedGroups = UserDefaults.standard.stringArray(forKey: "pin.groups")
        defer { UserDefaults.standard.set(savedGroups, forKey: "pin.groups") }
        UserDefaults.standard.removeObject(forKey: "pin.groups")
        m.switchGroup(to: PinManager.defaultGroup)

        let a = m.pin(splitRep(CGSize(width: 200, height: 100)), frame: CGRect(x: -4000, y: -4000, width: 200, height: 100))
        a.setZoom(1.5, anchor: CGPoint(x: -4000, y: -4000))
        a.setOpacity(0.6)
        a.toggleFloating()
        let text = ClipboardPinSource.textPin("备忘：周五交周报", scale: 2)!
        let b = m.pin(text, centeredAt: CGPoint(x: -3500, y: -3900), on: nil)
        let group = m.createGroup("资料")
        let c = m.pin(sampleRep(), frame: CGRect(x: -3000, y: -4000, width: 120, height: 80))
        c.enterFixedThumbnail(around: CGPoint(x: 10, y: 10))
        let before = [a, b, c].map { ($0.persistentFrame, $0.zoom, $0.group, $0.sourceText) }
        store.save(m)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []
        expect(files.filter { $0.hasSuffix(".png") }.count == 3 && files.contains("pins.json"), "saves one image per pin plus the state")

        for pin in m.pins { pin.close(keepInHistory: false) }
        m.switchGroup(to: PinManager.defaultGroup)
        store.restore(into: m)
        expect(m.pins.count == 3, "restores all three pins")
        expect(m.currentGroup == group, "restores the current group")
        for (pin, old) in zip(m.pins, before) {
            let f = pin.frame, o = old.0
            expect(abs(f.minX - o.minX) < 0.5 && abs(f.minY - o.minY) < 0.5 && abs(f.width - o.width) < 0.5 && abs(f.height - o.height) < 0.5,
                   "frame restored (\(f) vs \(o))")
            expect(abs(pin.zoom - old.1) < 0.001 && pin.group == old.2 && pin.sourceText == old.3, "zoom, group and text restored")
        }
        let ra = m.pins[0]
        expect(abs(ra.alphaValue - 0.6) < 0.01 && ra.level == .normal, "opacity and the always-on-top switch are restored")
        expect(ra.rep.size == CGSize(width: 200, height: 100), "image keeps its point size")
        expect(!ra.isVisible && m.pins[2].isVisible, "only the current group is shown after restoring")

        // Closing a pin and saving again removes its image.
        m.pins[2].close(keepInHistory: false)
        store.save(m)
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []).filter { $0.hasSuffix(".png") }
        expect(left.count == 2, "closed pins' images are deleted")
        m.closeAll()
        m.deleteGroup(group)
    }

    @MainActor static func selectionSize() async {
        let saved = StyleMemory.aspectRatio
        defer { StyleMemory.aspectRatio = saved }
        StyleMemory.aspectRatio = AspectRatio("16:9")
        let h = CaptureHarness()
        h.drag(CGPoint(x: 50, y: 50), CGPoint(x: 370, y: 100))
        expect(h.view.testing_selection == CGRect(x: 50, y: 50, width: 320, height: 180), "16:9 lock shapes the dragged selection (\(String(describing: h.view.testing_selection)))")
        // Drag the bottom-right handle mostly downwards.
        h.drag(CGPoint(x: 370, y: 230), CGPoint(x: 380, y: 320))
        if let r = h.view.testing_selection {
            expect(abs(r.width / r.height - 16.0 / 9.0) < 0.01 && r.minX == 50 && r.minY == 50, "corner resize keeps the ratio and the opposite corner (\(r))")
        }
        h.drag(CGPoint(x: 530, y: 185), CGPoint(x: 610, y: 185)) // right edge handle outward by 80
        if let r = h.view.testing_selection {
            expect(abs(r.width - 560) < 0.5 && abs(r.width / r.height - 16.0 / 9.0) < 0.01 && r.minX == 50,
                   "edge resize grows the other side to keep the ratio (\(r))")
        }
        h.screenshot().map { write($0, "selection-ratio.png") }

        h.view.testing_typeSize(CGSize(width: 400, height: 300))
        expect(h.view.testing_selection?.size == CGSize(width: 400, height: 300), "typed size is applied")
        expect(StyleMemory.aspectRatio == nil, "a typed size that breaks the lock turns the lock off")
        h.view.testing_typeSize(CGSize(width: 5000, height: 5000))
        expect(h.view.testing_selection == CGRect(origin: .zero, size: h.size), "an oversized typed size is limited to the screen")
        h.view.testing_typeSize(CGSize(width: 300, height: 300))
        h.view.testing_setRatio(AspectRatio("4:3"))
        expect(h.view.testing_selection?.size == CGSize(width: 300, height: 225), "choosing a ratio reshapes the current selection")
        expect(StyleMemory.aspectRatio == AspectRatio("4:3"), "the chosen ratio is remembered")
    }

    @MainActor static func toolColors() async {
        UserDefaults.standard.removeObject(forKey: "style.colors")
        UserDefaults.standard.removeObject(forKey: "style.sizes")
        expect(StyleMemory.color(for: .highlighter).isApproximately(StyleState.palette[2]), "highlighter starts yellow")
        expect(StyleMemory.color(for: .rectangle).isApproximately(StyleState.palette[0]), "other tools start red")

        let h = CaptureHarness()
        h.select(CGRect(x: 40, y: 40, width: 600, height: 360))
        h.key("r", code: 15)
        h.view.testing_applyStyle(.color(StyleState.palette[3]))
        h.view.testing_applyStyle(.size(8))
        h.key("a", code: 0)
        h.view.testing_applyStyle(.color(StyleState.palette[5]))
        h.key("r", code: 15)
        h.drag(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 200))
        let rect = h.view.testing_items.last
        expect(rect?.color.isApproximately(StyleState.palette[3]) == true && rect?.size == 8, "rectangle keeps its own green and size 8")
        h.key("a", code: 0)
        h.drag(CGPoint(x: 300, y: 100), CGPoint(x: 400, y: 200))
        expect(h.view.testing_items.last?.color.isApproximately(StyleState.palette[5]) == true, "arrow keeps its own purple")
        expect(StyleMemory.color(for: .rectangle).isApproximately(StyleState.palette[3]) && StyleMemory.size(for: .rectangle) == 8,
               "choices are saved for the next launch")

        // ⌥ + wheel lowers the opacity of the selected arrow.
        for _ in 0..<3 {
            let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0)!
            wheel.flags = .maskAlternate
            h.view.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        }
        let alpha = h.view.testing_items.last?.color.alphaComponent ?? 1
        expect(abs(alpha - 0.7) < 0.01, "⌥ + wheel lowers opacity in 10% steps (\(alpha))")
        h.view.testing_applyStyle(.color(StyleState.palette[4]))
        let after = h.view.testing_items.last?.color
        expect(after?.isApproximately(StyleState.palette[4]) == true && abs((after?.alphaComponent ?? 1) - 0.7) < 0.01, "picking a swatch keeps the opacity")
        h.export().map { write($0, "tool-colors.png") }
    }

    @MainActor static func itemStyles() async {
        UserDefaults.standard.removeObject(forKey: "style.options")
        for tool in Tool.allCases { StyleMemory.setColor(StyleState.palette[0], for: tool) }
        StyleMemory.sizes = [:]
        let h = CaptureHarness()
        h.select(CGRect(x: 20, y: 20, width: 760, height: 460))
        func option(_ change: @escaping (inout ItemStyle) -> Void) { h.view.testing_applyStyle(.options(change)) }

        h.key("r", code: 15)
        option { $0.dash = .dashed }
        option { $0.rounded = true }
        h.drag(CGPoint(x: 60, y: 60), CGPoint(x: 260, y: 160))
        // Esc first each time: an option change applies to the selected annotation, and the last one drawn is selected.
        h.key("\u{1b}", code: 53)
        h.key("a", code: 0)
        option { $0.arrowHead = .open }
        h.drag(CGPoint(x: 300, y: 160), CGPoint(x: 450, y: 70))
        h.key("\u{1b}", code: 53)
        option { $0.arrowHead = .double }
        h.drag(CGPoint(x: 480, y: 120), CGPoint(x: 700, y: 120))
        h.key("\u{1b}", code: 53)
        h.key("l", code: 37)
        option { $0.dash = .dotted }
        h.drag(CGPoint(x: 60, y: 220), CGPoint(x: 400, y: 220))
        h.key("\u{1b}", code: 53)
        h.key("t", code: 17)
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
        h.key("a", code: 0)
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
        // Old history JSON without a style still decodes.
        let legacy = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","shape":{"number":{"_0":[1,2]}},"color":[1,0,0,1],"size":20,"effect":"pixelate"}"#
        let decoded = try? JSONDecoder().decode(AnnotationItem.self, from: Data(legacy.utf8))
        expect(decoded?.style == ItemStyle(), "annotations saved before styles existed still load")
    }

    @MainActor static func cursorCapture() async {
        let arrow = NSCursor.arrow
        let tip = CGPoint(x: 300, y: 250) // on the white card
        let cursor = CapturedCursor(image: arrow.image, rect: CGRect(x: tip.x - arrow.hotSpot.x, y: tip.y - arrow.hotSpot.y,
                                                                    width: arrow.image.size.width, height: arrow.image.size.height))
        expect(CaptureEngine.pointer() != nil, "the current system pointer can be read")
        let h = CaptureHarness(cursor: cursor)
        h.select(CGRect(x: 200, y: 200, width: 200, height: 120))
        expect(!h.view.testing_showsCursor, "off by default")
        func darkPixels(_ rep: NSBitmapImageRep) -> Int {
            var n = 0
            for dx in 0..<10 { for dy in 0..<14 {
                if let c = rep.color(atPoint: CGPoint(x: tip.x - 200 + CGFloat(dx) + 1, y: tip.y - 200 + CGFloat(dy) + 2)), c.brightnessComponent < 0.3 { n += 1 }
            } }
            return n
        }
        let without = h.export()!
        h.key("`", code: 50)
        expect(h.view.testing_showsCursor, "` turns the pointer on")
        let with = h.export()!
        write(with, "cursor.png")
        expect(darkPixels(without) == 0 && darkPixels(with) > 10, "the export contains the pointer only when on (\(darkPixels(without)) vs \(darkPixels(with)))")
        if let screen = h.screenshot() {
            let c = screen.color(atPoint: CGPoint(x: tip.x + 3, y: tip.y + 8))!
            expect(c.brightnessComponent < 0.3, "the on-screen preview shows the pointer too")
        }
        h.key("`", code: 50)
        expect(darkPixels(h.export()!) == 0, "` again takes it out")
    }

    @MainActor static func refreshCapture() async {
        let first = CaptureHarness()
        let history = CaptureHistory(directory: outputDirectory.appendingPathComponent("refresh-history", isDirectory: true))
        let session = CaptureSession.makeForTesting(image: first.snapshot, size: first.size, history: history)
        let view = session.testing_views[0]
        view.window?.makeFirstResponder(view)
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100, y: 100)))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 300, y: 200)))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 300, y: 200)))
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                            characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15)!)
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 120, y: 120)))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 200, y: 180)))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 200, y: 180)))

        // A "new" screen: solid green.
        let green = sampleRep(first.size, color: .systemGreen).cgImage!
        session.refresh(from: view) { [0: green] }
        for _ in 0..<50 where session.testing_views[0] === view { try? await Task.sleep(for: .milliseconds(20)) }
        let refreshed = session.testing_views[0]
        expect(refreshed !== view && refreshed.snapshotImage === green, "F5 swaps in the new screenshot")
        expect(refreshed.testing_selection == CGRect(x: 100, y: 100, width: 200, height: 100) && refreshed.testing_items.count == 1,
               "selection and annotations are kept")
        if let rep = refreshed.exportImage(format: .png, shadow: false), let c = rep.color(atPoint: CGPoint(x: 150, y: 50)) {
            expect(c.greenComponent > 0.6 && c.redComponent < 0.5, "the export uses the new pixels")
        }
        expect(refreshed.historyEntry() != nil, "a refreshed capture is recorded again when output")
        session.finish()
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
        ctx.draw(ci.createCGImage(qr("https://snap.example/app"), from: qr("https://snap.example/app").extent)!, in: CGRect(x: 200, y: 300, width: 264, height: 264))
        ctx.draw(ci.createCGImage(qr("WIFI:S:Office;P:12345678;;"), from: qr("WIFI:S:Office;P:12345678;;").extent)!, in: CGRect(x: 1000, y: 500, width: 296, height: 296))
        let screen = ctx.makeImage()!
        let codes = await CodeScanner.scan([screen, screen])
        expect(codes.count == 2 && codes.contains("https://snap.example/app") && codes.contains("WIFI:S:Office;P:12345678;;"),
               "finds both codes on the screen, without duplicates across screens (\(codes))")
        let blank = sampleRep(CGSize(width: 400, height: 300), color: .white).cgImage!
        let none = await CodeScanner.scan([blank])
        expect(none.isEmpty, "a screen without codes finds nothing")
    }

    @MainActor static func shareFile() async {
        let rep = sampleRep(CGSize(width: 120, height: 80))
        guard let url = try? ShareController.file(for: rep) else { return expect(false, "share file is written") }
        let data = try? Data(contentsOf: url)
        expect(url.pathExtension == "png" && data?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]), "shares a PNG file (\(url.lastPathComponent))")
        let back = data.flatMap(NSBitmapImageRep.init(data:))
        expect(back?.pixelsWide == rep.pixelsWide, "at full resolution")
        let items = NSSharingService.sharingServices(forItems: [url])
        expect(!items.isEmpty, "the system offers share services for it (\(items.count))")
        let toolbar = ToolbarView { _ in }
        expect(toolbar.subviews.first.map { $0.subviews.contains { ($0 as? NSButton)?.toolTip?.hasPrefix("分享") == true } } ?? false,
               "the capture toolbar has a share button")
    }

    @MainActor static func boards() async {
        let size = CGSize(width: 600, height: 400)
        let history = CaptureHistory(directory: outputDirectory.appendingPathComponent("board-history", isDirectory: true))
        StyleMemory.setColor(StyleState.palette[0], for: .pen)
        func drive(_ view: CaptureView) -> (([CGPoint]) -> Void, (String, UInt16) -> Void) {
            func mouse(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                                   windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            let stroke: ([CGPoint]) -> Void = { points in
                view.mouseDown(with: mouse(.leftMouseDown, points[0]))
                for p in points.dropFirst() { view.mouseDragged(with: mouse(.leftMouseDragged, p)) }
                view.mouseUp(with: mouse(.leftMouseUp, points.last!))
            }
            let key: (String, UInt16) -> Void = { chars, code in
                view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                    characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!)
            }
            return (stroke, key)
        }

        let white = CaptureSession.boardImage(size: size, scale: 2, color: .white)
        let board = CaptureSession.makeForTesting(image: white, size: size, history: history, mode: .whiteboard)
        let view = board.testing_views[0]
        expect(view.testing_selection == CGRect(origin: .zero, size: size), "the whole screen is the canvas")
        let (stroke, key) = drive(view)
        stroke((0...10).map { CGPoint(x: 100 + CGFloat($0) * 30, y: 200) })
        expect(view.testing_items.count == 1, "the pen is ready without choosing a tool")
        if let rep = view.exportImage(format: .png) {
            write(rep, "whiteboard.png")
            expect(rep.size == size, "export is the full board without shadow padding (\(rep.size))")
            let ink = rep.color(atPoint: CGPoint(x: 250, y: 200))!, paper = rep.color(atPoint: CGPoint(x: 250, y: 300))!
            expect(ink.redComponent > 0.8 && ink.greenComponent < 0.4 && paper.blueComponent > 0.95, "red ink on white paper")
        }
        key("\u{1b}", 53) // deselects the stroke just drawn
        key("\u{1b}", 53)
        expect(!board.isFinished, "one Esc with nothing selected does not close the board")
        key(" ", 49)
        expect(view.subviews.contains { $0 is ToolbarView && $0.isHidden }, "space hides the toolbar")
        key("\u{1b}", 53)
        expect(board.isFinished, "a second Esc right after closes it")

        let clear = CaptureSession.boardImage(size: size, scale: 2, color: .clear)
        let glass = CaptureSession.makeForTesting(image: clear, size: size, history: history, mode: .transparentBoard)
        let live = sampleRep(size, color: .systemGreen).cgImage!
        glass.liveCapture = { [0: live] }
        let glassView = glass.testing_views[0]
        let (glassStroke, glassKey) = drive(glassView)
        glassStroke((0...10).map { CGPoint(x: 100 + CGFloat($0) * 30, y: 200) })
        let before = NSPasteboard.general.changeCount
        glassKey("\r", 36)
        for _ in 0..<100 where !glass.isFinished { try? await Task.sleep(for: .milliseconds(20)) }
        expect(glass.isFinished && NSPasteboard.general.changeCount != before, "Return on a transparent board copies after grabbing the screen")
        if let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
           let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            let ink = rep.color(atPoint: CGPoint(x: 250, y: 200))!, screen = rep.color(atPoint: CGPoint(x: 250, y: 300))!
            expect(ink.redComponent > 0.8 && screen.greenComponent > 0.6 && screen.redComponent < 0.5, "the drawing is composited onto the live screen")
            write(rep, "transparent-board.png")
        }
    }

    @MainActor static func elements() async {
        let window = CGRect(x: 40, y: 40, width: 640, height: 300)
        let nodes = [
            UIElementNode(rect: CGRect(x: 40, y: 60, width: 640, height: 280), parent: nil), // content
            UIElementNode(rect: CGRect(x: 40, y: 60, width: 640, height: 50), parent: 0),   // toolbar
            UIElementNode(rect: CGRect(x: 60, y: 70, width: 80, height: 30), parent: 1),    // button
        ]
        let h = CaptureHarness(windowRects: [window])
        h.view.setElements(nodes)
        h.view.mouseMoved(with: h.mouse(.mouseMoved, CGPoint(x: 90, y: 85)))
        expect(h.view.testing_hoverRect == nodes[2].rect, "hover highlights the button under the pointer")
        func wheel(_ lines: Int32) {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)!
            h.view.scrollWheel(with: NSEvent(cgEvent: event)!)
        }
        wheel(1)
        expect(h.view.testing_hoverRect == nodes[1].rect, "wheel up selects the parent toolbar")
        wheel(1)
        expect(h.view.testing_hoverRect == nodes[0].rect, "again: the content area")
        wheel(5)
        expect(h.view.testing_hoverRect == window, "and finally the window, no further")
        wheel(-2)
        expect(h.view.testing_hoverRect == nodes[1].rect, "wheel down walks back in")
        h.key("\t", code: 48)
        h.view.mouseMoved(with: h.mouse(.mouseMoved, CGPoint(x: 91, y: 85)))
        expect(h.view.testing_hoverRect == window, "Tab switches to whole windows")
        h.key("\t", code: 48)
        h.view.mouseMoved(with: h.mouse(.mouseMoved, CGPoint(x: 90, y: 85)))
        h.click(CGPoint(x: 90, y: 85))
        expect(h.view.testing_selection == nodes[2].rect, "a click selects the highlighted element")

        // The real collector, reading a window of this process.
        let win = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        let button = NSButton(title: "Snap 按钮", target: nil, action: nil)
        button.frame = CGRect(x: 20, y: 40, width: 120, height: 32)
        win.contentView?.addSubview(button)
        win.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(200))
        let collected = ElementCollector.collect(pids: [ProcessInfo.processInfo.processIdentifier], budget: 1)
        let buttonOnScreen = win.convertToScreen(button.convert(button.bounds, to: nil))
        let found = collected.contains { abs($0.rect.minX - buttonOnScreen.minX) < 2 && abs($0.rect.minY - buttonOnScreen.minY) < 2
            && abs($0.rect.width - buttonOnScreen.width) < 2 }
        if ElementCollector.isTrusted || !collected.isEmpty {
            expect(found, "the collector finds a real button's frame (\(collected.count) elements, trusted: \(ElementCollector.isTrusted))")
            expect(collected.contains { $0.parent != nil }, "and records parents")
        } else {
            print("SKIP  real collector: this process has no Accessibility permission")
        }
        win.orderOut(nil)
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
        key("r", 15)
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: local.minX + 20, y: local.minY + 20)))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: local.minX + 120, y: local.minY + 70)))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: local.minX + 120, y: local.minY + 70)))
        let oldID = pin.id
        key("\r", 36)
        expect(session.isFinished && pin.isVisible, "Return finishes and shows the pin again")
        expect(pin.id != oldID && pin.rep.size == CGSize(width: 200, height: 100), "the pin now has the annotated image at full size")
        let c = pin.rep.color(atPoint: CGPoint(x: 20, y: 45))!
        expect(c.redComponent > 0.8 && c.greenComponent < 0.4, "the rectangle is baked into the pin (\(c))")
        expect(abs(pin.zoom - 1.5) < 0.001 && abs(pin.frame.minX - zoomedFrame.minX) < 0.5 && abs(pin.frame.maxY - zoomedFrame.maxY) < 0.5,
               "the pin is back at 150% in the same place")
        write(pin.rep, "pin-annotated.png")

        // Esc throws edits away.
        let before = pin.id
        guard let second = CaptureSession.beginPinEdit(pin, in: screen) else { return expect(false, "second edit") }
        let v2 = second.testing_views[0]
        v2.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                          characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
        expect(second.isFinished && pin.id == before && pin.isVisible, "Esc leaves the pin unchanged")
        PinManager.shared.closeAll()
    }

    @MainActor static func automation() async {
        // Two side-by-side 2x screens: red on the left, blue on the right.
        let left = CGRect(x: 0, y: 0, width: 400, height: 300), right = CGRect(x: 400, y: 0, width: 400, height: 300)
        let screens = [(left, sampleRep(left.size, color: .systemRed).cgImage!), (right, sampleRep(right.size, color: .systemBlue).cgImage!)]
        let rep = AutomationRunner.crop(CGRect(x: 450, y: 100, width: 120, height: 80), screens: screens)
        expect(rep?.size == CGSize(width: 120, height: 80) && rep?.pixelsWide == 240, "crops the area from the right screen at full resolution")
        if let c = rep?.color(atPoint: CGPoint(x: 60, y: 40)) { expect(c.blueComponent > 0.8 && c.redComponent < 0.4, "with that screen's pixels") }
        expect(AutomationRunner.crop(CGRect(x: 350, y: 100, width: 100, height: 50), screens: screens)?.size == CGSize(width: 50, height: 50),
               "an area across two screens is cut to the screen holding its center")

        let dir = outputDirectory.appendingPathComponent("automation", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        let file = dir.appendingPathComponent("sub/out.png")
        let saved = Settings.shared.saveDirectory
        defer { Settings.shared.saveDirectory = saved }
        Settings.shared.saveDirectory = dir
        let before = PinManager.shared.pins.count
        let results = AutomationRunner.deliver(rep!, frame: CGRect(x: -4000, y: -4000, width: 120, height: 80), outputs: [.pin, .quickSave, .file(file.path)])
        expect(results.count == 3 && FileManager.default.fileExists(atPath: file.path), "writes the requested file, creating folders (\(results))")
        expect(PinManager.shared.pins.count == before + 1 && PinManager.shared.pins.last?.frame.origin == CGPoint(x: -4000, y: -4000), "pins where the area was")
        let quick = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".png") }
        expect(quick.count == 1, "quick-save goes to the save folder")
        PinManager.shared.closeAll()

        // Interactive capture with an output: selecting is enough.
        let h = CaptureHarness()
        let session = CaptureSession.makeForTesting(image: h.snapshot, size: h.size,
                                                    history: CaptureHistory(directory: outputDirectory.appendingPathComponent("auto-history")))
        session.autoOutputs = [.pin]
        let view = session.testing_views[0]
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100, y: 100)))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 260, y: 200)))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 260, y: 200)))
        for _ in 0..<50 where !session.isFinished { try? await Task.sleep(for: .milliseconds(20)) }
        expect(session.isFinished && PinManager.shared.pins.last?.frame.size == CGSize(width: 160, height: 100),
               "snip -o pin pins the selection as soon as it is made")
        PinManager.shared.closeAll()
    }

    @MainActor static func hotkeys() async {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        // Unusual combinations so they are free: ⌃⌥⇧⌘ + F13 / F14.
        let a = Shortcut(keyCode: 105, carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey), keyLabel: "F13")
        let b = Shortcut(keyCode: 107, carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey), keyLabel: "F14")
        var fired: [String] = []
        let okA = center.register(id: HotKeyCenter.customBase, shortcut: a) { fired.append("a") }
        let okB = center.register(id: HotKeyCenter.customBase + 1, shortcut: b) { fired.append("b") }
        expect(okA && okB && center.registeredCount == 2, "two custom commands register with the system")
        center.setSuspended(true)
        expect(center.registeredCount == 0, "an ignored app in front releases every hotkey")
        center.setSuspended(false)
        expect(center.registeredCount == 2, "and they come back when it leaves")
        center.testing_fire(HotKeyCenter.customBase + 1)
        expect(fired == ["b"], "each id runs its own command")
        center.unregisterCustom()
        expect(center.registeredCount == 0, "custom commands can be cleared without touching built-ins")

        expect(IgnoredApps.matches(name: "Steam", bundleID: "com.valvesoftware.steam", path: "/Applications/Steam.app", patterns: ["steam"]),
               "matches an app by name, case-insensitively")
        expect(IgnoredApps.matches(name: "Game", bundleID: "x.y", path: "/Users/me/Games/Foo.app", patterns: ["games/"]),
               "matches a path fragment")
        expect(!IgnoredApps.matches(name: "Safari", bundleID: "com.apple.Safari", path: "/Applications/Safari.app", patterns: ["steam", " "]),
               "leaves other apps alone")
        expect(CustomCommand.presets.allSatisfy { Automation.parse(command: $0.command) != nil }, "every preset command parses")

        // The settings window with a couple of commands, rendered offscreen for a look (without touching the Keychain).
        let model = SettingsModel(loadSecrets: false)
        model.customCommands = [CustomCommand(name: "截取全屏并复制", command: "snip --full -o clipboard", shortcut: a),
                                CustomCommand(name: "新命令", command: "oops")]
        model.ignoredAppsText = "Steam, com.microsoft.rdc.macos"
        let hosting = NSHostingView(rootView: SettingsView(model: model))
        hosting.frame = CGRect(x: 0, y: 0, width: 480, height: 1900)
        let window = NSWindow(contentRect: CGRect(x: -8000, y: -8000, width: 480, height: 1900), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            write(rep, "settings.png")
        }

    }

    @MainActor static func magnifierTool() async {
        StyleMemory.setColor(StyleState.palette[0], for: .magnifier)
        let h = CaptureHarness()
        h.select(CGRect(x: 40, y: 40, width: 700, height: 400))
        h.key("g", code: 5)
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

    @MainActor static func pinFilters() async {
        let pin = PinManager.shared.pin(splitRep(CGSize(width: 200, height: 100)), frame: CGRect(x: -4000, y: -4000, width: 200, height: 100))
        key(pin, "5", code: 23)
        let gray = pin.displayedRep.color(atPoint: CGPoint(x: 50, y: 50))!
        expect(pin.grayscale && abs(gray.redComponent - gray.blueComponent) < 0.03, "5 shows the pin in grayscale")
        if let shot = render(pin.testing_view), let c = shot.color(atPoint: CGPoint(x: 50, y: 50)) {
            expect(abs(c.redComponent - c.greenComponent) < 0.05, "the window shows it gray too")
        }
        key(pin, "5", code: 23)
        key(pin, "6", code: 22)
        let inv = pin.displayedRep.color(atPoint: CGPoint(x: 50, y: 50))!, orig = pin.rep.color(atPoint: CGPoint(x: 50, y: 50))!
        expect(abs(inv.redComponent - (1 - orig.redComponent)) < 0.05, "6 inverts the colors")
        pin.rotateRight()
        expect(pin.inverted && pin.displayedRep.color(atPoint: CGPoint(x: 50, y: 50))!.redComponent < 0.5, "filters survive rotating (red top half, inverted)")
        pin.rotateLeft()
        key(pin, "6", code: 22)

        // Crop to the right (blue) half via a thumbnail.
        pin.testing_view.testing_rightDrag(from: CGPoint(x: 110, y: 10), to: CGPoint(x: 190, y: 90))
        let thumbFrame = pin.frame
        pin.cropToThumbnail()
        expect(pin.thumbnail == nil && pin.rep.size == CGSize(width: 80, height: 80) && pin.frame == thumbFrame, "crop keeps just the region, in place")
        let c = pin.rep.color(atPoint: CGPoint(x: 40, y: 40))!
        expect(c.blueComponent > 0.8 && c.redComponent < 0.4, "the cropped image is the blue half")
        pin.setZoom(1)
        expect(pin.frame.size == CGSize(width: 80, height: 80), "100% is the cropped size")

        // A transparent image on a dark checkerboard.
        let clear = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        clear.size = CGSize(width: 40, height: 40)
        let glass = PinManager.shared.pin(clear, frame: CGRect(x: -3000, y: -4000, width: 40, height: 40))
        glass.background = .darkChecker
        if let shot = render(glass.testing_view), let p = shot.color(atPoint: CGPoint(x: 12, y: 12)) {
            expect(p.alphaComponent > 0.99 && p.brightnessComponent < 0.4, "see-through parts show the dark checkerboard")
        }
        PinManager.shared.closeAll()
    }

    @MainActor static func pinMulti() async {
        let m = PinManager.shared
        m.closeAll()
        let a = m.pin(sampleRep(), frame: CGRect(x: -4000, y: -4000, width: 120, height: 80))
        let b = m.pin(sampleRep(), frame: CGRect(x: -3800, y: -4000, width: 120, height: 80))
        let c = m.pin(sampleRep(), frame: CGRect(x: -3600, y: -4000, width: 120, height: 80))
        a.testing_view.testing_beginDrag(at: .zero, command: true)
        b.testing_view.testing_beginDrag(at: .zero, command: true)
        expect(m.selection.count == 2, "⌘-click selects two pins")
        b.testing_view.drag(to: CGPoint(x: 30, y: 40), snapping: false)
        expect(a.frame.origin == CGPoint(x: -3970, y: -3960) && b.frame.origin == CGPoint(x: -3770, y: -3960) && c.frame.origin == CGPoint(x: -3600, y: -4000),
               "dragging one selected pin moves the whole selection only")
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -4, wheel2: 0, wheel3: 0)!
        wheel.flags = .maskAlternate
        a.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        expect(abs(a.alphaValue - 0.8) < 0.01 && abs(b.alphaValue - 0.8) < 0.01 && c.alphaValue == 1, "⌥ + wheel changes the selection's opacity")
        key(c, "a", code: 0, flags: .command)
        expect(m.selection.count == 3, "⌘A selects every visible pin")
        key(a, "w", code: 13, flags: .command)
        expect(m.pins.isEmpty, "⌘W closes the whole selection")

        // ⇧-drag: the right pin sticks to the left pin's right edge.
        let left = m.pin(sampleRep(), frame: CGRect(x: -4000, y: -4000, width: 120, height: 80))
        let right = m.pin(sampleRep(), frame: CGRect(x: -3700, y: -3995, width: 120, height: 80))
        right.testing_view.testing_beginDrag(at: .zero)
        right.testing_view.drag(to: CGPoint(x: -172, y: 0), snapping: true) // lands at x -3872, 8pt from -3880
        expect(right.frame.minX == left.frame.maxX && right.frame.minY == left.frame.minY, "⇧-drag snaps to the neighbour's edge (\(right.frame))")
        right.testing_view.testing_beginDrag(at: .zero)
        right.testing_view.drag(to: CGPoint(x: 8, y: 0), snapping: false)
        expect(right.frame.minX == left.frame.maxX + 8, "without ⇧ there is no snapping")

        // Drops.
        let pb = NSPasteboard(name: NSPasteboard.Name("app.snap.drop"))
        pb.clearContents()
        let file = outputDirectory.appendingPathComponent("drop.png")
        try? sampleRep(CGSize(width: 60, height: 50), color: .systemRed).representation(using: .png, properties: [:])?.write(to: file)
        pb.writeObjects([file as NSURL])
        PinDrop.accept(pb, into: left)
        expect(left.rep.size == CGSize(width: 60, height: 50) && left.frame.size == CGSize(width: 60, height: 50), "a dropped image file replaces the picture")
        pb.clearContents()
        pb.writeObjects([URL(string: "https://example.com/cat.png")! as NSURL])
        let png = sampleRep(CGSize(width: 30, height: 30), color: .systemBlue).representation(using: .png, properties: [:])!
        PinDrop.accept(pb, into: right) { _ in png }
        for _ in 0..<50 where right.sourceText == nil { try? await Task.sleep(for: .milliseconds(20)) }
        expect(right.sourceText == "https://example.com/cat.png" && right.rep.pixelsWide == 60, "a dropped image link is downloaded into the pin")
        m.closeAll()
    }

    @MainActor static func superSnip() async {
        let h = CaptureHarness()
        let session = CaptureSession.makeForTesting(image: h.snapshot, size: h.size,
                                                    history: CaptureHistory(directory: outputDirectory.appendingPathComponent("ss-history")))
        // The testing window sits at (-9000, -9000); an area inside it in global Cocoa coordinates.
        session.preselect(CGRect(x: -9000 + 100, y: -9000 + 200, width: 300, height: 150))
        let view = session.testing_views[0]
        expect(view.testing_selection == CGRect(x: 100, y: h.size.height - 200 - 150, width: 300, height: 150),
               "the dragged area opens already selected (\(String(describing: view.testing_selection)))")
        session.finish()
        expect(SuperSnip.cocoa(CGRect(x: 10, y: 20, width: 30, height: 40)).maxY == (NSScreen.screens.first?.frame.height ?? 0) - 20,
               "event coordinates are flipped to Cocoa")
        let ok = SuperSnip.shared.setEnabled(true)
        if ElementCollector.isTrusted {
            expect(ok && SuperSnip.shared.isRunning, "the event tap starts with permission")
        } else {
            expect(!ok && !SuperSnip.shared.isRunning, "without permission the tap is refused cleanly")
            print("SKIP  live event tap: no Accessibility permission for this process")
        }
        SuperSnip.shared.setEnabled(false)
    }

    @MainActor static func printing() async {
        let pdf = outputDirectory.appendingPathComponent("print.pdf")
        try? FileManager.default.removeItem(at: pdf)
        let rep = sampleRep(CGSize(width: 1600, height: 900), color: .systemRed)
        let ok = Printer.operation(for: rep, pdf: pdf).run()
        let doc = CGPDFDocument(pdf as CFURL)
        expect(ok && doc?.numberOfPages == 1, "prints on exactly one page (pages: \(doc?.numberOfPages ?? 0))")
        if let page = doc?.page(at: 1) {
            let box = page.getBoxRect(.mediaBox)
            expect(box.width > box.height, "a wide image prints in landscape (\(box.size))")
        }
    }

    @MainActor static func loupe() async {
        let settings = Settings.shared
        defer { settings.magnifierZoom = 8; settings.magnifierHidden = false; settings.magnifierGrid = true }
        settings.magnifierZoom = 4
        var h = CaptureHarness()
        expect(h.view.testing_magnifier.cellSize == 4 && h.view.testing_magnifier.cells == 31, "4× shows more pixels (\(h.view.testing_magnifier.cells))")
        settings.magnifierZoom = 12
        h = CaptureHarness()
        expect(h.view.testing_magnifier.cells == 11 && h.view.testing_magnifier.frame.width == 132, "12× shows fewer, bigger pixels")

        settings.magnifierHidden = true
        h = CaptureHarness()
        h.view.mouseMoved(with: h.mouse(.mouseMoved, CGPoint(x: 70, y: 70)))
        expect(!h.view.testing_magnifierVisible, "hidden in settings: no loupe while choosing")
        expect(h.view.testing_magnifier.colorString == "#FFFFFF", "the pixel under the pointer is still sampled for C (\(h.view.testing_magnifier.colorString))")
        let option = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!
        h.view.flagsChanged(with: option)
        expect(h.view.testing_magnifierVisible, "holding ⌥ shows it")
        let release = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                       characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!
        h.view.flagsChanged(with: release)
        expect(!h.view.testing_magnifierVisible, "releasing ⌥ hides it again")
    }

    @MainActor static func hotCorners() async {
        let settings = Settings.shared
        defer { settings.hotCorners = [:]; HotCornerMonitor.shared.reload() }
        settings.hotCorners = [:]
        HotCornerMonitor.shared.reload()
        expect(!HotCornerMonitor.shared.isRunning, "no corners set: nothing polls")
        settings.hotCorners = [.topRight: "toggle-images"]
        HotCornerMonitor.shared.reload()
        expect(HotCornerMonitor.shared.isRunning, "a corner with a command starts watching")
        expect(HotCornerMonitor.choices.allSatisfy { $0.command.isEmpty || Automation.parse(command: $0.command) != nil }, "every corner choice is a valid command")
        let m = PinManager.shared
        let pin = m.pin(sampleRep(), frame: CGRect(x: -4000, y: -4000, width: 120, height: 80))
        HotCornerMonitor.shared.run(.topRight)
        expect(!pin.isVisible && m.isHidingAll, "the top-right corner hides the pins")
        HotCornerMonitor.shared.run(.topRight)
        expect(pin.isVisible, "again shows them")
        HotCornerMonitor.shared.run(.bottomLeft)
        expect(pin.isVisible, "a corner without a command does nothing")
        m.closeAll()
    }

    @MainActor static func redact() async {
        let h = CaptureHarness(lines: [
            "客户：张三  电话 13812345678",
            "邮箱：zhang.san@example.com",
            "订单号 20260925153000  金额 128.50",
            "OPENAI_API_KEY=sk-proj_abcdefghijklmnop123",
        ])
        h.select(CGRect(x: 60, y: 60, width: 520, height: 160))
        h.key("b", code: 11)
        for _ in 0..<400 where !(h.view.testing_items.contains { if case .mosaicRect = $0.shape { return true }; return false }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let boxes = h.view.testing_items.compactMap { item -> CGRect? in
            if case let .mosaicRect(r) = item.shape { return r }
            return nil
        }
        expect(boxes.count == 3, "covers the phone number, email and API key (\(boxes.count) boxes: \(boxes.map(\.integral)))")
        // Line 1 is at y≈80-97; the phone number is the right part of it, "客户：张三" on the left stays readable.
        expect(boxes.contains { $0.minY < 90 && $0.maxY > 90 && $0.minX > 150 }, "the phone box covers just the number, not the whole line")
        expect(!boxes.contains { $0.minY < 146 && $0.maxY > 146 }, "the order number line is left alone")
        h.key("b", code: 11)
        try? await Task.sleep(for: .milliseconds(300))
        let again = h.view.testing_items.filter { if case .mosaicRect = $0.shape { return true }; return false }.count
        expect(again == boxes.count, "pressing B again doesn't stack more boxes")
        h.key("z", code: 6, flags: .command)
        expect(h.view.testing_items.isEmpty, "one ⌘Z removes all the boxes")
        h.key("z", code: 6, flags: [.command, .shift])
        h.export().map { write($0, "redact.png") }
    }

    @MainActor static func ocrStructure() async {
        let gap = String(repeating: " ", count: 18)
        let h = CaptureHarness(lines: ["Name\(gap)City\(gap)Score", "Alice\(gap)Paris\(gap)95", "Bob\(gap)  Tokyo\(gap)88"])
        h.select(CGRect(x: 60, y: 60, width: 520, height: 110))
        h.key("x", code: 7)
        for _ in 0..<400 where h.view.testing_ocrText == nil { try? await Task.sleep(for: .milliseconds(100)) }
        let text = h.view.testing_ocrText ?? ""
        print("OCR table output:\n\(text)")
        expect(text.hasPrefix("| Name | City | Score |") && text.contains("| Alice | Paris | 95 |"), "a table on screen comes out as a Markdown table")
        h.view.testing_reformat(0)
        expect(!(h.view.testing_ocrText ?? "").contains("|"), "文本 switches back to plain lines")

        let code = CaptureHarness(lines: ["func add(a: Int) -> Int {", "        return a + 1", "}"])
        code.select(CGRect(x: 60, y: 60, width: 520, height: 110))
        code.key("x", code: 7)
        for _ in 0..<400 where code.view.testing_ocrText == nil { try? await Task.sleep(for: .milliseconds(100)) }
        code.view.testing_reformat(2)
        let indented = code.view.testing_ocrText ?? ""
        print("OCR code output:\n\(indented)")
        let second = indented.split(separator: "\n").dropFirst().first.map(String.init) ?? ""
        expect(second.hasPrefix("    ") && second.trimmingCharacters(in: .whitespaces).hasPrefix("return"), "代码 keeps the body indented")
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
}
