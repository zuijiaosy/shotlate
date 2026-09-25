import AppKit
import ApplicationServices
import SnapCore

/// Holds ⌥⌘ and drags anywhere to capture that area. Uses an event tap, so it needs Accessibility permission.
final class SuperSnip {
    static let shared = SuperSnip()
    static let modifiers: CGEventFlags = [.maskAlternate, .maskCommand]
    static let label = "⌥⌘ + 拖动"

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tracker = SuperSnipTracker()
    private var frame: NSWindow?

    var isRunning: Bool { tap != nil }

    /// Starts or stops listening. Returns false when the event tap could not be created (no permission).
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        if !enabled {
            stop()
            return true
        }
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: { _, type, event, _ in
            SuperSnip.shared.handle(type, event)
        }, userInfo: nil) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        hideFrame()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let kind: SuperSnipTracker.Event
        switch type {
        case .leftMouseDown: kind = .down
        case .leftMouseDragged: kind = .dragged
        case .leftMouseUp: kind = .up
        default: return Unmanaged.passUnretained(event)
        }
        let held = event.flags.intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift]) == Self.modifiers
        // Capture already running: leave the mouse alone.
        guard CaptureSession.current == nil || tracker.start != nil else { return Unmanaged.passUnretained(event) }
        switch tracker.handle(kind, at: event.location, modifiersHeld: held) {
        case .pass:
            return Unmanaged.passUnretained(event)
        case let .track(rect):
            if let rect { showFrame(Self.cocoa(rect)) }
            return nil
        case let .finish(rect):
            hideFrame()
            let area = Self.cocoa(rect)
            DispatchQueue.main.async { CaptureSession.begin(initialSelection: area) }
            return nil
        case .cancel:
            hideFrame()
            return nil
        }
    }

    /// CG global (top-left origin) → Cocoa global.
    static func cocoa(_ r: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    /// A thin frame following the drag, so the area is visible before the capture opens.
    private func showFrame(_ rect: CGRect) {
        if frame == nil {
            let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = .screenSaver
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            let view = NSView()
            view.wantsLayer = true
            view.layer?.borderColor = selectionBlue.cgColor
            view.layer?.borderWidth = 2
            view.layer?.backgroundColor = selectionBlue.withAlphaComponent(0.08).cgColor
            w.contentView = view
            frame = w
        }
        frame?.setFrame(rect, display: true)
        frame?.orderFrontRegardless()
    }

    private func hideFrame() {
        frame?.orderOut(nil)
    }
}
