import CoreGraphics
import Foundation

/// One line of text recognized by Vision, in a top-left-origin coordinate space (points).
public struct OCRLine: Equatable, Sendable {
    public var text: String
    public var rect: CGRect

    public init(text: String, rect: CGRect) {
        self.text = text
        self.rect = rect
    }
}

public enum VisionGeometry {
    /// Converts a Vision `boundingBox` (normalized 0...1, origin bottom-left)
    /// into a rect inside `bounds`, which uses a top-left origin.
    public static func rect(fromNormalized b: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + b.minX * bounds.width,
               y: bounds.minY + (1 - b.maxY) * bounds.height,
               width: b.width * bounds.width,
               height: b.height * bounds.height)
    }
}

/// A paragraph made of one or more adjacent OCR lines; the unit that gets translated.
public struct TextBlock: Equatable, Sendable {
    public var id: Int
    public var lines: [OCRLine]

    public init(id: Int, lines: [OCRLine]) {
        self.id = id
        self.lines = lines
    }

    public var rect: CGRect {
        lines.reduce(CGRect.null) { $0.union($1.rect) }
    }

    public var lineHeight: CGFloat {
        guard !lines.isEmpty else { return 0 }
        return lines.reduce(0) { $0 + $1.rect.height } / CGFloat(lines.count)
    }

    /// Lines joined into one string. A trailing hyphen is treated as a word break.
    public var text: String {
        var result = ""
        for line in lines {
            let t = line.text.trimmingCharacters(in: .whitespaces)
            if result.isEmpty {
                result = t
            } else if result.hasSuffix("-"), let first = t.first, first.isLowercase {
                result.removeLast()
                result += t
            } else {
                result += " " + t
            }
        }
        return result
    }
}

public enum TextBlockBuilder {
    /// Groups lines into paragraphs: a line joins a block when it starts below the block's
    /// last line with a small gap, has a similar height and a roughly aligned left edge.
    public static func group(_ lines: [OCRLine]) -> [TextBlock] {
        let sorted = lines.sorted {
            $0.rect.minY != $1.rect.minY ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX
        }
        var groups: [[OCRLine]] = []
        for line in sorted {
            if let index = groups.lastIndex(where: { canMerge($0[$0.count - 1], line) }) {
                groups[index].append(line)
            } else {
                groups.append([line])
            }
        }
        return groups.enumerated().map { TextBlock(id: $0.offset, lines: $0.element) }
    }

    static func canMerge(_ upper: OCRLine, _ lower: OCRLine) -> Bool {
        let small = min(upper.rect.height, lower.rect.height)
        let large = max(upper.rect.height, lower.rect.height)
        guard small > 0, large / small < 1.4 else { return false }
        let gap = lower.rect.minY - upper.rect.maxY
        guard gap >= -small * 0.3, gap < small * 0.8 else { return false }
        return abs(upper.rect.minX - lower.rect.minX) < small
    }

    /// Whether a block is worth sending for translation: it must contain Latin words,
    /// must not be mostly CJK already, and must not be a bare URL, path or number.
    public static func shouldTranslate(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var latin = 0
        var cjk = 0
        for scalar in t.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF: cjk += 1
            default: break
            }
        }
        guard latin >= 2, cjk < latin else { return false }
        let skipPatterns = [
            #"^(https?://|www\.)\S+$"#,   // URL
            #"^[~/.]?[\w.-]*/[\w./-]*$"#,  // file path
            #"^[\w.+-]+@[\w-]+\.[\w.]+$"#, // email
            #"^v?\d+(\.\d+)+[a-z]?$"#,     // version number
        ]
        return !skipPatterns.contains { t.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }
}
