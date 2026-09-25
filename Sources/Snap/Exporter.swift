import AppKit
import SnapCore
import UniformTypeIdentifiers

struct ExportOptions {
    var cornerRadius: CGFloat
    var shadow: Bool
    var format: ImageFormat
    /// Puts the capture on a backdrop with margins, like the screenshots in blog posts and slides.
    var backdrop: Backdrop? = nil
}

/// A gradient (or flat) background for beautified exports.
struct Backdrop: Equatable {
    var title: String
    var colors: [NSColor]

    static let presets: [Backdrop] = [
        Backdrop(title: "紫蓝", colors: [NSColor(srgbRed: 0.56, green: 0.49, blue: 0.94, alpha: 1), NSColor(srgbRed: 0.35, green: 0.65, blue: 0.97, alpha: 1)]),
        Backdrop(title: "橙粉", colors: [NSColor(srgbRed: 1.0, green: 0.70, blue: 0.28, alpha: 1), NSColor(srgbRed: 1.0, green: 0.44, blue: 0.57, alpha: 1)]),
        Backdrop(title: "青绿", colors: [NSColor(srgbRed: 0.26, green: 0.88, blue: 0.69, alpha: 1), NSColor(srgbRed: 0.23, green: 0.55, blue: 1.0, alpha: 1)]),
        Backdrop(title: "石墨", colors: [NSColor(srgbRed: 0.23, green: 0.25, blue: 0.29, alpha: 1), NSColor(srgbRed: 0.12, green: 0.13, blue: 0.16, alpha: 1)]),
        Backdrop(title: "浅灰", colors: [NSColor(srgbRed: 0.95, green: 0.96, blue: 0.97, alpha: 1), NSColor(srgbRed: 0.87, green: 0.89, blue: 0.91, alpha: 1)]),
    ]

    /// Margin around the capture: grows with its size, within sensible limits.
    static func margin(for size: CGSize) -> CGFloat {
        min(96, max(32, min(size.width, size.height) * 0.1)).rounded()
    }
}

enum Exporter {
    static let shadowPadding: CGFloat = 24

    /// Renders the selection with annotations and visible translations at full pixel density.
    /// Rounded corners and the drop shadow are applied here, on transparent padding.
    static func render(renderer: ContentRenderer, selection: CGRect, scale: CGFloat,
                       items: [AnnotationItem], translation: [TranslatedBlock], options: ExportOptions) -> NSBitmapImageRep? {
        // JPEG has no alpha, so a shadow on transparent padding would turn black; a backdrop is opaque, so it can.
        let shadow = options.backdrop != nil || (options.shadow && options.format == .png)
        let padding = options.backdrop.map { _ in Backdrop.margin(for: selection.size) } ?? (shadow ? shadowPadding : 0)
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
        // On a backdrop square corners look unfinished; give them a small radius at least.
        let wantedRadius = options.backdrop == nil ? options.cornerRadius : max(options.cornerRadius, 10)
        let radius = min(wantedRadius, min(selection.width, selection.height) / 2)
        let shape = NSBezierPath(roundedRect: content, xRadius: radius, yRadius: radius)

        if let backdrop = options.backdrop {
            let canvas = CGRect(origin: .zero, size: sizePoints)
            if backdrop.colors.count > 1, let gradient = NSGradient(colors: backdrop.colors) {
                gradient.draw(in: canvas, angle: -45)
            } else {
                (backdrop.colors.first ?? .white).setFill()
                canvas.fill()
            }
        } else if options.format == .jpeg {
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

    /// Puts the image on the pasteboard. With "copy as file" on, the same item also carries a PNG file,
    /// so pasting into Finder creates a file while chat apps still paste the image.
    static func copy(_ rep: NSBitmapImageRep, to pasteboard: NSPasteboard = .general, asFile: Bool = Settings.shared.copyAsFile) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        let png = rep.representation(using: .png, properties: [:])
        if let png { item.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        if asFile, let png, let url = try? clipboardFile(png) {
            item.setString(url.absoluteString, forType: .fileURL)
        }
        pasteboard.writeObjects([item])
    }

    /// Files handed out through the clipboard live in Caches and are cleaned up after a day.
    static var clipboardDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("app.snap.Snap/Clipboard", isDirectory: true)
    }

    private static func clipboardFile(_ png: Data) throws -> URL {
        let fm = FileManager.default
        let directory = clipboardDirectory
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for old in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let date = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < cutoff {
                try? fm.removeItem(at: old)
            }
        }
        // A folder per copy keeps the friendly file name unique.
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(defaultFileName(format: .png))
        try png.write(to: url)
        return url
    }

    /// Name of the app that was in front when the current capture started, for `{app}` in file names.
    static var sourceAppName: String?

    static func defaultFileName(format: ImageFormat) -> String {
        let base = FileNameTemplate.expand(Settings.shared.fileNameTemplate, date: Date(), appName: sourceAppName)
        return "\(base).\(format.fileExtension)"
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
