import AppKit
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
    ]

    @MainActor
    static func run(_ name: String, output: URL?) async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
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
}
