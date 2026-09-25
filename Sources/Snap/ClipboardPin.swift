import AppKit
import SnapCore
import UniformTypeIdentifiers

/// What a pin shows: the image, plus the text it was made from (for text, color and file pins) so it can be copied back.
struct PinContent {
    var rep: NSBitmapImageRep
    var text: String?
}

/// Turns whatever is on the pasteboard into pin images, in Snipaste's order:
/// image files, then a bitmap image, then a color value, then rich text, then plain text (including non-image file paths).
enum ClipboardPinSource {
    static let maxTextWidth: CGFloat = 560

    static func read(_ pasteboard: NSPasteboard, scale: CGFloat) -> [PinContent] {
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty {
            let images = files.compactMap { url -> PinContent? in
                guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                      let image = NSImage(contentsOf: url), let rep = bitmap(from: image) else { return nil }
                return PinContent(rep: rep, text: url.path)
            }
            if !images.isEmpty { return images }
            let paths = files.map(\.path).joined(separator: "\n")
            return textPin(paths, scale: scale).map { [$0] } ?? []
        }

        // Bitmap images only: apps like Pages also put a PDF rendering of copied text on the pasteboard.
        if pasteboard.canReadItem(withDataConformingToTypes: [UTType.image.identifier]),
           let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
           let rep = bitmap(from: image) {
            return [PinContent(rep: rep, text: nil)]
        }

        let plain = pasteboard.string(forType: .string)
        if let plain, let rgb = ColorText.parse(plain), let rep = colorCard(rgb, scale: scale) {
            return [PinContent(rep: rep, text: rgb.hex)]
        }
        if let rich = richText(pasteboard), rich.length > 0,
           let rep = renderText(rich, scale: scale) {
            return [PinContent(rep: rep, text: plain ?? rich.string)]
        }
        if let plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return textPin(plain, scale: scale).map { [$0] } ?? []
        }
        return []
    }

    private static func richText(_ pasteboard: NSPasteboard) -> NSAttributedString? {
        if let data = pasteboard.data(forType: .html),
           let html = NSAttributedString(html: data, options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) {
            return trimmed(withSystemDefaultFont(html))
        }
        if let data = pasteboard.data(forType: .rtf), let rtf = NSAttributedString(rtf: data, documentAttributes: nil) {
            return trimmed(rtf)
        }
        return nil
    }

    /// HTML without its own font falls back to Times 12; show that as the system font at 14, keeping bold and italic.
    private static func withSystemDefaultFont(_ s: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: s)
        m.enumerateAttribute(.font, in: NSRange(location: 0, length: m.length)) { value, range, _ in
            guard let font = value as? NSFont, font.familyName == "Times" else { return }
            let traits = font.fontDescriptor.symbolicTraits
            var descriptor = NSFont.systemFont(ofSize: font.pointSize * 14 / 12).fontDescriptor
            descriptor = descriptor.withSymbolicTraits(traits.intersection([.bold, .italic]))
            m.addAttribute(.font, value: NSFont(descriptor: descriptor, size: 0) ?? NSFont.systemFont(ofSize: 14), range: range)
        }
        return m
    }

    /// Browsers wrap copied HTML in trailing newlines; drop them so the pin has no empty band at the bottom.
    private static func trimmed(_ s: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: s)
        while let last = m.string.last, last.isNewline || last == " " {
            m.deleteCharacters(in: NSRange(location: m.length - 1, length: 1))
        }
        return m
    }

    static func textPin(_ text: String, scale: CGFloat) -> PinContent? {
        let code = CodeText.looksLikeCode(text)
        let font = code ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : NSFont.systemFont(ofSize: 14)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = code ? .byCharWrapping : .byWordWrapping
        paragraph.lineSpacing = 2
        // Tabs as four spaces, so indented code lines up regardless of tab stops.
        let body = text.replacingOccurrences(of: "\t", with: "    ").trimmingCharacters(in: .newlines)
        let attributed = NSAttributedString(string: body, attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph])
        return renderText(attributed, scale: scale).map { PinContent(rep: $0, text: text) }
    }

    /// Draws text on a white card, wrapping at `maxTextWidth`.
    static func renderText(_ text: NSAttributedString, scale: CGFloat, padding: CGFloat = 12) -> NSBitmapImageRep? {
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let measured = text.boundingRect(with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude), options: options)
        let textSize = CGSize(width: min(maxTextWidth, ceil(measured.width)), height: min(8000, ceil(measured.height)))
        let size = CGSize(width: max(textSize.width + padding * 2, 40), height: textSize.height + padding * 2)
        return draw(size: size, scale: scale) {
            NSColor.white.setFill()
            CGRect(origin: .zero, size: size).fill()
            text.draw(with: CGRect(x: padding, y: padding, width: textSize.width, height: textSize.height), options: options)
        }
    }

    /// A swatch with its hex and RGB values underneath, like Snipaste's color cards.
    static func colorCard(_ rgb: ColorText.RGB, scale: CGFloat) -> NSBitmapImageRep? {
        let size = CGSize(width: 180, height: 124)
        let (r, g, b) = rgb.bytes
        return draw(size: size, scale: scale) {
            NSColor.white.setFill()
            CGRect(origin: .zero, size: size).fill()
            NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: size.width, height: 84).fill()
            let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
            NSAttributedString(string: rgb.hex, attributes: [.font: mono, .foregroundColor: NSColor.black])
                .draw(at: CGPoint(x: 10, y: 88))
            NSAttributedString(string: "RGB \(r), \(g), \(b)", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.darkGray,
            ]).draw(at: CGPoint(x: 10, y: 105))
        }
    }

    /// Renders `body` in a flipped, top-left-origin context of `size` points at `scale`.
    static func draw(size: CGSize, scale: CGFloat, _ body: () -> Void) -> NSBitmapImageRep? {
        // Whole points, so the pin window's size is exact and survives saving and restoring.
        let size = CGSize(width: ceil(size.width), height: ceil(size.height))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()),
                                         pixelsHigh: Int((size.height * scale).rounded()), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let flipped = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        NSGraphicsContext.current = flipped
        let cg = context.cgContext
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        body()
        return rep
    }

    static func bitmap(from image: NSImage) -> NSBitmapImageRep? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = image.size.width > 0 ? image.size : CGSize(width: cg.width, height: cg.height)
        return rep
    }
}
