import AppKit
import ApplicationServices
import ScreenCaptureKit
import SnapCore

/// Long screenshot: captures a screen region repeatedly while the user (or auto-scroll) scrolls it,
/// and stitches the frames with `ScrollStitcher`.
final class ScrollCaptureController {
    private(set) static var current: ScrollCaptureController?

    private let rect: CGRect
    private let screen: NSScreen
    private let scale: CGFloat
    private let frameWindow: NSWindow
    private let panel: ScrollCapturePanel
    private let stitcher: ScrollStitcher
    private let stitchQueue = DispatchQueue(label: "app.snap.stitch", qos: .userInitiated)
    private var filter: SCContentFilter?
    private var captureTimer: Timer?
    private var autoScrollTimer: Timer?
    private var inFlight = false
    private var unchangedCount = 0
    private var lastPreview = Date.distantPast
    private var finished = false
    private var dumped = 0

    private let excludeOwnWindows: Bool
    /// Called with the stitched image instead of opening the result window (used by the dev demo).
    var onFinished: ((CGImage) -> Void)?

    /// `rect` is in global Cocoa coordinates.
    @discardableResult
    static func start(rect: CGRect, screen: NSScreen, excludeOwnWindows: Bool = true) -> ScrollCaptureController {
        current?.cancel()
        let controller = ScrollCaptureController(rect: rect, screen: screen, excludeOwnWindows: excludeOwnWindows)
        current = controller
        controller.begin()
        return controller
    }

    private init(rect: CGRect, screen: NSScreen, excludeOwnWindows: Bool) {
        self.excludeOwnWindows = excludeOwnWindows
        scale = screen.backingScaleFactor
        // Snap to whole pixels so every frame has exactly the same size.
        let r = CGRect(x: (rect.minX * scale).rounded() / scale, y: (rect.minY * scale).rounded() / scale,
                       width: (rect.width * scale).rounded() / scale, height: (rect.height * scale).rounded() / scale)
        self.rect = r
        self.screen = screen
        stitcher = ScrollStitcher(maxHeight: 60_000, ignoredRightColumns: Int(18 * screen.backingScaleFactor))

        frameWindow = NSWindow(contentRect: r.insetBy(dx: -4, dy: -4), styleMask: .borderless, backing: .buffered, defer: false)
        frameWindow.isOpaque = false
        frameWindow.backgroundColor = .clear
        frameWindow.ignoresMouseEvents = true
        frameWindow.level = .statusBar
        frameWindow.hasShadow = false
        frameWindow.isReleasedWhenClosed = false
        frameWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        frameWindow.contentView = DashedFrameView()

        panel = ScrollCapturePanel()
        panel.onFinish = { [weak self] in self?.finish() }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onAutoScroll = { [weak self] in self?.toggleAutoScroll() }
    }

