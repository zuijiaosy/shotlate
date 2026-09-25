import CoreGraphics
import Foundation

/// One recognized line with a box for every character, so a drag can select part of it.
public struct GlyphLine: Equatable, Sendable {
    public var text: String
    public var rect: CGRect
    /// One box per `Character` of `text`, left to right, each as tall as the line.
    public private(set) var boxes: [CGRect]
    let characters: [Character]

    /// `raw` holds Vision's box for each character, or nil where it gave none. Vision boxes a whole word
    /// for every character of it in some scripts, so a run of equal boxes is shared out evenly, and
    /// characters without a box (mostly spaces) fill the gap between their neighbours.
    public init(text: String, rect: CGRect, boxes raw: [CGRect?]) {
        self.text = text
        self.rect = rect
        characters = Array(text)
        let count = characters.count
        // Vision gives spaces an empty box at the image's edge; those count as missing.
        let usable = { (box: CGRect) in box.width > 0.01 && box.maxX > rect.minX - rect.height && box.minX < rect.maxX + rect.height }
        var spans: [(CGFloat, CGFloat)?] = raw.count == count
            ? raw.map { box in box.flatMap { usable($0) ? ($0.minX, $0.maxX) : nil } }
            : Array(repeating: nil, count: count)

        func share(_ span: (CGFloat, CGFloat), over range: Range<Int>) {
            let step = (span.1 - span.0) / CGFloat(range.count)
            for (n, i) in range.enumerated() { spans[i] = (span.0 + step * CGFloat(n), span.0 + step * CGFloat(n + 1)) }
        }

        var i = 0
        while i < count {
            guard let span = spans[i] else { i += 1; continue }
            var j = i + 1
            while j < count, let other = spans[j], abs(other.0 - span.0) < 0.01, abs(other.1 - span.1) < 0.01 { j += 1 }
            if j - i > 1 { share(span, over: i..<j) }
            i = j
        }
        i = 0
        while i < count {
            guard spans[i] == nil else { i += 1; continue }
            var j = i
            while j < count, spans[j] == nil { j += 1 }
            let low = i > 0 ? spans[i - 1]!.1 : rect.minX
            let high = j < count ? spans[j]!.0 : rect.maxX
            share((low, max(low, high)), over: i..<j)
            i = j
        }
        boxes = spans.map { CGRect(x: $0!.0, y: rect.minY, width: max(0, $0!.1 - $0!.0), height: rect.height) }
    }

    /// The caret offset closest to `x`: before the first character whose middle is right of it.
    func caret(atX x: CGFloat) -> Int {
        boxes.firstIndex { x < $0.midX } ?? boxes.count
    }

    /// The character under `x`, or the nearest one at either end.
    func characterIndex(atX x: CGFloat) -> Int {
        min(boxes.firstIndex { x < $0.maxX } ?? boxes.count - 1, boxes.count - 1)
    }
}

/// A caret between characters: `offset` characters into line `line` of a `TextLayout`.
public struct TextPosition: Comparable, Hashable, Sendable {
    public var line: Int
    public var offset: Int

    public init(line: Int, offset: Int) {
        self.line = line
        self.offset = offset
    }

    public static func < (a: TextPosition, b: TextPosition) -> Bool {
        a.line != b.line ? a.line < b.line : a.offset < b.offset
    }
}

/// A selected stretch of text; `anchor` stays where the drag started and `focus` follows the mouse.
public struct TextSpan: Equatable, Sendable {
    public var anchor: TextPosition
    public var focus: TextPosition

    public init(anchor: TextPosition, focus: TextPosition) {
        self.anchor = anchor
        self.focus = focus
    }

    public var start: TextPosition { min(anchor, focus) }
    public var end: TextPosition { max(anchor, focus) }
    public var isEmpty: Bool { anchor == focus }
}

/// The recognized text of an image, laid out for selecting with the mouse. All rects share the image's space.
public struct TextLayout: Equatable, Sendable {
    /// Lines in reading order, paragraph by paragraph, so a drag across lines selects what a reader would.
    public private(set) var lines: [GlyphLine]

