import AppKit

enum Tool: String, CaseIterable {
    case rectangle, ellipse, line, arrow, pen, highlighter, mosaic, eraser, magnifier, text, number

    var title: String {
        switch self {
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .line: return "直线"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .highlighter: return "记号笔"
        case .mosaic: return "马赛克"
        case .eraser: return "橡皮擦"
        case .magnifier: return "放大镜"
        case .text: return "文字"
        case .number: return "序号"
        }
    }

    var symbol: String {
        switch self {
        case .rectangle: return "square"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .pen: return "scribble"
        case .highlighter: return "highlighter"
        case .mosaic: return "checkerboard.rectangle"
        case .eraser: return "eraser"
        case .magnifier: return "plus.magnifyingglass"
        case .text: return "textformat"
        case .number: return "1.circle"
        }
    }

    /// Single-key shortcut while the capture overlay is active.
    var key: String {
        switch self {
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .line: return "l"
        case .arrow: return "a"
        case .pen: return "p"
        case .highlighter: return "h"
        case .mosaic: return "m"
        case .eraser: return "e"
        case .magnifier: return "g"
        case .text: return "t"
        case .number: return "n"
        }
    }

    /// What "size" means differs per tool: stroke width, brush width, font size or badge diameter.
    var sizeRange: ClosedRange<CGFloat> {
        switch self {
        case .mosaic, .eraser: return 6...120
        case .highlighter: return 6...60
        case .magnifier: return 1...10
        case .text: return 10...120
        case .number: return 14...80
        default: return 1...40
        }
    }

    var sizePresets: [CGFloat] {
        switch self {
        case .mosaic, .eraser: return [12, 24, 48]
        case .highlighter: return [12, 20, 32]
        case .magnifier: return [2, 3, 5]
        case .text: return [14, 20, 32]
        case .number: return [20, 26, 36]
        default: return [2, 4, 8]
        }
    }

    var defaultSize: CGFloat { sizePresets[1] }

    /// Freehand tools always draw, even when the stroke starts on an existing annotation.
    var isFreehand: Bool { self == .pen || self == .highlighter || self.usesAreaModes }

    /// Mosaic and eraser work either as a brush or on a dragged box.
    var usesAreaModes: Bool { self == .mosaic || self == .eraser }
}

enum MosaicMode: String { case brush, rect }

/// Stroke pattern for outlined shapes, lines, arrows and the pen.
enum DashStyle: String, Codable, CaseIterable { case solid, dashed, dotted }

/// Arrow look: the tapered filled arrow, a plain line with an open head, or heads at both ends.
enum ArrowHead: String, Codable, CaseIterable { case tapered, open, double }

/// How text stands out from what is under it.
enum TextDecoration: String, Codable, CaseIterable { case plain, background, outline }

/// The optional looks an annotation can have beyond color and size.
struct ItemStyle: Equatable, Codable {
    var dash: DashStyle = .solid
    var arrowHead: ArrowHead = .tapered
    var rounded = false
    var text: TextDecoration = .plain
}
enum MosaicEffect: String, Codable {
    case pixelate, blur
    /// The untouched screenshot: this is how the eraser removes annotations under it.
    case original
}

enum Shape: Equatable, Codable {
    case rectangle(CGRect)
    case ellipse(CGRect)
    case line(CGPoint, CGPoint)
    case arrow(CGPoint, CGPoint)
    /// Connected segments from clicks; with `arrow` the last segment ends in an arrowhead.
    case polyline([CGPoint], arrow: Bool)
    case pen([CGPoint])
    /// A translucent marker stroke, blended so text underneath stays readable.
    case highlighter([CGPoint])
    case mosaicRect(CGRect)
    case mosaicBrush([CGPoint])
    /// Text origin is the top-left of the first line; lines wrap at `width`.
    case text(String, CGPoint, width: CGFloat)
    case number(CGPoint)
    /// A circle of radius `radius` around `source`, shown enlarged in a lens centered at `target`.
    case magnifier(source: CGPoint, target: CGPoint, radius: CGFloat)
}

