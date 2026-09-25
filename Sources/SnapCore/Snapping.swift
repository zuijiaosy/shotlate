import CoreGraphics

/// Magnetic edges for dragging pins: an edge within `threshold` of another rect's edge lines up with it.
public enum Snapping {
    /// Snaps each axis independently to the nearest edge. Edges only attract when the rects are side by side
    /// on the other axis (their spans overlap), so a pin across the screen doesn't jump to an unrelated window.
    public static func snap(_ frame: CGRect, to targets: [CGRect], threshold: CGFloat = 12) -> CGRect {
        var bestX: CGFloat?, bestY: CGFloat?
        func consider(_ delta: CGFloat, _ best: inout CGFloat?) {
            if abs(delta) <= threshold, best == nil || abs(delta) < abs(best!) { best = delta }
        }
        for t in targets {
            let overlapsVertically = frame.minY < t.maxY + threshold && frame.maxY > t.minY - threshold
            let overlapsHorizontally = frame.minX < t.maxX + threshold && frame.maxX > t.minX - threshold
            if overlapsVertically {
                for edge in [t.minX, t.maxX] {
                    consider(edge - frame.minX, &bestX)
                    consider(edge - frame.maxX, &bestX)
                }
            }
            if overlapsHorizontally {
                for edge in [t.minY, t.maxY] {
                    consider(edge - frame.minY, &bestY)
                    consider(edge - frame.maxY, &bestY)
                }
            }
        }
        return frame.offsetBy(dx: bestX ?? 0, dy: bestY ?? 0)
    }
}
