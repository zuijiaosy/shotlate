import AppKit
import ApplicationServices
import SnapCore

/// Reads the frames of UI elements (buttons, fields, lists, toolbars…) through the Accessibility API,
/// so the capture overlay can highlight them. Collected up front because once the overlay is up,
/// asking "what is under the pointer" would only find the overlay itself.
enum ElementCollector {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Apps owning the frontmost normal windows, front to back, without Snap itself.
    static func frontApps(limit: Int = 4) -> [pid_t] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let own = ProcessInfo.processInfo.processIdentifier
        var pids: [pid_t] = []
        for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init), pid != own, !pids.contains(pid) else { continue }
            pids.append(pid)
            if pids.count == limit { break }
        }
        return pids
    }

    /// Element frames in Cocoa global coordinates, each with the index of its parent. Stops at `budget` seconds
    /// or `maxNodes`, whichever comes first, so a huge web page can't delay the capture.
    static func collect(pids: [pid_t], budget: TimeInterval = 0.35, maxNodes: Int = 4000) -> [UIElementNode] {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        let deadline = Date().addingTimeInterval(budget)
        var nodes: [UIElementNode] = []
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            var queue: [(element: AXUIElement, parent: Int?, depth: Int)] = copyElements(app, kAXWindowsAttribute).map { ($0, nil, 0) }
            var head = 0
            while head < queue.count, nodes.count < maxNodes, Date() < deadline {
                let (element, parent, depth) = queue[head]
                head += 1
                guard let cg = frame(of: element), cg.width >= 4, cg.height >= 4 else { continue }
                let rect = CGRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
                nodes.append(UIElementNode(rect: rect, parent: parent))
                guard depth < 30 else { continue }
                let index = nodes.count - 1
                for child in copyElements(element, kAXChildrenAttribute) { queue.append((child, index, depth + 1)) }
            }
        }
        return nodes
    }

    private static func copyElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    /// Frame in CG global coordinates (top-left origin of the main display).
    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