struct AnnotationItem: Equatable {
    var id = UUID()
    var shape: Shape
    var color: NSColor
    var size: CGFloat
    var effect: MosaicEffect = .pixelate
    var style = ItemStyle()

    var tool: Tool {
        switch shape {
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .line: return .line
        case .arrow: return .arrow
        case let .polyline(_, arrow): return arrow ? .arrow : .line
        case .pen: return .pen
        case .highlighter: return .highlighter
        case .mosaicRect, .mosaicBrush: return effect == .original ? .eraser : .mosaic
        case .text: return .text
        case .number: return .number
        case .magnifier: return .magnifier
        }
    }
}

/// Resize handles of a rectangle, in a flipped (top-left origin) space.
enum ResizeHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    func point(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// Moves the edges this handle controls by `d`. Dragging past the opposite edge flips the rect.
    func resize(_ r: CGRect, by d: CGPoint) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if [.topLeft, .left, .bottomLeft].contains(self) { minX += d.x }
        if [.topRight, .right, .bottomRight].contains(self) { maxX += d.x }
        if [.topLeft, .top, .topRight].contains(self) { minY += d.y }
        if [.bottomLeft, .bottom, .bottomRight].contains(self) { maxY += d.y }
        return CGRect(corners: CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY))
    }

    var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch self {
            case .topLeft: position = .topLeft
            case .top: position = .top
            case .topRight: position = .topRight
            case .right: position = .right
            case .bottomRight: position = .bottomRight
            case .bottom: position = .bottom
            case .bottomLeft: position = .bottomLeft
            case .left: position = .left
            }
            return .frameResize(position: position, directions: .all)
        }
        switch self {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }
}

/// A draggable control point of an annotation.
enum ItemHandle: Equatable {
    case rect(ResizeHandle)
    case start
    case end
    case vertex(Int)
}

// MARK: - Geometry

extension AnnotationItem {
    static func textFont(size: CGFloat) -> NSFont {
        .systemFont(ofSize: size, weight: .medium)
    }

