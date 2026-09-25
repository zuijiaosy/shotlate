import AppKit
import SnapCore

/// Carries out `snap://` URLs and forwarded command-line requests inside the running app.
enum AutomationRunner {
    static func run(_ command: AutomationCommand) {
        switch command {
        case let .capture(request):
            let start = { capture(request) }
            if request.delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + request.delay, execute: start)
            } else {
                start()
            }
        case .pinClipboard: PinManager.shared.pinClipboard()
        case .togglePins: PinManager.shared.toggleHidden()
        case let .whiteboard(transparent): CaptureSession.beginBoard(transparent: transparent)
        case .scanCode: CodeScanner.scanScreens()
        case .replayHistory: CaptureSession.begin(replay: true)
        }
    }

    static func capture(_ request: CaptureRequest) {
        guard request.area != .interactive else {
            CaptureSession.begin(autoOutputs: request.outputs)
            return
        }
        guard CaptureEngine.hasPermission else { return CaptureSession.requestPermission() }
        guard let rect = resolve(request.area) else { return HUD.show(request.area == .last ? "还没有上一次的选区" : "找不到要截取的区域") }
        Task { @MainActor in
            do {
                let shots = try await CaptureEngine.captureScreens().map { ($0.screen.frame, $0.image) }
                guard let rep = crop(rect, screens: shots) else { return HUD.show("截取的区域不在任何屏幕上") }
                let results = deliver(rep, frame: rect, outputs: request.effectiveOutputs)
                Sound.playCapture()
                HUD.show(results.joined(separator: "，"))
            } catch {
                HUD.show("截图失败：\(error.localizedDescription)")
            }
        }
    }

    /// The area in Cocoa global coordinates.
    static func resolve(_ area: CaptureRequest.Area) -> CGRect? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        switch area {
        case .interactive:
            return nil
        case .fullScreen:
            return screen?.frame
        case .last:
            guard let screen, let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  let local = StyleMemory.lastSelection[id] else { return nil }
            return CGRect(x: screen.frame.minX + local.minX, y: screen.frame.maxY - local.maxY, width: local.width, height: local.height)
        case .activeWindow:
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
            return CaptureEngine.windowFrames(ownedBy: pid).first
        case let .rect(r):
            guard let primary = NSScreen.screens.first?.frame else { return nil }
            return CGRect(x: r.minX, y: primary.maxY - r.maxY, width: r.width, height: r.height)
        }
    }

    /// Cuts `rect` (Cocoa global) out of the screen whose frame holds its center; the image keeps its point size.
    static func crop(_ rect: CGRect, screens: [(frame: CGRect, image: CGImage)]) -> NSBitmapImageRep? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let (frame, image) = screens.first(where: { $0.frame.contains(center) }) ?? screens.first(where: { $0.frame.intersects(rect) }) else { return nil }
        let clipped = rect.intersection(frame)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        let scale = CGFloat(image.width) / frame.width
        let pixels = CGRect(x: (clipped.minX - frame.minX) * scale, y: (frame.maxY - clipped.maxY) * scale,
                            width: clipped.width * scale, height: clipped.height * scale).integral
        guard let cropped = image.cropping(to: pixels) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cropped)
        rep.size = clipped.size
        return rep
    }

    /// Sends the image everywhere it was asked to go and returns a short description of each.
    @discardableResult
    static func deliver(_ rep: NSBitmapImageRep, frame: CGRect, outputs: [CaptureRequest.Output]) -> [String] {
        var results: [String] = []
        let settings = Settings.shared
        for output in outputs {
            switch output {
            case .clipboard:
                Exporter.copy(rep)
                results.append("已复制")
            case .pin:
                PinManager.shared.pin(rep, frame: CGRect(origin: frame.origin, size: rep.size))
                results.append("已贴图")
            case .quickSave:
                if let url = try? Exporter.save(rep, format: settings.imageFormat, directory: settings.saveDirectory) {
                    results.append("已保存到 \(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                } else {
                    results.append("保存失败")
                }
            case let .file(path):
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                let format: ImageFormat = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Exporter.write(rep, format: format, to: url)
                    results.append("已保存到 \(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                } catch {
                    results.append("保存 \(url.lastPathComponent) 失败")
                }
            }
        }
        return results
    }
}
