import AppKit

/// Shotlate's mark for the menu bar and the capture menu row: three selection corners and an open-centre reticle
/// (⇧⌘4's "select a region", not a camera). Drawn as a vector template on an 18-point grid with 2-point strokes
/// centred on whole points, so it stays sharp at 1x and keeps its shape on the light tiles of menu-bar managers.
enum BrandGlyph {
    static func image(pointSize: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { rect in
            let s = rect.width / 18
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: y * s) }
            NSColor.black.set()

            let corners = NSBezierPath()
            corners.lineWidth = 2 * s
            corners.lineCapStyle = .round
            corners.lineJoinStyle = .round
            for (start, corner, end) in [(p(3, 7), p(3, 3), p(7, 3)), (p(11, 3), p(15, 3), p(15, 7)), (p(3, 11), p(3, 15), p(7, 15))] {
                corners.move(to: start)
                corners.appendArc(from: corner, to: end, radius: 1.5 * s)
                corners.line(to: end)
            }
            corners.stroke()

            // Four whole-pixel ticks around a 2 × 2 open centre at (13, 13), so it can't be read as "+" (add).
            for (x, y, w, h) in [(12, 9, 2, 3), (12, 14, 2, 3), (9, 12, 3, 2), (14, 12, 3, 2)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                NSBezierPath(roundedRect: NSRect(x: x * s, y: y * s, width: w * s, height: h * s), xRadius: 0.4 * s, yRadius: 0.4 * s).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Shotlate"
        return image
    }
}
