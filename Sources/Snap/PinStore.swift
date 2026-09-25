import AppKit

/// Saves open pins when Snap quits (and shortly after pins change) and brings them back at the next launch.
final class PinStore {
    /// Replaced by the self-checks so they never touch the user's saved pins.
    static var shared = PinStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Snap/Pins", isDirectory: true))

    struct SavedPin: Codable {
        var id: UUID
        /// Window frame, or the full frame if the pin was collapsed to a thumbnail.
        var frame: CGRect
        var imageSize: CGSize
        var zoom: CGFloat
        var opacity: CGFloat
        var floating: Bool
        var group: String
        var text: String?
        var grayscale: Bool?
        var inverted: Bool?
        var background: PinBackground?
    }

    struct State: Codable {
        var pins: [SavedPin]
        var currentGroup: String
        var hidden: Bool
    }

    let directory: URL
    private var pendingSave: DispatchWorkItem?

    init(directory: URL) {
        self.directory = directory
    }

    private var stateURL: URL { directory.appendingPathComponent("pins.json") }
    private func imageURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).png") }

    /// Saves a second after the last change, so a burst of changes is written once.
    func scheduleSave(_ manager: PinManager = .shared) {
        guard Settings.shared.restorePins else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save(manager) }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func save(_ manager: PinManager = .shared) {
        pendingSave?.cancel()
        pendingSave = nil
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let saved = manager.pins.map { pin in
            SavedPin(id: pin.id, frame: pin.persistentFrame, imageSize: pin.rep.size, zoom: pin.zoom, opacity: pin.alphaValue,
                     floating: pin.level == .floating, group: pin.group, text: pin.sourceText,
                     grayscale: pin.grayscale, inverted: pin.inverted, background: pin.background)
        }
        // Images never change for a given id (rotating makes a new one), so only new ones are written.
        for pin in manager.pins where !fm.fileExists(atPath: imageURL(pin.id).path) {
            try? pin.rep.representation(using: .png, properties: [:])?.write(to: imageURL(pin.id))
        }
        let keep = Set(saved.map { "\($0.id.uuidString).png" })
        for file in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where file.hasSuffix(".png") && !keep.contains(file) {
            try? fm.removeItem(at: directory.appendingPathComponent(file))
        }
        let state = State(pins: saved, currentGroup: manager.currentGroup, hidden: manager.isHidingAll)
        try? JSONEncoder().encode(state).write(to: stateURL)
    }

    /// Recreates saved pins. Pins whose image is missing are skipped.
    func restore(into manager: PinManager = .shared) {
        guard let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode(State.self, from: data) else { return }
        for saved in state.pins {
            guard let data = try? Data(contentsOf: imageURL(saved.id)), let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = saved.imageSize
            let pin = manager.restorePin(rep, id: saved.id, frame: CGRect(origin: saved.frame.origin, size: saved.imageSize), group: saved.group)
            if abs(saved.zoom - 1) > 0.001 { pin.setZoom(saved.zoom, anchor: saved.frame.origin, flash: false) }
            pin.alphaValue = saved.opacity
            pin.level = saved.floating ? .floating : .normal
            pin.sourceText = saved.text
            pin.grayscale = saved.grayscale ?? false
            pin.inverted = saved.inverted ?? false
            pin.background = saved.background ?? .transparent
        }
        manager.restoreView(currentGroup: state.currentGroup, hidden: state.hidden)
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
