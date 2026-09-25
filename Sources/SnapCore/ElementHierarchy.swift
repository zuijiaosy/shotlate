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

    public init(nodes: [UIElementNode]) {
        self.nodes = nodes
    }

    /// Rects containing `p`, innermost first. Only elements inside `container` (the frontmost window at `p`) count,
    /// since elements of windows further back are hidden under it. The container itself ends the chain.
    public func chain(at p: CGPoint, within container: CGRect?) -> [CGRect] {
        func inside(_ r: CGRect) -> Bool {
            guard let container else { return true }
            return container.insetBy(dx: -1, dy: -1).contains(r)
        }
        var best: Int?
        for (i, node) in nodes.enumerated() where node.rect.contains(p) && inside(node.rect) {
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
            if r.contains(p), inside(r), !chain.contains(where: { Self.same($0, r) }) {
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