    private func begin() {
        frameWindow.orderFrontRegardless()
        panel.place(next: rect, on: screen)
        panel.orderFrontRegardless()
        panel.setStatus("在框内滚动鼠标或触控板，Snap 会自动拼接。框选时避开滚动条，效果更好。")

        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let own = excludeOwnWindows ? content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier } : []
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      let display = content.displays.first(where: { $0.displayID == number.uint32Value })
                else { throw CocoaError(.featureUnsupported) }
                filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in self?.tick() }
                RunLoop.main.add(timer, forMode: .common)
                captureTimer = timer
                tick()
            } catch {
                panel.setStatus("无法开始长截图：\(error.localizedDescription)")
            }
        }
    }

    private var configuration: SCStreamConfiguration {
        let config = SCStreamConfiguration()
        // sourceRect is in the display's points with a top-left origin.
        config.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
                                   width: rect.width, height: rect.height)
        config.width = Int((rect.width * scale).rounded())
        config.height = Int((rect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        return config
    }

    private func tick() {
        guard !inFlight, !finished, let filter else { return }
        inFlight = true
        let config = configuration
        Task { @MainActor in
            defer { inFlight = false }
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
                  !finished else { return }
            if let dir = ProcessInfo.processInfo.environment["SNAP_DUMP_FRAMES"], dumped < 4 {
                dumped += 1
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("frame\(dumped).png"))
            }
            let result: ScrollStitcher.Result = await withCheckedContinuation { continuation in
                stitchQueue.async {
                    guard let buffer = PixelBuffer(image: image) else { return continuation.resume(returning: .unchanged) }
                    continuation.resume(returning: self.stitcher.add(buffer))
                }
            }
            handle(result)
        }
    }

    private func handle(_ result: ScrollStitcher.Result) {
        if ProcessInfo.processInfo.environment["SNAP_DEBUG_STITCH"] != nil { print("stitch:", result, stitcher.height) }
        switch result {
        case .started, .appended:
            unchangedCount = 0
            panel.setStatus("\(stitcher.height.formatted()) px · 继续滚动，或点完成")
            refreshPreview(force: result == .started)
        case .unchanged:
            unchangedCount += 1
            // Auto-scroll that stops producing new rows has reached the end.
            if autoScrollTimer != nil, unchangedCount >= 12 {
                stopAutoScroll()
                panel.setStatus("\(stitcher.height.formatted()) px · 已经到底了")
            }
        case .scrolledBack:
            panel.setStatus("往回滚动的部分不会拼接，继续往下滚即可")
        case .noOverlap:
            panel.setStatus("滚得太快了，请慢一点，或往回滚一点再继续")
        case .limitReached:
            panel.setStatus("已达到长度上限")
            finish()
        }
    }

    private func refreshPreview(force: Bool) {
        guard force || Date().timeIntervalSince(lastPreview) > 0.3 else { return }
        lastPreview = Date()
        let width = Int(panel.previewWidth * scale)
        stitchQueue.async { [weak self] in
            guard let self, let preview = self.stitcher.makePreview(targetWidth: width) else { return }
            DispatchQueue.main.async { self.panel.setPreview(preview, pointWidth: CGFloat(width) / self.scale) }
        }
    }

    // MARK: Auto scroll

    private func toggleAutoScroll() {
        if autoScrollTimer != nil {
            stopAutoScroll()
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            panel.setStatus("自动滚动需要辅助功能权限：请在「系统设置 → 隐私与安全性 → 辅助功能」中允许 Snap")
            return
        }
        // Scroll events go to the window under the pointer, so park it in the region.
        guard let primary = NSScreen.screens.first else { return }
        CGWarpMouseCursorPosition(CGPoint(x: rect.midX, y: primary.frame.maxY - rect.midY))
        unchangedCount = 0
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -6, wheel2: 0, wheel3: 0)?
                .post(tap: .cghidEventTap)
        }
        RunLoop.main.add(timer, forMode: .common)
        autoScrollTimer = timer
        panel.setAutoScrolling(true)
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        panel.setAutoScrolling(false)
    }

    // MARK: Finish

    private func tearDown() {
        finished = true
        captureTimer?.invalidate()
        stopAutoScroll()
        frameWindow.orderOut(nil)
        panel.orderOut(nil)
        if ScrollCaptureController.current === self { ScrollCaptureController.current = nil }
    }

    func cancel() {
        tearDown()
    }

    func finish() {
        guard !finished else { return }
        tearDown()
        let scale = self.scale
        let screen = self.screen
        stitchQueue.async { [stitcher, self] in
            let image = stitcher.makeImage()
            DispatchQueue.main.async {
                guard let image else { return }
                if let onFinished = self.onFinished {
                    onFinished(image)
                    return
                }
                Sound.playCapture()
                ScrollResultWindow.show(image: image, scale: scale, on: screen)
            }
        }
    }
}

// The stitcher is only touched on `stitchQueue`; everything else runs on the main thread.
extension ScrollCaptureController: @unchecked Sendable {}

/// Dashed blue outline drawn just outside the captured region.
private final class DashedFrameView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        selectionBlue.setStroke()
        path.stroke()
    }
}

/// Control panel beside the region: live preview, status, auto-scroll, cancel and done.
final class ScrollCapturePanel: NSPanel {
    var onFinish: () -> Void = {}
    var onCancel: () -> Void = {}
    var onAutoScroll: () -> Void = {}
    let previewWidth: CGFloat = 150

    private let root = PanelView()
    private let titleLabel = NSTextField(labelWithString: "长截图")
    private let preview = NSImageView()
    private let previewBox = NSView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let autoButton = NSButton(title: "自动滚动", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let doneButton = NSButton(title: "完成", target: nil, action: nil)

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 190, height: 400), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = root
        root.radius = 12

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        previewBox.wantsLayer = true
        previewBox.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        previewBox.layer?.cornerRadius = 6
        previewBox.layer?.masksToBounds = true
        preview.imageScaling = .scaleProportionallyDown
        preview.imageAlignment = .alignBottom
        previewBox.addSubview(preview)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 4

