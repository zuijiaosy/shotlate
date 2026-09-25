import CoreGraphics

/// "Super snip": holding the modifiers and dragging draws a capture area anywhere, without pressing the hotkey first.
/// Fed raw mouse events; decides which ones to swallow and when an area is finished.
public struct SuperSnipTracker {
    public enum Event { case down, dragged, up }
    public enum Outcome: Equatable {
        /// Let the event through to the app under the pointer.
        case pass
        /// Swallow it; the area is now `rect` (nil before the drag moves).
        case track(CGRect?)
        case finish(CGRect)
        /// A click without a drag: swallowed, nothing captured.
        case cancel
    }

    public private(set) var start: CGPoint?

    public init() {}

    /// `modifiersHeld` says whether exactly the super-snip modifiers are down.
    public mutating func handle(_ event: Event, at p: CGPoint, modifiersHeld: Bool) -> Outcome {
        switch event {
        case .down:
            guard modifiersHeld else { return .pass }
            start = p
            return .track(nil)
        case .dragged:
            guard let start else { return .pass }
            return .track(Self.rect(start, p))
        case .up:
            guard let start else { return .pass }
            self.start = nil
            let r = Self.rect(start, p)
            return r.width >= 4 && r.height >= 4 ? .finish(r) : .cancel
        }
    }

    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
