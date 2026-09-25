import AppKit

/// End-to-end check of the long screenshot: shows a window with a sticky header over a long list,
/// scrolls it programmatically while `ScrollCaptureController` captures the list area, and writes the result.
/// Needs Screen Recording permission for the process that runs it.
///
///   Snap --scroll-demo output.png
enum ScrollDemo {
    @MainActor
    static func run(output: URL) {
        guard let screen = NSScreen.main else { exit(1) }
        let visible = screen.visibleFrame
        let size = CGSize(width: 420, height: 380)
        let window = NSWindow(contentRect: CGRect(x: visible.minX + 40, y: visible.maxY - size.height - 40, width: size.width, height: size.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Snap 长截图测试"
        window.level = .floating
        window.isReleasedWhenClosed = false

        let root = NSView(frame: CGRect(origin: .zero, size: size))
        let headerHeight: CGFloat = 44
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: size.width, height: size.height - headerHeight))
        scroll.hasVerticalScroller = true
        scroll.documentView = ListView(frame: CGRect(x: 0, y: 0, width: size.width, height: 60 * 36))
        root.addSubview(scroll)
        let header = HeaderView(frame: CGRect(x: 0, y: size.height - headerHeight, width: size.width, height: headerHeight))
        root.addSubview(header)
        window.contentView = root
        window.orderFrontRegardless()
        scroll.documentView?.scroll(.zero)

        // Capture the header and the list, like a user selecting an app's content area.
        let contentOnScreen = window.convertToScreen(root.convert(root.bounds, to: nil))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let controller = ScrollCaptureController.start(rect: contentOnScreen, screen: screen, excludeOwnWindows: false)
            controller.onFinished = { image in
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: output)
                print("Stitched \(image.width) × \(image.height) px → \(output.path)")
                exit(0)
            }
            var offset: CGFloat = 0
            let maxOffset = (scroll.documentView?.frame.height ?? 0) - scroll.contentSize.height
            // Give the controller time to take the first frame at the top before scrolling.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
                offset = min(offset + 23, maxOffset)
                scroll.contentView.scroll(to: CGPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
                if offset >= maxOffset {
                    timer.invalidate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { controller.finish() }
                }
            } }
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

    private final class ListView: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill()
            dirtyRect.fill()
            for i in 0..<60 {
                let row = CGRect(x: 0, y: CGFloat(i) * 36, width: bounds.width, height: 36)
                guard row.intersects(dirtyRect) else { continue }
                (i % 2 == 0 ? NSColor(white: 0.97, alpha: 1) : NSColor.white).setFill()
                row.fill()
                NSColor(hue: CGFloat(i) / 60, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
                CGRect(x: 12, y: row.minY + 10, width: 16, height: 16).fill()
                NSAttributedString(string: "Row \(i + 1) · The quick brown fox jumps over the lazy dog",
                                   attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
                    .draw(at: CGPoint(x: 38, y: row.minY + 9))
            }
        }
    }
}
