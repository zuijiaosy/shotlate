import CoreGraphics
import Foundation

public enum ScreenCorner: String, CaseIterable, Codable {
    case topLeft, topRight, bottomLeft, bottomRight
}

/// Fires when the pointer rests in a screen corner. Works in Cocoa coordinates (origin bottom-left).
/// A corner fires once per visit: the pointer has to leave it before it can fire again.
public struct HotCornerDetector {
    public var dwell: TimeInterval
    public var reach: CGFloat
    private var current: (corner: ScreenCorner, screen: Int, since: Date)?
    private var fired = false

    public init(dwell: TimeInterval = 0.3, reach: CGFloat = 3) {
        self.dwell = dwell
        self.reach = reach
    }

    /// Which corner of which screen `p` is in, if any.
    public func corner(at p: CGPoint, screens: [CGRect]) -> (ScreenCorner, Int)? {
        for (i, s) in screens.enumerated() where s.insetBy(dx: -1, dy: -1).contains(p) {
            let left = p.x <= s.minX + reach, right = p.x >= s.maxX - reach - 1
            let bottom = p.y <= s.minY + reach, top = p.y >= s.maxY - reach - 1
            switch (left, right, top, bottom) {
            case (true, _, true, _): return (.topLeft, i)
            case (_, true, true, _): return (.topRight, i)
            case (true, _, _, true): return (.bottomLeft, i)
            case (_, true, _, true): return (.bottomRight, i)
            default: return nil
            }
        }
        return nil
    }

    /// Call on every pointer update (and on a timer while the pointer is still). Returns the corner when it fires.
    public mutating func update(_ p: CGPoint, screens: [CGRect], now: Date) -> ScreenCorner? {
        guard let (corner, screen) = corner(at: p, screens: screens) else {
            current = nil
            fired = false
            return nil
        }
        if let c = current, c.corner == corner, c.screen == screen {
            if !fired, now.timeIntervalSince(c.since) >= dwell {
                fired = true
                return corner
            }
            return nil
        }
        current = (corner, screen, now)
        fired = false
        return nil
    }
}