    static func textAttributes(color: NSColor, size: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: textFont(size: size), .foregroundColor: color, .paragraphStyle: paragraph]
    }

    static func textSize(_ text: String, size: CGFloat, width: CGFloat) -> CGSize {
        let measured = NSAttributedString(string: text.isEmpty ? " " : text, attributes: textAttributes(color: .black, size: size))
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        return CGSize(width: ceil(measured.width), height: ceil(measured.height))
    }

    /// Visual bounds, including stroke width.
    var bounds: CGRect {
        let pad = size / 2 + 1
        switch shape {
        case let .rectangle(r), let .ellipse(r):
            return r.insetBy(dx: -pad, dy: -pad)
        case let .mosaicRect(r):
            return r
        case let .line(a, b):
            return CGRect(corners: a, b).insetBy(dx: -pad, dy: -pad)
        case let .arrow(a, b):
            let head = Self.arrowHeadWidth(size) / 2
            return CGRect(corners: a, b).insetBy(dx: -head, dy: -head)
        case let .polyline(points, arrow):
            let pad = arrow ? max(pad, Self.arrowHeadWidth(size) / 2) : pad
            return points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -pad, dy: -pad)
        case let .pen(points), let .highlighter(points), let .mosaicBrush(points):
            return points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -pad, dy: -pad)
        case let .text(text, origin, width):
            let r = CGRect(origin: origin, size: Self.textSize(text, size: size, width: width))
            return style.text == .background ? r.insetBy(dx: -Self.textPadding(size), dy: -Self.textPadding(size) / 2) : r
        case let .number(center):
            return CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        case let .magnifier(source, target, radius):
            let lens = radius * Self.magnification
            return CGRect(x: source.x - radius, y: source.y - radius, width: radius * 2, height: radius * 2)
                .union(CGRect(x: target.x - lens, y: target.y - lens, width: lens * 2, height: lens * 2))
                .insetBy(dx: -pad, dy: -pad)
        }
    }

    /// Whether a click at `p` lands on this annotation. Outlined shapes are hit on their stroke only,
    /// so a new shape can still be drawn inside an existing rectangle.
    func contains(_ p: CGPoint) -> Bool {
        let tolerance = max(5, size / 2 + 3)
        switch shape {
        case let .rectangle(r):
            let outer = r.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = r.insetBy(dx: tolerance, dy: tolerance)
            return outer.contains(p) && (inner.isEmpty || !inner.contains(p))
        case let .ellipse(r):
            let a = max(r.width / 2, 1), b = max(r.height / 2, 1)
            let dx = (p.x - r.midX) / a, dy = (p.y - r.midY) / b
            let radial = (dx * dx + dy * dy).squareRoot()
            return abs(radial - 1) * min(a, b) <= tolerance
        case let .mosaicRect(r):
            return r.contains(p)
        case let .line(a, b):
            return distance(p, a, b) <= tolerance
        case let .arrow(a, b):
            return distance(p, a, b) <= max(tolerance, Self.arrowHeadWidth(size) / 2)
        case let .polyline(points, _):
            return zip(points, points.dropFirst()).contains { distance(p, $0, $1) <= tolerance }
        case let .pen(points), let .highlighter(points), let .mosaicBrush(points):
            if points.count == 1 { return hypot(p.x - points[0].x, p.y - points[0].y) <= tolerance }
            return zip(points, points.dropFirst()).contains { distance(p, $0, $1) <= tolerance }
        case .text:
            return bounds.insetBy(dx: -4, dy: -4).contains(p)
        case let .number(c):
            return hypot(p.x - c.x, p.y - c.y) <= size / 2 + 3
        case let .magnifier(source, target, radius):
            return hypot(p.x - target.x, p.y - target.y) <= radius * Self.magnification + tolerance
                || abs(hypot(p.x - source.x, p.y - source.y) - radius) <= tolerance
        }
    }

    var handles: [(ItemHandle, CGPoint)] {
        switch shape {
        case let .rectangle(r), let .ellipse(r), let .mosaicRect(r):
            return ResizeHandle.allCases.map { (.rect($0), $0.point(in: r)) }
        case let .line(a, b), let .arrow(a, b):
            return [(.start, a), (.end, b)]
        case let .polyline(points, _):
            return points.enumerated().map { (.vertex($0.offset), $0.element) }
        case let .magnifier(source, target, _):
            return [(.start, source), (.end, target)]
        default:
            return []
        }
    }

    func moved(by d: CGPoint) -> AnnotationItem {
        var copy = self
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.x, y: p.y + d.y) }
        switch shape {
        case let .rectangle(r): copy.shape = .rectangle(r.offsetBy(dx: d.x, dy: d.y))
        case let .ellipse(r): copy.shape = .ellipse(r.offsetBy(dx: d.x, dy: d.y))
        case let .mosaicRect(r): copy.shape = .mosaicRect(r.offsetBy(dx: d.x, dy: d.y))
        case let .line(a, b): copy.shape = .line(m(a), m(b))
        case let .arrow(a, b): copy.shape = .arrow(m(a), m(b))
        case let .polyline(points, arrow): copy.shape = .polyline(points.map(m), arrow: arrow)
        case let .pen(points): copy.shape = .pen(points.map(m))
        case let .highlighter(points): copy.shape = .highlighter(points.map(m))
        case let .mosaicBrush(points): copy.shape = .mosaicBrush(points.map(m))
        case let .text(text, origin, width): copy.shape = .text(text, m(origin), width: width)
        case let .number(c): copy.shape = .number(m(c))
        case let .magnifier(source, target, radius): copy.shape = .magnifier(source: m(source), target: m(target), radius: radius)
        }
        return copy
    }

    func resized(_ handle: ItemHandle, by d: CGPoint) -> AnnotationItem {
        var copy = self
        switch (shape, handle) {
        case let (.rectangle(r), .rect(h)): copy.shape = .rectangle(h.resize(r, by: d))
        case let (.ellipse(r), .rect(h)): copy.shape = .ellipse(h.resize(r, by: d))
        case let (.mosaicRect(r), .rect(h)): copy.shape = .mosaicRect(h.resize(r, by: d))
        case let (.line(a, b), .start): copy.shape = .line(CGPoint(x: a.x + d.x, y: a.y + d.y), b)
        case let (.line(a, b), .end): copy.shape = .line(a, CGPoint(x: b.x + d.x, y: b.y + d.y))
        case let (.arrow(a, b), .start): copy.shape = .arrow(CGPoint(x: a.x + d.x, y: a.y + d.y), b)
        case let (.arrow(a, b), .end): copy.shape = .arrow(a, CGPoint(x: b.x + d.x, y: b.y + d.y))
        case let (.magnifier(source, target, radius), .start):
            copy.shape = .magnifier(source: CGPoint(x: source.x + d.x, y: source.y + d.y), target: target, radius: radius)
        case let (.magnifier(source, target, radius), .end):
            copy.shape = .magnifier(source: source, target: CGPoint(x: target.x + d.x, y: target.y + d.y), radius: radius)
        case (.polyline(var points, let arrow), let .vertex(i)) where points.indices.contains(i):
            points[i] = CGPoint(x: points[i].x + d.x, y: points[i].y + d.y)
            copy.shape = .polyline(points, arrow: arrow)
        default: break
        }
        return copy
    }

    var isMeaningful: Bool {
        switch shape {
        case let .rectangle(r), let .ellipse(r), let .mosaicRect(r): return r.width >= 3 && r.height >= 3
        case let .line(a, b), let .arrow(a, b): return hypot(a.x - b.x, a.y - b.y) >= 3
        case let .polyline(points, _): return points.count >= 2 && zip(points, points.dropFirst()).contains { hypot($0.x - $1.x, $0.y - $1.y) >= 3 }
        case let .pen(points), let .highlighter(points): return points.count >= 2
        case let .mosaicBrush(points): return !points.isEmpty
        case let .text(text, _, _): return !text.isEmpty
        case .number: return true
        case let .magnifier(_, _, radius): return radius >= 4
        }
    }

    static let magnification: CGFloat = 2

    /// Where the lens goes for a new magnifier: beside the circle, inside `bounds` if possible.
    static func lensCenter(source: CGPoint, radius: CGFloat, in bounds: CGRect) -> CGPoint {
        let lens = radius * magnification, gap = radius * 0.6
        var x = source.x + radius + gap + lens
        if x + lens > bounds.maxX { x = source.x - radius - gap - lens }
        let y = min(max(source.y, bounds.minY + lens), bounds.maxY - lens)
        return CGPoint(x: x, y: y)
    }

    static func textPadding(_ size: CGFloat) -> CGFloat { max(4, size * 0.35) }
    static func cornerRadius(for r: CGRect, size: CGFloat) -> CGFloat { min(8 + size * 2, min(r.width, r.height) / 2) }

    static func arrowHeadWidth(_ size: CGFloat) -> CGFloat { size * 3 + 10 }
    static func arrowHeadLength(_ size: CGFloat) -> CGFloat { size * 3 + 12 }
}

