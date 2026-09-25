import AppKit

/// An offscreen capture overlay driven with synthetic events, for scripted checks.
@MainActor
final class CaptureHarness {
    let window: NSWindow
    let view: CaptureView
    let snapshot: CGImage
    let size: CGSize

    /// A 2x canvas: light grey with a white card, black text lines and a dark band, so tools show up on varied pixels.
    init(size: CGSize = CGSize(width: 800, height: 500), windowRects: [CGRect] = [], cursor: CapturedCursor? = nil) {
        self.size = size
        let scale: CGFloat = 2
        let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Draw in flipped points so the layout below reads top-down like the view.
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSColor(srgbRed: 0.86, green: 0.88, blue: 0.9, alpha: 1).setFill()
        CGRect(origin: .zero, size: size).fill()
        NSColor.white.setFill()
        CGRect(x: 60, y: 60, width: 520, height: 300).fill()
        for i in 0..<6 {
            NSAttributedString(string: "Line \(i + 1): The quick brown fox jumps over the lazy dog 1234567890",
                               attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black])
                .draw(at: CGPoint(x: 80, y: 80 + CGFloat(i) * 28))
        }
        NSColor(srgbRed: 0.15, green: 0.17, blue: 0.2, alpha: 1).setFill()
        CGRect(x: 60, y: 300, width: 520, height: 60).fill()
        NSGraphicsContext.restoreGraphicsState()
        snapshot = ctx.makeImage()!

        let frame = CGRect(origin: .zero, size: size)
        window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = CaptureView(frame: frame, snapshot: snapshot, windowRects: windowRects, displayID: 0, cursor: cursor)
        window.contentView = CaptureRootView(frame: frame, snapshot: snapshot, captureView: view)
        window.makeFirstResponder(view)
    }

    func mouse(_ type: NSEvent.EventType, _ p: CGPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: flags, timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    func drag(_ points: [CGPoint], flags: NSEvent.ModifierFlags = []) {
        guard let first = points.first, let last = points.last else { return }
        view.mouseDown(with: mouse(.leftMouseDown, first, flags: flags))
        for p in points.dropFirst() { view.mouseDragged(with: mouse(.leftMouseDragged, p, flags: flags)) }
        view.mouseUp(with: mouse(.leftMouseUp, last, flags: flags))
    }

    func drag(_ from: CGPoint, _ to: CGPoint, flags: NSEvent.ModifierFlags = [], steps: Int = 8) {
        drag((0...steps).map { i in
            let t = CGFloat(i) / CGFloat(steps)
            return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        }, flags: flags)
    }

    func click(_ p: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
        view.mouseDown(with: mouse(.leftMouseDown, p, flags: flags, clicks: clicks))
        view.mouseUp(with: mouse(.leftMouseUp, p, flags: flags, clicks: clicks))
    }

    func key(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        (window.firstResponder ?? view).keyDown(with: event)
    }

    /// Selects `rect` by dragging.
    func select(_ rect: CGRect) {
        drag(CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY))
    }

    /// The exported image (no shadow) and a pixel reader in selection points.
    func export() -> NSBitmapImageRep? {
        view.exportImage(format: .png, shadow: false)
    }

    /// Color of the snapshot at a point, for comparing against the exported pixels.
    func original(_ p: CGPoint) -> NSColor? {
        NSBitmapImageRep(cgImage: snapshot).colorAt(x: Int(p.x * 2), y: Int(p.y * 2))?.usingColorSpace(.sRGB)
    }

    /// Renders the overlay (dim, selection, chrome) composited over the snapshot, for looking at.
    func screenshot() -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        // A fresh, fully transparent bitmap so undrawn areas let the screenshot show through.
        guard let overlay = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        overlay.size = size
        if let data = overlay.bitmapData { memset(data, 0, overlay.bytesPerRow * overlay.pixelsHigh) }
        view.cacheDisplay(in: view.bounds, to: overlay)
        let out = NSImage(size: size)
        out.lockFocus()
        NSImage(cgImage: snapshot, size: size).draw(in: CGRect(origin: .zero, size: size))
        overlay.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        out.unlockFocus()
        return out.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
    }
}

extension NSBitmapImageRep {
    /// Color at a point given in the image's point size (top-left origin).
    func color(atPoint p: CGPoint) -> NSColor? {
        let sx = CGFloat(pixelsWide) / size.width, sy = CGFloat(pixelsHigh) / size.height
        return colorAt(x: Int(p.x * sx), y: Int(p.y * sy))?.usingColorSpace(.sRGB)
    }
}
