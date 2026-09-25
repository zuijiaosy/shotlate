import AppKit

/// Drives the capture overlay offscreen with synthetic events and writes a PNG per step,
/// so the interaction states can be reviewed without Screen Recording permission.
///
///   Snap --ui-demo background.png output-directory
enum UIDemo {
    @MainActor
    static func run(input: URL, outputDirectory: URL) async {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // Place the sample at the top-left of a larger canvas so the toolbar has room.
        let size = CGSize(width: 960, height: 620)
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let sample = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let canvas = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        canvas.setFillColor(NSColor(srgbRed: 0.85, green: 0.87, blue: 0.9, alpha: 1).cgColor)
        canvas.fill(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
        canvas.draw(sample, in: CGRect(x: 80, y: canvas.height - sample.height - 80, width: sample.width, height: sample.height))
        guard let snapshot = canvas.makeImage() else { return }

        let frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -5000, y: -5000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let windowRect = CGRect(x: 40, y: 40, width: 640, height: 300)
        let view = CaptureView(frame: frame, snapshot: snapshot, windowRects: [windowRect], displayID: 0)
        window.contentView = CaptureRootView(frame: frame, snapshot: snapshot, captureView: view)
        window.makeFirstResponder(view)

        var step = 0
        func shot(_ name: String) {
            step += 1
            view.layoutSubtreeIfNeeded()
            // A fresh, fully transparent bitmap so undrawn areas let the screenshot show through.
            guard let overlay = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
            overlay.size = size
            if let data = overlay.bitmapData { memset(data, 0, overlay.bytesPerRow * overlay.pixelsHigh) }
            view.cacheDisplay(in: view.bounds, to: overlay)
            if step == 3, let c = overlay.colorAt(x: 800, y: 500) { print("overlay pixel inside selection:", c) }
            let out = NSImage(size: size)
            out.lockFocus()
            NSImage(cgImage: snapshot, size: size).draw(in: frame)
            overlay.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            out.unlockFocus()
            if let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: outputDirectory.appendingPathComponent(String(format: "%02d-%@.png", step, name)))
            }
        }
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: flags, timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        func drag(_ from: CGPoint, _ to: CGPoint, flags: NSEvent.ModifierFlags = [], steps: Int = 8, capture: String? = nil) {
            view.mouseDown(with: mouse(.leftMouseDown, from, flags: flags))
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                // A slight curve so pen strokes are not straight lines.
                let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t + sin(t * .pi) * 12)
                view.mouseDragged(with: mouse(.leftMouseDragged, capture == nil ? p : CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), flags: flags))
            }
            if let capture { shot(capture) }
            view.mouseUp(with: mouse(.leftMouseUp, to, flags: flags))
        }
        func click(_ p: CGPoint, clicks: Int = 1) {
            view.mouseDown(with: mouse(.leftMouseDown, p, clicks: clicks))
            view.mouseUp(with: mouse(.leftMouseUp, p, clicks: clicks))
        }
        func key(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: chars,
                                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            (window.firstResponder ?? view).keyDown(with: event)
        }

        view.mouseMoved(with: mouse(.mouseMoved, CGPoint(x: 300, y: 170)))
        shot("hover-window-magnifier")

        drag(CGPoint(x: 70, y: 60), CGPoint(x: 700, y: 360), capture: "selecting")
        shot("selected")

        key("r", code: 15)
        drag(CGPoint(x: 96, y: 120), CGPoint(x: 330, y: 170), capture: nil)
        shot("rectangle-selected")

        key("a", code: 0)
        drag(CGPoint(x: 560, y: 110), CGPoint(x: 420, y: 150))
        key("m", code: 46)
        drag(CGPoint(x: 100, y: 196), CGPoint(x: 300, y: 196))
        shot("mosaic-brush")

        key("n", code: 45)
        click(CGPoint(x: 90, y: 110))
        click(CGPoint(x: 90, y: 250))
        key("p", code: 35)
        drag(CGPoint(x: 460, y: 250), CGPoint(x: 660, y: 290))

        key("1", code: 18)
        click(CGPoint(x: 420, y: 320))
        if let editor = window.firstResponder as? NSTextView {
            editor.insertText("Snap 标注\n第二行", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        shot("text-editing")
        key("\u{1b}", code: 53) // commit text
        key("\u{1b}", code: 53) // deselect
        key("\u{1b}", code: 53) // drop tool
        shot("after-escape-steps")

        // Select the rectangle by its outline, move it, then make it thicker with the wheel.
        click(CGPoint(x: 96, y: 145))
        drag(CGPoint(x: 96, y: 145), CGPoint(x: 116, y: 225))
        for _ in 0..<4 {
            let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!
            view.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        }
        shot("rectangle-moved-thicker")

        key("z", code: 6, flags: .command)
        key("z", code: 6, flags: .command)
        shot("undo-twice")
        key("z", code: 6, flags: [.command, .shift])
        shot("redo-once")

        func pump(_ seconds: TimeInterval) async { try? await Task.sleep(for: .seconds(seconds)) }
        key("x", code: 7) // OCR
        for _ in 0..<200 where !(view.subviews.contains { $0 is OCRPanelView && !$0.isHidden }) { await pump(0.25) }
        shot("ocr-panel")
        key("\u{1b}", code: 53) // close OCR panel
        Settings.shared.apiKey.isEmpty ? key("y", code: 16) : ()
        await pump(0.1)
        shot("translate-without-key")

        // Frosted-glass mosaic over the button, then delete badge 1 so badge 2 renumbers to 1.
        key("\u{1b}", code: 53)
        key("m", code: 46)
        view.testing_applyStyle(.mosaicMode(.rect))
        view.testing_applyStyle(.mosaicEffect(.blur))
        drag(CGPoint(x: 540, y: 285), CGPoint(x: 690, y: 330))
        key("\u{1b}", code: 53)
        key("\u{1b}", code: 53)
        click(CGPoint(x: 90, y: 110))
        key("", code: 51)
        shot("blur-mosaic-renumbered")

        // Deselect, then shrink the selection's right edge and grow its bottom edge by keyboard.
        key("\u{1b}", code: 53)
        for _ in 0..<20 { key("", code: 124, flags: .shift) }
        for _ in 0..<20 { key("", code: 125, flags: .command) }
        shot("keyboard-resized")

        if let rep = view.exportImage(format: .png), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: outputDirectory.appendingPathComponent("export.png"))
        }

        // Pin: zoom to 60%, rotate right, and render the pin window's content.
        if let rep = view.exportImage(format: .png, shadow: false) {
            let pin = PinWindow(rep: rep, frame: CGRect(x: -5000, y: -5000, width: rep.size.width, height: rep.size.height))
            pin.setZoom(0.6)
            pin.rotateRight()
            if let content = pin.contentView, let out = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: out)
                try? out.representation(using: .png, properties: [:])?.write(to: outputDirectory.appendingPathComponent("pin-rotated.png"))
                print("Pin frame \(pin.frame.size) zoom \(pin.zoom)")
            }
        }
        print("Wrote \(step) steps to \(outputDirectory.path)")
    }
}
