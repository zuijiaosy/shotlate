import AppKit

/// Scripted behaviour checks that need AppKit (windows, pasteboard, rendering) and so can't live in SnapCore's tests.
/// Each check prints PASS/FAIL lines and the process exits non-zero if any expectation failed.
///
///   Snap --check <name|all> [output-directory]
enum FeatureChecks {
    @MainActor private static var failures = 0
    @MainActor static var outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snap-checks")

    @MainActor static func expect(_ condition: Bool, _ message: String) {
        print(condition ? "PASS  \(message)" : "FAIL  \(message)")
        if !condition { failures += 1 }
    }

    @MainActor static let checks: [(String, @MainActor () async -> Void)] = [
        ("pins-hide", pinsHide),
    ]

    @MainActor
    static func run(_ name: String, output: URL?) async -> Int32 {
        if let output { outputDirectory = output }
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let selected = name == "all" ? checks : checks.filter { $0.0 == name }
        guard !selected.isEmpty else {
            print("unknown check \(name); available: \(checks.map(\.0).joined(separator: ", "))")
            return 2
        }
        for (checkName, body) in selected {
            print("== \(checkName)")
            await body()
        }
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }

    /// A small solid-color image, `size` in points at 2x.
    static func sampleRep(_ size: CGSize = CGSize(width: 120, height: 80), color: NSColor = .systemTeal) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        CGRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    @MainActor static func write(_ rep: NSBitmapImageRep, _ name: String) {
        try? rep.representation(using: .png, properties: [:])?.write(to: outputDirectory.appendingPathComponent(name))
    }

    // MARK: - Checks

    @MainActor static func pinsHide() async {
        let manager = PinManager.shared
        let a = manager.pin(sampleRep(), frame: CGRect(x: -4000, y: -4000, width: 120, height: 80))
        let b = manager.pin(sampleRep(), frame: CGRect(x: -3800, y: -4000, width: 120, height: 80))
        expect(a.isVisible && b.isVisible, "new pins are visible")
        manager.toggleHidden()
        expect(manager.isHidingAll && !a.isVisible && !b.isVisible, "toggle hides every pin")
        expect(!manager.hasHistory, "hidden pins are not moved to the restore history")
        manager.toggleHidden()
        expect(!manager.isHidingAll && a.isVisible && b.isVisible, "toggle again shows them")
        manager.toggleHidden()
        let c = manager.pin(sampleRep(), frame: CGRect(x: -3600, y: -4000, width: 120, height: 80))
        expect(!manager.isHidingAll && a.isVisible && c.isVisible, "a new pin while hidden brings the others back")
        manager.closeAll()
        expect(!manager.hasPins, "close all empties the list")
    }
}
