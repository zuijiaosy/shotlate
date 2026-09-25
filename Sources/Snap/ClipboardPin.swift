import AppKit
import UniformTypeIdentifiers

/// Turns the images on the pasteboard into pin images: image files copied in Finder, or else bitmap image data.
enum ClipboardPinSource {
    static func read(_ pasteboard: NSPasteboard) -> [NSBitmapImageRep] {
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let images = files.compactMap { url -> NSBitmapImageRep? in
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                  let image = NSImage(contentsOf: url) else { return nil }
            return bitmap(from: image)
        }
        if !images.isEmpty { return images }

        // Bitmap images only: apps like Pages also put a PDF rendering of copied text on the pasteboard.
        if pasteboard.canReadItem(withDataConformingToTypes: [UTType.image.identifier]),
           let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
           let rep = bitmap(from: image) {
            return [rep]
        }
        return []
    }

    static func bitmap(from image: NSImage) -> NSBitmapImageRep? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = image.size.width > 0 ? image.size : CGSize(width: cg.width, height: cg.height)
        return rep
    }
}
