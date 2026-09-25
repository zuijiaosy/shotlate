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
    /// Frames are clipped to the scroll area (or web view) holding them, so content scrolled under a toolbar
    /// only counts where it shows; subtrees scrolled out of sight entirely are skipped.
    static func collect(pids: [pid_t], budget: TimeInterval = 0.35, maxNodes: Int = 4000) -> [UIElementNode] {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        let deadline = Date().addingTimeInterval(budget)
        var nodes: [UIElementNode] = []
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            var queue: [(element: AXUIElement, parent: Int?, clip: CGRect, depth: Int)] =
                copyElements(app, kAXWindowsAttribute).map { ($0, nil, .infinite, 0) }
            var head = 0
            while head < queue.count, nodes.count < maxNodes, Date() < deadline {
                let (element, parent, clip, depth) = queue[head]
                head += 1
                guard let info = attributes(of: element) else { continue }
                var index = parent, childClip = clip
                if let cg = info.frame {
                    let visible = cg.intersection(clip)
                    // Sized but entirely out of view: its children are too.
                    if visible.isNull, cg.width >= 4, cg.height >= 4 { continue }
                    if visible.width >= 4, visible.height >= 4 {
                        nodes.append(UIElementNode(rect: CGRect(x: visible.minX, y: primaryHeight - visible.maxY,
                                                                width: visible.width, height: visible.height), parent: parent))
                        index = nodes.count - 1
                    }
                    if info.role == kAXScrollAreaRole || info.role == "AXWebArea" { childClip = visible }
                }
                // Tiny wrappers aren't recorded, but their children still are (under the nearest recorded ancestor).
                guard depth < 30 else { continue }
                for child in info.children { queue.append((child, index, childClip, depth + 1)) }
            }
        }
        return nodes
    }

    private static let queried = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute] as CFArray

    /// Role, frame (CG global coordinates, top-left origin of the main display) and children, in one round trip.
    private static func attributes(of element: AXUIElement) -> (role: String?, frame: CGRect?, children: [AXUIElement])? {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, queried, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let list = values as [AnyObject]?, list.count == 4 else { return nil }
        func value<T>(_ object: AnyObject, _ type: AXValueType, _ empty: T) -> T? {
            guard CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
            let axValue = object as! AXValue
            var result = empty
            guard AXValueGetType(axValue) == type, AXValueGetValue(axValue, type, &result) else { return nil }
            return result
        }
        var frame: CGRect?
        if let position = value(list[1], .cgPoint, CGPoint.zero), let size = value(list[2], .cgSize, CGSize.zero) {
            frame = CGRect(origin: position, size: size)
        }
        return (list[0] as? String, frame, list[3] as? [AXUIElement] ?? [])
    }

    private static func copyElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
