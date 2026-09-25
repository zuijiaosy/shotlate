import AppKit

/// The system share menu (AirDrop, Mail, Messages, Notes…) for a finished image, shared as a PNG file
/// with the usual file name so the recipient gets a sensible name.
final class ShareController: NSObject, NSSharingServicePickerDelegate {
    private static var current: ShareController?
    private var anchorWindow: NSWindow?

    /// The file handed to the share services.
    static func file(for rep: NSBitmapImageRep) throws -> URL {
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        let folder = Exporter.clipboardDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Exporter.defaultFileName(format: .png))
        try png.write(to: url)
        return url
    }

    /// Shows the picker next to `view`.
    static func share(_ rep: NSBitmapImageRep, relativeTo view: NSView) {
        guard let url = try? file(for: rep) else { return HUD.show("无法准备分享的图片") }
        let controller = ShareController()
        current = controller
        let picker = NSSharingServicePicker(items: [url])
        picker.delegate = controller
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    /// Shows the picker at `rect` (global screen coordinates) after the capture overlay has closed.
    /// The overlay sits above menus, so a small invisible window stands in as the anchor.
    static func share(_ rep: NSBitmapImageRep, at rect: CGRect) {
        let anchor = NSWindow(contentRect: CGRect(x: rect.midX - 1, y: rect.minY, width: 2, height: 2),
                              styleMask: .borderless, backing: .buffered, defer: false)
        anchor.isOpaque = false
        anchor.backgroundColor = .clear
        anchor.level = .floating
        anchor.isReleasedWhenClosed = false
        anchor.orderFrontRegardless()
        NSApp.activate()
        guard let view = anchor.contentView else { return }
        share(rep, relativeTo: view)
        current?.anchorWindow = anchor
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        // Keep the anchor until the service has taken the file; close it when the picker is dismissed without a choice.
        if service == nil { finish() }
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, delegateFor service: NSSharingService) -> NSSharingServiceDelegate? {
        self
    }

    private func finish() {
        anchorWindow?.orderOut(nil)
        anchorWindow = nil
        ShareController.current = nil
    }
}

extension ShareController: NSSharingServiceDelegate {
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish() }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) { finish() }
}
