import AppKit
import UniformTypeIdentifiers

struct ExportOptions {
    var cornerRadius: CGFloat
    var shadow: Bool
    var format: ImageFormat
}

enum Exporter {
    static let shadowPadding: CGFloat = 24

    /// Renders the selection with annotations and visible translations at full pixel density.
    /// Rounded corners and the drop shadow are applied here, on transparent padding.
    static func render(renderer: ContentRenderer, selection: CGRect, scale: CGFloat,
                       items: [AnnotationItem], translation: [TranslatedBlock], options: ExportOptions) -> NSBitmapImageRep? {
        // JPEG has no alpha, so a shadow on transparent padding would turn black.
        let shadow = options.shadow && options.format == .png
        let padding = shadow ? shadowPadding : 0
        let sizePoints = CGSize(width: selection.width + padding * 2, height: selection.height + padding * 2)
        let width = Int((sizePoints.width * scale).rounded())
        let height = Int((sizePoints.height * scale).rounded())
        guard width > 0, height > 0,
              let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Work in flipped points so drawing code matches the on-screen view.
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: 0, y: sizePoints.height)
        cg.scaleBy(x: 1, y: -1)
        let context = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        let content = CGRect(x: padding, y: padding, width: selection.width, height: selection.height)
        let radius = min(options.cornerRadius, min(selection.width, selection.height) / 2)
        let shape = NSBezierPath(roundedRect: content, xRadius: radius, yRadius: radius)

        if options.format == .jpeg {
            NSColor.white.setFill()
            NSBezierPath(rect: CGRect(origin: .zero, size: sizePoints)).fill()
        }
        if shadow {
            // Shadow offsets are in device space and unaffected by the flip: negative height points down.
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 18 * scale,
                         color: NSColor.black.withAlphaComponent(0.45).cgColor)
            NSColor.white.setFill()
            shape.fill()
            cg.restoreGState()
        }

        shape.addClip()
        let transform = NSAffineTransform()
        transform.translateX(by: content.minX - selection.minX, yBy: content.minY - selection.minY)
        transform.concat()
        renderer.draw(items: items, translation: translation)

        guard let image = cg.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = sizePoints // keeps 2x images at their on-screen size when pasted
        return rep
    }

    static func data(_ rep: NSBitmapImageRep, format: ImageFormat) -> Data? {
        switch format {
        case .png: return rep.representation(using: .png, properties: [:])
        case .jpeg: return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
    }

    static func copy(_ rep: NSBitmapImageRep) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        pasteboard.writeObjects([image])
    }

    static func defaultFileName(format: ImageFormat) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Snap \(formatter.string(from: Date())).\(format.fileExtension)"
    }

    /// Saves into the configured folder with a timestamped name and returns the file URL.
    static func save(_ rep: NSBitmapImageRep, format: ImageFormat, directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = defaultFileName(format: format)
        var url = directory.appendingPathComponent(name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let base = (name as NSString).deletingPathExtension
            url = directory.appendingPathComponent("\(base) \(suffix).\(format.fileExtension)")
            suffix += 1
        }
        try write(rep, format: format, to: url)
        return url
    }

    static func write(_ rep: NSBitmapImageRep, format: ImageFormat, to url: URL) throws {
        guard let data = data(rep, format: format) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
}

/// Small floating message at the bottom of the screen, used after the overlay has closed.
enum HUD {
    private static var window: NSWindow?

    static func show(_ text: String, on screen: NSScreen? = NSScreen.main) {
        window?.orderOut(nil)
        guard let screen else { return }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        let size = label.fittingSize
        let width = min(size.width + 32, screen.frame.width - 40)
        let frame = CGRect(x: screen.frame.midX - width / 2, y: screen.frame.minY + 120, width: width, height: 36)

        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .transient]
        let background = NSView(frame: CGRect(origin: .zero, size: frame.size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        background.layer?.cornerRadius = 10
        label.frame = CGRect(x: 16, y: (36 - size.height) / 2, width: width - 32, height: size.height)
        background.addSubview(label)
        w.contentView = background
        w.orderFrontRegardless()
        window = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if window === w {
                w.orderOut(nil)
                window = nil
            }
        }
    }
}
