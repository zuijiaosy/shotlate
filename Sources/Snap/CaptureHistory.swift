import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One past capture: the frozen screen it was taken from, where the selection was, and its annotations.
struct HistoryEntry: Codable, Equatable {
    var id = UUID()
    var date = Date()
    var displayID: UInt32
    /// Screen size in points when captured; replay needs a screen of the same size.
    var screenSize: CGSize
    var selection: CGRect
    var items: [AnnotationItem]
}

/// Past captures on disk, newest first. Each entry is a folder with the screen image and a JSON description.
/// Files are written on a background queue; the in-memory list is updated right away.
final class CaptureHistory {
    static let shared = CaptureHistory(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Snap/History", isDirectory: true))

    let directory: URL
    private let queue = DispatchQueue(label: "app.snap.history", qos: .utility)
    private var cache: [HistoryEntry]?

    init(directory: URL) {
        self.directory = directory
    }

    var limit: Int { Settings.shared.historyLimit }

    /// Newest first.
    var entries: [HistoryEntry] {
        if let cache { return cache }
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let loaded = folders.compactMap { folder -> HistoryEntry? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("entry.json")) else { return nil }
            return try? JSONDecoder().decode(HistoryEntry.self, from: data)
        }.sorted { $0.date > $1.date }
        cache = loaded
        return loaded
    }

    func record(_ entry: HistoryEntry, snapshot: CGImage) {
        guard limit > 0 else { return }
        var list = entries
        list.insert(entry, at: 0)
        let dropped = list.count > limit ? Array(list[limit...]) : []
        list = Array(list.prefix(limit))
        cache = list
        let folder = directory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        let base = directory
        queue.async {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                guard let dest = CGImageDestinationCreateWithURL(folder.appendingPathComponent("screen.png") as CFURL,
                                                                 UTType.png.identifier as CFString, 1, nil) else { return }
                CGImageDestinationAddImage(dest, snapshot, nil)
                guard CGImageDestinationFinalize(dest) else { return }
                // The JSON goes last, so a half-written entry is never listed.
                try JSONEncoder().encode(entry).write(to: folder.appendingPathComponent("entry.json"))
            } catch {
                try? fm.removeItem(at: folder)
            }
            for old in dropped { try? fm.removeItem(at: base.appendingPathComponent(old.id.uuidString)) }
        }
    }

    func image(for entry: HistoryEntry) -> CGImage? {
        waitForWrites()
        let url = directory.appendingPathComponent(entry.id.uuidString).appendingPathComponent("screen.png")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func clear() {
        cache = []
        let directory = self.directory
        queue.async { try? FileManager.default.removeItem(at: directory) }
    }

    /// Applies a lower limit right away.
    func prune() {
        let list = entries
        guard list.count > limit else { return }
        cache = Array(list.prefix(limit))
        let dropped = list[max(0, limit)...].map(\.id)
        let directory = self.directory
        queue.async { for id in dropped { try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString)) } }
    }

    func waitForWrites() {
        queue.sync {}
    }
}

// MARK: - Codable annotations

extension AnnotationItem: Codable {
    private enum CodingKeys: String, CodingKey { case id, shape, color, size, effect }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rgba = try c.decode([CGFloat].self, forKey: .color)
        self.init(id: try c.decode(UUID.self, forKey: .id), shape: try c.decode(Shape.self, forKey: .shape),
                  color: NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba.count > 3 ? rgba[3] : 1),
                  size: try c.decode(CGFloat.self, forKey: .size), effect: try c.decode(MosaicEffect.self, forKey: .effect))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let s = color.usingColorSpace(.sRGB) ?? .black
        try c.encode(id, forKey: .id)
        try c.encode(shape, forKey: .shape)
        try c.encode([s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent], forKey: .color)
        try c.encode(size, forKey: .size)
        try c.encode(effect, forKey: .effect)
    }
}