    public init(_ lines: [GlyphLine]) {
        var unused = Array(lines.indices)
        var ordered: [GlyphLine] = []
        for block in TextBlockBuilder.group(lines.map { OCRLine(text: $0.text, rect: $0.rect) }) {
            for line in block.lines {
                guard let k = unused.firstIndex(where: { lines[$0].rect == line.rect && lines[$0].text == line.text }) else { continue }
                ordered.append(lines[unused.remove(at: k)])
            }
        }
        self.lines = ordered.filter { !$0.characters.isEmpty }
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// The caret under `point` when it is on a line (grown by `slop` so thin text is easy to hit), else nil.
    public func hitTest(_ point: CGPoint, slop: CGFloat = 3) -> TextPosition? {
        let hits = lines.indices.filter { lines[$0].rect.insetBy(dx: -slop, dy: -slop).contains(point) }
        guard let index = hits.min(by: { abs(lines[$0].rect.midY - point.y) < abs(lines[$1].rect.midY - point.y) }) else { return nil }
        return TextPosition(line: index, offset: lines[index].caret(atX: point.x))
    }

    /// The caret nearest to `point` anywhere, for extending a selection while the mouse leaves the text:
    /// the closest line vertically (so past a line's end means its end), then the closest horizontally.
    public func nearestPosition(to point: CGPoint) -> TextPosition? {
        func distance(_ r: CGRect) -> (CGFloat, CGFloat) {
            (max(r.minY - point.y, 0, point.y - r.maxY), max(r.minX - point.x, 0, point.x - r.maxX))
        }
        guard let index = lines.indices.min(by: { distance(lines[$0].rect) < distance(lines[$1].rect) }) else { return nil }
        return TextPosition(line: index, offset: lines[index].caret(atX: point.x))
    }

    /// The word under `point` (a run of CJK characters splits into words too), or the single character there.
    public func word(at point: CGPoint) -> TextSpan? {
        guard let hit = hitTest(point) else { return nil }
        let line = lines[hit.line]
        let index = line.characterIndex(atX: point.x)
        var found = index..<(index + 1)
        let text = line.text
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, range, _, stop in
            let lower = text.distance(from: text.startIndex, to: range.lowerBound)
            let upper = text.distance(from: text.startIndex, to: range.upperBound)
            if lower <= index, index < upper {
                found = lower..<upper
                stop = true
            }
        }
        return TextSpan(anchor: TextPosition(line: hit.line, offset: found.lowerBound), focus: TextPosition(line: hit.line, offset: found.upperBound))
    }

    /// The whole line under `point`.
    public func line(at point: CGPoint) -> TextSpan? {
        guard let hit = hitTest(point) else { return nil }
        return TextSpan(anchor: TextPosition(line: hit.line, offset: 0), focus: TextPosition(line: hit.line, offset: lines[hit.line].characters.count))
    }

    /// The highlight for `range`: one rect per line it touches.
    public func rects(for range: TextSpan) -> [CGRect] {
        spans(range).compactMap { line, span in
            guard !span.isEmpty else { return nil }
            let boxes = lines[line].boxes[span]
            return boxes.reduce(CGRect.null) { $0.union($1) }
        }
    }

    /// The selected text, one line of the image per line of text.
    public func text(for range: TextSpan) -> String {
        spans(range).map { line, span in String(lines[line].characters[span]) }.joined(separator: "\n")
    }

    private func spans(_ range: TextSpan) -> [(Int, Range<Int>)] {
        let start = range.start, end = range.end
        guard !range.isEmpty, start.line < lines.count, end.line < lines.count else { return [] }
        return (start.line...end.line).map { line in
            let count = lines[line].characters.count
            let lower = line == start.line ? min(start.offset, count) : 0
            let upper = line == end.line ? min(end.offset, count) : count
            return (line, lower..<max(lower, upper))
        }
    }
}
