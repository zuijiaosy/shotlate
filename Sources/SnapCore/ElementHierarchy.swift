import CoreGraphics

/// One on-screen UI element (button, list, toolbar, panel…) and the element that contains it.
public struct UIElementNode: Equatable {
    public var rect: CGRect
    public var parent: Int?

    public init(rect: CGRect, parent: Int?) {
        self.rect = rect
        self.parent = parent
    }
}

/// Picks what to highlight under the pointer when capturing: the smallest element there, then its ancestors,
/// so the scroll wheel can walk from a button out to its toolbar and window.
public struct ElementHierarchy {
    public let nodes: [UIElementNode]
    /// Nodes that draw nothing where they claim to be; they still link their children to their parents.
    public let excluded: Set<Int>

    public init(nodes: [UIElementNode], excluded: Set<Int> = []) {
        self.nodes = nodes
        self.excluded = excluded
    }

    /// Excludes the nodes whose frames don't match `screenshot` (see `ElementVisibility`). `scale` is pixels per point.
    public init(nodes: [UIElementNode], screenshot: PixelBuffer, scale: CGFloat) {
        var excluded = Set<Int>()
        for (i, node) in nodes.enumerated() where ElementVisibility.cutsThroughContent(node.rect, in: screenshot, scale: scale) {
            excluded.insert(i)
        }
        self.init(nodes: nodes, excluded: excluded)
    }

    /// Rects containing `p`, innermost first. Only elements inside `container` (the frontmost window at `p`) count,
    /// since elements of windows further back are hidden under it. The container itself ends the chain.
    public func chain(at p: CGPoint, within container: CGRect?) -> [CGRect] {
        func inside(_ r: CGRect) -> Bool {
            guard let container else { return true }
            return container.insetBy(dx: -1, dy: -1).contains(r)
        }
        var best: Int?
        for (i, node) in nodes.enumerated() where node.rect.contains(p) && inside(node.rect) && !excluded.contains(i) {
            if best == nil || node.rect.width * node.rect.height < nodes[best!].rect.width * nodes[best!].rect.height {
                best = i
            }
        }
        var chain: [CGRect] = []
        var seen = Set<Int>()
        var current = best
        while let i = current, !seen.contains(i) {
            seen.insert(i)
            let r = nodes[i].rect
            if !excluded.contains(i), r.contains(p), inside(r), !chain.contains(where: { Self.same($0, r) }) {
                // Ancestors are recorded from the outside in, but frames sometimes overshoot; keep only real growth.
                if let last = chain.last, !r.insetBy(dx: -1, dy: -1).contains(last) {
                    current = nodes[i].parent
                    continue
                }
                chain.append(r)
            }
            current = nodes[i].parent
        }
        if let container, !chain.contains(where: { Self.same($0, container) }) {
            chain.append(container)
        }
        return chain
    }

    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }
}

/// Checks an element frame against what is on screen. Accessibility trees contain elements that draw nothing where
/// their frame says (transparent overlays, clipped or off-flow web nodes); their edges run straight through text and
/// images, which the edges of a visible element never do: those sit on a border or in blank space.
public enum ElementVisibility {
    /// Whether an edge of `rect` (points, top-left origin) cuts through what `buffer` shows. `scale` is pixels per point.
    public static func cutsThroughContent(_ rect: CGRect, in buffer: PixelBuffer, scale: CGFloat) -> Bool {
        let minX = Int((rect.minX * scale).rounded()), maxX = Int((rect.maxX * scale).rounded())
        let minY = Int((rect.minY * scale).rounded()), maxY = Int((rect.maxY * scale).rounded())
        guard maxX - minX >= 8, maxY - minY >= 8 else { return false }
        // Compare the line one point outside each edge with the line one point inside it.
        let gap = max(1, Int(scale.rounded()))
        let xs = max(0, minX)..<min(buffer.width - 1, maxX), ys = max(0, minY)..<min(buffer.height - 1, maxY)
        if minY - gap >= 0, minY + gap - 1 < buffer.height,
           cut(xs, { buffer.pixel(x: $0, y: minY - gap) }, { buffer.pixel(x: $0, y: minY + gap - 1) }) { return true }
        if maxY + gap - 1 < buffer.height, maxY - gap >= 0,
           cut(xs, { buffer.pixel(x: $0, y: maxY + gap - 1) }, { buffer.pixel(x: $0, y: maxY - gap) }) { return true }
        if minX - gap >= 0, minX + gap - 1 < buffer.width,
           cut(ys, { buffer.pixel(x: minX - gap, y: $0) }, { buffer.pixel(x: minX + gap - 1, y: $0) }) { return true }
        if maxX + gap - 1 < buffer.width, maxX - gap >= 0,
           cut(ys, { buffer.pixel(x: maxX + gap - 1, y: $0) }, { buffer.pixel(x: maxX - gap, y: $0) }) { return true }
        return false
    }

    /// Something crosses the edge at `i` when the outside and inside lines agree there and both change sharply
    /// towards `i + 1`: a stroke or image edge running across. A few such crossings are noise; many mean a cut.
    private static func cut(_ range: Range<Int>, _ outside: (Int) -> RGBA, _ inside: (Int) -> RGBA) -> Bool {
        guard range.count >= 8 else { return false }
        let step = max(1, range.count / 2000)
        var samples = 0, crossings = 0
        for i in stride(from: range.lowerBound, to: range.upperBound, by: step) {
            samples += 1
            let o = outside(i), n = inside(i)
            guard o.distance(to: n) < 48 else { continue }
            if o.distance(to: outside(i + 1)) >= 96, n.distance(to: inside(i + 1)) >= 96 { crossings += 1 }
        }
        return crossings >= max(4, samples / 60)
    }
}
