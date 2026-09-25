import AppKit
import ScreenCaptureKit

/// A frozen image of one screen, taken before the overlay appears.
struct ScreenSnapshot {
    let screen: NSScreen
    let image: CGImage
}

enum CaptureEngine {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Captures every screen at full pixel resolution, leaving out Snap's own windows.
    static func captureScreens() async throws -> [ScreenSnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var snapshots: [ScreenSnapshot] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value })
            else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            snapshots.append(ScreenSnapshot(screen: screen, image: image))
        }
        return snapshots
    }

    struct Pointer {
        var image: NSImage
        /// Hot spot in the image's top-left-origin points.
        var hotSpot: CGPoint
        /// Global Cocoa coordinates.
        var location: CGPoint
    }

    /// The pointer as it looks right now, so it can be added to the frozen screenshot on request.
    static func pointer() -> Pointer? {
        guard let cursor = NSCursor.currentSystem else { return nil }
        return Pointer(image: cursor.image, hotSpot: cursor.hotSpot, location: NSEvent.mouseLocation)
    }

    /// Frames of normal app windows, front to back, in Cocoa global coordinates (origin bottom-left of the main screen).
    static func windowFrames(ownedBy owner: pid_t? = nil) -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height
        else { return [] }
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int) != ownPID,
                  owner == nil || (info[kCGWindowOwnerPID as String] as? Int) == Int(owner!),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 40, bounds.height > 40
            else { return nil }
            // CG window bounds use a top-left origin on the primary display.
            return CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
        }
    }
}
