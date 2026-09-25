import CoreGraphics
import Foundation

/// Parses a typed selection size such as `800x600`, `800 × 600`, `800*600` or `800, 600`.
public enum SizeText {
    public static func parse(_ text: String) -> CGSize? {
        let separators = CharacterSet(charactersIn: "x×X*,， \t")
        let parts = text.components(separatedBy: separators).filter { !$0.isEmpty }
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w >= 1, h >= 1 else { return nil }
        return CGSize(width: w, height: h)
    }
}

/// A width:height ratio for locking the selection's shape.
public struct AspectRatio: Equatable {
    public var width: CGFloat
    public var height: CGFloat
    public var value: CGFloat { width / height }
    public var label: String { "\(Int(width)):\(Int(height))" }

    public init?(width: CGFloat, height: CGFloat) {
        guard width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
    }

    /// "16:9" or "16/9".
    public init?(_ text: String) {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == "/" }).compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        self.init(width: CGFloat(parts[0]), height: CGFloat(parts[1]))
    }

    public static let presets = ["1:1", "4:3", "3:4", "16:9", "9:16", "3:2", "2:3"].compactMap(AspectRatio.init)
}

public enum SelectionGeometry {
    /// The largest rect with `ratio` that grows from `anchor` towards `p` and covers the dragged box in its longer direction.
    public static func fit(anchor a: CGPoint, toward p: CGPoint, ratio: CGFloat) -> CGRect {
        let dx = p.x - a.x, dy = p.y - a.y
        let w = max(abs(dx), abs(dy) * ratio)
        let h = w / ratio
        return CGRect(x: dx >= 0 ? a.x : a.x - w, y: dy >= 0 ? a.y : a.y - h, width: w, height: h)
    }

    /// Shrinks `r` (keeping its ratio and the corner at `anchor`) until it fits inside `bounds`.
    public static func clamp(_ r: CGRect, anchor a: CGPoint, in bounds: CGRect) -> CGRect {
        guard r.width > 0, r.height > 0 else { return r }
        let growsRight = r.midX >= a.x, growsDown = r.midY >= a.y
        let availableW = growsRight ? bounds.maxX - a.x : a.x - bounds.minX
        let availableH = growsDown ? bounds.maxY - a.y : a.y - bounds.minY
        let scale = min(1, max(0, availableW) / r.width, max(0, availableH) / r.height)
        let w = r.width * scale, h = r.height * scale
        return CGRect(x: growsRight ? a.x : a.x - w, y: growsDown ? a.y : a.y - h, width: w, height: h)
    }

    /// Applies `ratio` to a rect that was just resized by dragging an edge: the dragged dimension wins,
    /// the other follows, and the top-left stays put.
    public static func fitEdge(_ r: CGRect, ratio: CGFloat, horizontalEdge: Bool, in bounds: CGRect) -> CGRect {
        var out = r
        if horizontalEdge {
            out.size.height = r.width / ratio
        } else {
            out.size.width = r.height * ratio
        }
        return clamp(out, anchor: CGPoint(x: out.minX, y: out.minY), in: bounds)
    }
}
