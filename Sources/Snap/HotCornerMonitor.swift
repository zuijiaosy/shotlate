import AppKit
import SnapCore

/// Watches the pointer and runs the command set for a screen corner when the pointer rests there.
/// Polls ten times a second while any corner has a command; nothing runs otherwise.
final class HotCornerMonitor {
    static let shared = HotCornerMonitor()

    static let choices: [(title: String, command: String)] = [
        ("无", ""),
        ("显示 / 隐藏贴图", "toggle-images"),
        ("截图", "snip"),
        ("从剪贴板贴图", "paste"),
        ("下一个贴图分组", "switch-group"),
        ("白板", "whiteboard"),
        ("透明白板", "transparent-whiteboard"),
        ("回放上一次截图", "snap://history"),
    ]

    private var timer: Timer?
    private var detector = HotCornerDetector()

    func reload() {
        let active = Settings.shared.hotCorners.values.contains { !$0.isEmpty }
        if active, timer == nil {
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !active {
            timer?.invalidate()
            timer = nil
        }
    }

    var isRunning: Bool { timer != nil }

    private func tick() {
        // Not while capturing: the corners are then part of the picture.
        guard CaptureSession.current == nil else { return }
        let screens = NSScreen.screens.map(\.frame)
        guard let corner = detector.update(NSEvent.mouseLocation, screens: screens, now: Date()) else { return }
        run(corner)
    }

    func run(_ corner: ScreenCorner) {
        guard let text = Settings.shared.hotCorners[corner], !text.isEmpty, let command = Automation.parse(command: text) else { return }
        AutomationRunner.run(command)
    }
}