private func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

extension CGRect {
    init(corners a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

// MARK: - Rendering

/// One translated paragraph, laid out and ready to draw over the original text.
struct TranslatedBlock {
    var rect: CGRect
    var text: String
    var fontSize: CGFloat
    var bold: Bool
    var centered = false
    var background: NSColor
    var foreground: NSColor
}

/// Draws annotations and translations over the frozen screen, in a flipped (top-left origin) context.
/// Shared by the on-screen view and the exporter so the saved image matches what was on screen.
/// The mouse pointer as it was when the capture started, drawable onto the screenshot.
struct CapturedCursor {
    var image: NSImage
    /// Where the pointer image goes, in the capture view's flipped points.
    var rect: CGRect
}

struct ContentRenderer {
    let base: NSImage
    let bounds: CGRect
    let effect: (MosaicEffect) -> NSImage
    /// Drawn right above the screenshot, under every annotation.
    var cursor: CapturedCursor? = nil

    func draw(items: [AnnotationItem], translation: [TranslatedBlock]) {
        drawBase()
        drawOverlays(items: items, draft: nil, hiddenID: nil, translation: translation, baseDrawn: true)
    }

    func drawBase() {
        base.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        drawCursor()
    }

    func drawCursor() {
        cursor?.image.draw(in: cursor!.rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Translations go first so annotations stay on top of them.
    ///
    /// On screen the overlay is a transparent layer above the screenshot. A highlighter multiplies with what is
    /// under it, so when one is present the screenshot is painted into the overlay first (`baseDrawn` false);
    /// the screen then matches the export, which always starts from the screenshot.
    func drawOverlays(items: [AnnotationItem], draft: AnnotationItem?, hiddenID: UUID?, translation: [TranslatedBlock],
                      baseDrawn: Bool = false) {
        if !baseDrawn, (items + [draft].compactMap { $0 }).contains(where: { $0.tool == .highlighter }) {
            drawBase()
        } else if !baseDrawn {
            // On screen the screenshot layer has no pointer; the overlay adds it.
            drawCursor()
        }
        for block in translation { Self.draw(block) }
        var number = 0
        for item in items {
            if case .number = item.shape { number += 1 }
            if item.id != hiddenID { draw(item, number: number) }
        }
        if let draft {
            if case .number = draft.shape { number += 1 }
            draw(draft, number: number)
        }
    }

    static func draw(_ block: TranslatedBlock) {
        block.background.setFill()
        NSBezierPath(roundedRect: block.rect.insetBy(dx: -2, dy: -1.5), xRadius: 2, yRadius: 2).fill()
        let attributed = attributedText(block.text, size: block.fontSize, bold: block.bold, color: block.foreground,
                                        alignment: block.centered ? .center : .natural)
        let measured = attributed.boundingRect(with: CGSize(width: block.rect.width, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading])
        var rect = block.rect
        if measured.height < rect.height {
            rect.origin.y += (rect.height - measured.height) / 2
            rect.size.height = measured.height
        }
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    static func attributedText(_ text: String, size: CGFloat, bold: Bool, color: NSColor,
                               alignment: NSTextAlignment = .natural) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = alignment
        let font = NSFont(name: bold ? "PingFangSC-Semibold" : "PingFangSC-Regular", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    func draw(_ item: AnnotationItem, number: Int) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.setStrokeColor(item.color.cgColor)
        cg.setFillColor(item.color.cgColor)
        cg.setLineWidth(item.size)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        Self.applyDash(item.style.dash, size: item.size, to: cg)

        switch item.shape {
        case let .rectangle(r):
            if item.style.rounded {
                let radius = AnnotationItem.cornerRadius(for: r, size: item.size)
                cg.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
                cg.strokePath()
            } else {
                cg.setLineJoin(.miter)
                cg.stroke(r)
            }
        case let .ellipse(r):
            cg.strokeEllipse(in: r)
        case let .line(a, b):
            cg.strokeLineSegments(between: [a, b])
        case let .arrow(a, b):
            if item.style.arrowHead == .tapered, item.style.dash == .solid {
                if let path = Self.arrowPath(from: a, to: b, size: item.size) {
                    cg.addPath(path)
                    cg.fillPath()
                }
            } else {
                Self.drawArrow([a, b], head: item.style.arrowHead, size: item.size, in: cg)
            }
        case let .polyline(points, arrow):
            guard points.count >= 2 else { break }
            if arrow {
                Self.drawArrow(points, head: item.style.arrowHead, size: item.size, in: cg)
            } else {
                cg.addLines(between: points)
                cg.strokePath()
            }
        case let .pen(points):
            cg.addPath(Self.smoothPath(points))
            cg.strokePath()
        case let .highlighter(points):
            // One path stroked once, so overlapping parts of the stroke don't get darker.
            cg.setBlendMode(.multiply)
            cg.setAlpha(0.55)
            cg.setLineCap(.butt)
            cg.addPath(Self.smoothPath(points))
            cg.strokePath()
        case let .mosaicRect(r):
            cg.clip(to: r)
            effect(item.effect).draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        case let .mosaicBrush(points):
            cg.addPath(Self.smoothPath(points.count == 1 ? [points[0], points[0]] : points))
            cg.replacePathWithStrokedPath()
            cg.clip()
            effect(item.effect).draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        case let .text(text, origin, width):
            var attributes = AnnotationItem.textAttributes(color: item.color, size: item.size)
            switch item.style.text {
            case .plain:
                break
            case .background:
                // A pill in the chosen color, with black or white text on it.
                let box = item.bounds
                cg.addPath(CGPath(roundedRect: box, cornerWidth: min(6, box.height / 2), cornerHeight: min(6, box.height / 2), transform: nil))
                cg.fillPath()
                attributes[.foregroundColor] = Self.contrastingTextColor(for: item.color)
            case .outline:
                // Negative stroke width strokes and fills, so the letters keep their color with a contrasting edge.
                attributes[.strokeColor] = Self.contrastingTextColor(for: item.color)
                attributes[.strokeWidth] = -max(2.5, 30 / item.size)
            }
            NSAttributedString(string: text, attributes: attributes)
                .draw(with: CGRect(x: origin.x, y: origin.y, width: width, height: 100_000), options: [.usesLineFragmentOrigin])
        case let .magnifier(source, target, radius):
            let lens = radius * AnnotationItem.magnification
            let dx = target.x - source.x, dy = target.y - source.y, distance = max(hypot(dx, dy), 0.001)
            // Connector between the two circles' edges.
            if distance > radius + lens {
                cg.strokeLineSegments(between: [CGPoint(x: source.x + dx / distance * radius, y: source.y + dy / distance * radius),
                                                CGPoint(x: target.x - dx / distance * lens, y: target.y - dy / distance * lens)])
            }
            cg.strokeEllipse(in: CGRect(x: source.x - radius, y: source.y - radius, width: radius * 2, height: radius * 2))
            let lensRect = CGRect(x: target.x - lens, y: target.y - lens, width: lens * 2, height: lens * 2)
            cg.saveGState()
            cg.addEllipse(in: lensRect)
            cg.clip()
            // Map the lens back onto the source circle, enlarged.
            cg.translateBy(x: target.x, y: target.y)
            cg.scaleBy(x: AnnotationItem.magnification, y: AnnotationItem.magnification)
            cg.translateBy(x: -source.x, y: -source.y)
            cg.interpolationQuality = .none
            drawBase()
            cg.restoreGState()
            cg.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            cg.strokeEllipse(in: lensRect)
        case let .number(c):
            let d = item.size
            let circle = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
            cg.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor.black.withAlphaComponent(0.3).cgColor)
            cg.fillEllipse(in: circle)
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            cg.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            cg.setLineWidth(max(1.5, d / 16))
            cg.strokeEllipse(in: circle.insetBy(dx: 0.75, dy: 0.75))
            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: d * (number >= 10 ? 0.46 : 0.56), weight: .bold),
                .foregroundColor: Self.contrastingTextColor(for: item.color),
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2))
        }
    }

    static func contrastingTextColor(for color: NSColor) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    /// Quadratic curves through the midpoints of consecutive samples: smooth, but passes near every sample.
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            for p in points.dropFirst() { path.addLine(to: p) }
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    static func applyDash(_ dash: DashStyle, size: CGFloat, to cg: CGContext) {
        switch dash {
        case .solid: break
        case .dashed: cg.setLineDash(phase: 0, lengths: [max(4, size * 3), max(3, size * 2)])
        case .dotted:
            // Zero-length dashes with round caps are dots.
            cg.setLineCap(.round)
            cg.setLineDash(phase: 0, lengths: [0.01, max(3, size * 2)])
        }
    }

    /// A stroked shaft through `points` with filled heads: at the end, or at both ends for `.double`,
    /// or open V heads for `.open`.
    static func drawArrow(_ points: [CGPoint], head: ArrowHead, size: CGFloat, in cg: CGContext) {
        guard let tip = points.last, let beforeTip = points.dropLast().last(where: { hypot($0.x - tip.x, $0.y - tip.y) > 1 }) else { return }
        var shaft = points
        func trim(_ end: CGPoint, from previous: CGPoint) -> CGPoint {
            // Stop the stroke inside the head, so the round cap doesn't poke out of the tip.
            let length = hypot(end.x - previous.x, end.y - previous.y)
            let head = min(AnnotationItem.arrowHeadLength(size), length * 0.6) * 0.8
            return CGPoint(x: end.x - (end.x - previous.x) / length * head, y: end.y - (end.y - previous.y) / length * head)
        }
        if head != .open { shaft[shaft.count - 1] = trim(tip, from: beforeTip) }
        let start = points[0]
        let afterStart = points.dropFirst().first(where: { hypot($0.x - start.x, $0.y - start.y) > 1 })
        if head == .double, let afterStart { shaft[0] = trim(start, from: afterStart) }
        cg.addLines(between: shaft)
        cg.strokePath()
        cg.setLineDash(phase: 0, lengths: [])
        switch head {
        case .tapered:
            cg.addPath(arrowHeadPath(from: beforeTip, to: tip, size: size))
            cg.fillPath()
        case .double:
            cg.addPath(arrowHeadPath(from: beforeTip, to: tip, size: size))
            if let afterStart { cg.addPath(arrowHeadPath(from: afterStart, to: start, size: size)) }
            cg.fillPath()
        case .open:
            let dx = tip.x - beforeTip.x, dy = tip.y - beforeTip.y
            let length = max(hypot(dx, dy), 0.001)
            let ux = dx / length, uy = dy / length
            let arm = min(AnnotationItem.arrowHeadLength(size), length * 0.6)
            let spread = arm * 0.6
            let base = CGPoint(x: tip.x - ux * arm, y: tip.y - uy * arm)
            cg.addLines(between: [CGPoint(x: base.x - uy * spread, y: base.y + ux * spread), tip,
                                  CGPoint(x: base.x + uy * spread, y: base.y - ux * spread)])
            cg.strokePath()
        }
    }

    /// A plain triangular head at `tip`, pointing away from `tail`; used by polyline arrows whose shaft is a stroke.
    static func arrowHeadPath(from tail: CGPoint, to tip: CGPoint, size: CGFloat) -> CGPath {
        let dx = tip.x - tail.x, dy = tip.y - tail.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length, uy = dy / length
        let headLength = min(AnnotationItem.arrowHeadLength(size), length * 0.6)
        let headHalf = min(AnnotationItem.arrowHeadWidth(size) / 2, headLength * 0.7)
        let base = CGPoint(x: tip.x - ux * headLength, y: tip.y - uy * headLength)
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: base.x - uy * headHalf, y: base.y + ux * headHalf))
        path.addLine(to: CGPoint(x: base.x + uy * headHalf, y: base.y - ux * headHalf))
        path.closeSubpath()
        return path
    }

    /// A filled arrow whose shaft widens from the tail towards the head, like WeChat's and QQ's.
    static func arrowPath(from tail: CGPoint, to tip: CGPoint, size: CGFloat) -> CGPath? {
        let dx = tip.x - tail.x, dy = tip.y - tail.y
        let length = hypot(dx, dy)
        guard length > 1 else { return nil }
        let ux = dx / length, uy = dy / length
        let nx = -uy, ny = ux
        let headLength = min(AnnotationItem.arrowHeadLength(size), length * 0.6)
        let headHalf = min(AnnotationItem.arrowHeadWidth(size) / 2, headLength * 0.7)
        let tailHalf = max(0.5, size * 0.15)
        let neckHalf = min(max(size * 0.6, 1.5), headHalf * 0.6)
        let base = CGPoint(x: tip.x - ux * headLength, y: tip.y - uy * headLength)

        func p(_ o: CGPoint, _ half: CGFloat) -> CGPoint { CGPoint(x: o.x + nx * half, y: o.y + ny * half) }
        let path = CGMutablePath()
        path.move(to: p(tail, tailHalf))
        path.addLine(to: p(base, neckHalf))
        path.addLine(to: p(base, headHalf))
        path.addLine(to: tip)
        path.addLine(to: p(base, -headHalf))
        path.addLine(to: p(base, -neckHalf))
        path.addLine(to: p(tail, -tailHalf))
        path.closeSubpath()
        return path
    }
}