        autoButton.bezelStyle = .push
        autoButton.controlSize = .small
        autoButton.target = self
        autoButton.action = #selector(autoTapped)
        cancelButton.bezelStyle = .push
        cancelButton.controlSize = .small
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        doneButton.bezelStyle = .push
        doneButton.controlSize = .small
        doneButton.keyEquivalent = "\r"
        doneButton.target = self
        doneButton.action = #selector(doneTapped)
        for view in [titleLabel, previewBox, status, autoButton, cancelButton, doneButton] as [NSView] { root.addSubview(view) }
    }

    override var canBecomeKey: Bool { true }

    func place(next rect: CGRect, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let height = min(max(rect.height, 300), min(520, visible.height - 20))
        var origin = CGPoint(x: rect.maxX + 14, y: rect.maxY - height)
        if origin.x + frame.width > visible.maxX { origin.x = rect.minX - frame.width - 14 }
        if origin.x < visible.minX { origin.x = rect.maxX - frame.width - 10 }
        origin.y = min(max(origin.y, visible.minY + 10), visible.maxY - height - 10)
        setFrame(CGRect(origin: origin, size: CGSize(width: 190, height: height)), display: false)
        layoutContent()
    }

    private func layoutContent() {
        let w = frame.width, h = frame.height
        titleLabel.frame = CGRect(x: 14, y: 12, width: w - 28, height: 18)
        let buttonsY = h - 36
        cancelButton.frame = CGRect(x: 12, y: buttonsY, width: 80, height: 24)
        doneButton.frame = CGRect(x: w - 92, y: buttonsY, width: 80, height: 24)
        autoButton.frame = CGRect(x: 12, y: buttonsY - 30, width: w - 24, height: 24)
        status.frame = CGRect(x: 14, y: buttonsY - 30 - 50, width: w - 28, height: 46)
        previewBox.frame = CGRect(x: (w - previewWidth) / 2, y: 38, width: previewWidth, height: max(40, status.frame.minY - 44))
        preview.frame = previewBox.bounds
    }

    func setStatus(_ text: String) {
        status.stringValue = text
    }

    func setPreview(_ image: CGImage, pointWidth: CGFloat) {
        let size = CGSize(width: pointWidth, height: pointWidth * CGFloat(image.height) / CGFloat(image.width))
        preview.image = NSImage(cgImage: image, size: size)
    }

    func setAutoScrolling(_ on: Bool) {
        autoButton.title = on ? "停止自动滚动" : "自动滚动"
    }

    @objc private func autoTapped() { onAutoScroll() }
    @objc private func cancelTapped() { onCancel() }
    @objc private func doneTapped() { onFinish() }

    override func cancelOperation(_ sender: Any?) { onCancel() }
}

/// Shows a finished long screenshot with copy, save and pin actions.
final class ScrollResultWindow: NSWindow, NSWindowDelegate {
    private static var open: [ScrollResultWindow] = []
    private let rep: NSBitmapImageRep

    static func show(image: CGImage, scale: CGFloat, on screen: NSScreen) {
        let window = ScrollResultWindow(image: image, scale: scale, screen: screen)
        open.append(window)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private init(image: CGImage, scale: CGFloat, screen: NSScreen) {
        rep = NSBitmapImageRep(cgImage: image)
        let pointSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        rep.size = pointSize
        let visible = screen.visibleFrame
        let contentWidth = min(max(pointSize.width + 2, 360), visible.width * 0.8)
        let contentHeight = min(pointSize.height, visible.height * 0.8) + 52
        let frame = CGRect(x: visible.midX - contentWidth / 2, y: visible.midY - contentHeight / 2, width: contentWidth, height: contentHeight)
        super.init(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        title = "长截图 · \(image.width) × \(image.height) px"
        isReleasedWhenClosed = false
        delegate = self

        let root = NSView(frame: CGRect(origin: .zero, size: frame.size))
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 52, width: frame.width, height: frame.height - 52))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 4
        let imageView = FlippedImageView(frame: CGRect(origin: .zero, size: pointSize))
        let nsImage = NSImage(size: pointSize)
        nsImage.addRepresentation(rep)
        imageView.image = nsImage
        imageView.imageScaling = .scaleAxesIndependently
        scroll.documentView = imageView
        root.addSubview(scroll)

        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.frame = CGRect(x: 12, y: 12, width: frame.width - 24, height: 28)
        bar.autoresizingMask = [.width]
        let hint = NSTextField(labelWithString: "⌘ + 滚轮或双指捏合缩放")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        bar.addArrangedSubview(hint)
        bar.addArrangedSubview(NSView())
        for (title, action) in [("贴图", #selector(pinImage)), ("保存", #selector(saveImage)), ("复制", #selector(copyImage))] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .push
            if title == "复制" { button.keyEquivalent = "\r" }
            bar.addArrangedSubview(button)
        }
        root.addSubview(bar)
        contentView = root
    }

    @objc private func copyImage() {
        Exporter.copy(rep)
        close()
        HUD.show("已复制到剪贴板")
    }

    @objc private func saveImage() {
        do {
            let url = try Exporter.save(rep, format: Settings.shared.imageFormat, directory: Settings.shared.saveDirectory)
            close()
            HUD.show("已保存到 \(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func pinImage() {
        guard let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        // Long images are pinned at a height that fits the screen; scroll the pin to zoom.
        let fit = min(1, (visible.height * 0.9) / rep.size.height)
        let size = CGSize(width: rep.size.width, height: rep.size.height)
        let pin = PinManager.shared.pin(rep, frame: CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                                           width: size.width, height: size.height))
        if fit < 1 { pin.setZoom(fit) }
        close()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }

    func windowWillClose(_ notification: Notification) {
        ScrollResultWindow.open.removeAll { $0 === self }
    }
}

private final class FlippedImageView: NSImageView {
    override var isFlipped: Bool { true }
}

enum Sound {
    private static let capture = NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif", byReference: true)

    static func playCapture() {
        guard Settings.shared.playSound else { return }
        capture?.stop()
        capture?.play()
    }
}
