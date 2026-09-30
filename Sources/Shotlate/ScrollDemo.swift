import AppKit

/// End-to-end check of the long screenshot: shows a window with a sticky header and an input bar with a
/// blinking caret around a long list, scrolls it with real trackpad-style scroll events (gesture plus
/// momentum) while `ScrollCaptureController` captures the whole content area, and writes the result.
/// With `--auto`, the controller's auto scroll drives it instead.
/// Needs Screen Recording permission for the process that runs it.
///
///   Shotlate --scroll-demo output.png [--auto]
enum ScrollDemo {
    static let rows = 60
    static let rowHeight: CGFloat = 36

    @MainActor
    static func run(output: URL, auto: Bool) {
        guard let screen = NSScreen.main else { exit(1) }
        let visible = screen.visibleFrame
        let size = CGSize(width: 420, height: 440)
        let window = NSWindow(contentRect: CGRect(x: visible.minX + 40, y: visible.maxY - size.height - 40, width: size.width, height: size.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Shotlate 长截图测试"
        window.level = .floating
        window.isReleasedWhenClosed = false

        let root = NSView(frame: CGRect(origin: .zero, size: size))
        let headerHeight: CGFloat = 44, footerHeight: CGFloat = 56
        let scroll = NSScrollView(frame: CGRect(x: 0, y: footerHeight, width: size.width, height: size.height - headerHeight - footerHeight))
        scroll.hasVerticalScroller = true
        scroll.documentView = ListView(frame: CGRect(x: 0, y: 0, width: size.width, height: CGFloat(rows) * rowHeight))
        root.addSubview(scroll)
        root.addSubview(HeaderView(frame: CGRect(x: 0, y: size.height - headerHeight, width: size.width, height: headerHeight)))
        let footer = FooterView(frame: CGRect(x: 0, y: 0, width: size.width, height: footerHeight))
        root.addSubview(footer)
        window.contentView = root
        // Events posted to our own process go to the key window, so the demo has to be the active app.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        scroll.documentView?.scroll(.zero)
        // A caret blinking in the input bar, as in chat apps: it must not count as scrolled content.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            footer.caretVisible.toggle()
            footer.needsDisplay = true
        }

        // Capture header, list and input bar, like a user selecting a chat window's content area.
        let contentOnScreen = window.convertToScreen(root.convert(root.bounds, to: nil))
        let maxOffset = (scroll.documentView?.frame.height ?? 0) - scroll.contentSize.height
        var offset: CGFloat { scroll.contentView.bounds.origin.y }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let controller = ScrollCaptureController.start(rect: contentOnScreen, screen: screen, excludeOwnWindows: false)
            // Auto scroll: drive the NSScrollView directly — no Accessibility permission needed in the demo.
            // Auto scroll drives NSScrollView directly — no Accessibility permission needed in tests.
            controller.autoScrollBlock = { [weak scroll] delta in
                guard let scroll else { return }
                let docHeight = scroll.documentView?.frame.height ?? 0
                let maxOffset = docHeight - scroll.contentSize.height
                let current = scroll.contentView.bounds.origin.y
                let next = min(maxOffset, max(0, current + delta))
                scroll.contentView.scroll(to: CGPoint(x: 0, y: next))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            controller.onFinished = { image in
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: output)
                print("Stitched \(image.width) × \(image.height) px → \(output.path)")
                exit(0)
            }
            // Give the controller time to take the first frame at the top before scrolling.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if auto {
                    controller.toggleAutoScroll()
                    return
                }
                var flung = false
                func swipe() {
                    if offset >= maxOffset - 1 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { controller.finish() }
                        return
                    }
                    // Once, jump further than the visible list so stitching loses track, then come back.
                    if !flung, offset >= 500 {
                        flung = true
                        let resume = offset
                        scroll.contentView.scroll(to: CGPoint(x: 0, y: min(maxOffset, resume + scroll.contentSize.height * 1.5)))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            scroll.contentView.scroll(to: CGPoint(x: 0, y: resume))
                            scroll.reflectScrolledClipView(scroll.contentView)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { swipe() }
                        }
                        return
                    }
                    let swipeCenter = CGPoint(x: contentOnScreen.midX, y: (NSScreen.screens.first?.frame.height ?? 0) - contentOnScreen.midY)
                TrackpadSwipe.send(at: swipeCenter, distance: 260, pid: ProcessInfo.processInfo.processIdentifier) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { swipe() }
                    }
                }
                swipe()
            }
        }
    }

    /// A two-finger swipe as the trackpad sends it: gesture phases with pixel deltas at 60 Hz, then
    /// decaying momentum events after the fingers lift.
    enum TrackpadSwipe {
        static func send(at point: CGPoint, distance: CGFloat, pid: pid_t, completion: @escaping () -> Void) {
            var events: [(scroll: Int32, phase: Int64, momentum: Int64)] = []
            let fingers = 8
            for i in 0..<fingers { events.append((Int32(-distance * 0.5 / CGFloat(fingers)), i == 0 ? 1 : 2, 0)) }
            events.append((0, 4, 0))
            // Momentum covers the other half of the distance, decaying like the system's inertia.
            var v = distance * 0.5 * 0.12
            var first = true
            while v >= 1 {
                events.append((Int32(-v.rounded()), 0, first ? 1 : 2))
                first = false
                v *= 0.88
            }
            events.append((0, 0, 3))
            for (i, e) in events.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) / 60) {
                    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: e.scroll, wheel2: 0, wheel3: 0) else { return }
                    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: e.phase)
                    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: e.momentum)
                    event.location = point
                    event.postToPid(pid)
                    if i == events.count - 1 { completion() }
                }
            }
        }
    }

    private final class HeaderView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor(srgbRed: 0.17, green: 0.18, blue: 0.2, alpha: 1).setFill()
            bounds.fill()
            NSAttributedString(string: "Sticky Header", attributes: [.font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.white])
                .draw(at: CGPoint(x: 14, y: 12))
        }
    }

    private final class FooterView: NSView {
        var caretVisible = true
        override func draw(_ dirtyRect: NSRect) {
            NSColor(white: 0.93, alpha: 1).setFill()
            bounds.fill()
            let field = bounds.insetBy(dx: 12, dy: 10)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: field, xRadius: 8, yRadius: 8).fill()
            NSAttributedString(string: "Message", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor])
                .draw(at: CGPoint(x: field.minX + 14, y: field.minY + 10))
            if caretVisible {
                NSColor.controlAccentColor.setFill()
                CGRect(x: field.minX + 10, y: field.minY + 8, width: 2, height: 20).fill()
            }
        }
    }

    private final class ListView: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill()
            dirtyRect.fill()
            for i in 0..<ScrollDemo.rows {
                let row = CGRect(x: 0, y: CGFloat(i) * ScrollDemo.rowHeight, width: bounds.width, height: ScrollDemo.rowHeight)
                guard row.intersects(dirtyRect) else { continue }
                (i % 2 == 0 ? NSColor(white: 0.97, alpha: 1) : NSColor.white).setFill()
                row.fill()
                NSColor(hue: CGFloat(i) / CGFloat(ScrollDemo.rows), saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
                CGRect(x: 12, y: row.minY + 10, width: 16, height: 16).fill()
                NSAttributedString(string: "Row \(i + 1) · The quick brown fox jumps over the lazy dog",
                                   attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
                    .draw(at: CGPoint(x: 38, y: row.minY + 9))
            }
        }
    }
}
