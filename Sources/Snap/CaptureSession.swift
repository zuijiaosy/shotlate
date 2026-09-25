import AppKit

/// Borderless full-screen window that can take keyboard focus.
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Window content: the frozen screenshot as a static layer, with the interactive overlay on top.
/// Keeping the screenshot in its own layer means mouse movement never redraws it.
final class CaptureRootView: NSView {
    let captureView: CaptureView

    init(frame: CGRect, snapshot: CGImage, captureView: CaptureView) {
        self.captureView = captureView
        super.init(frame: frame)
        wantsLayer = true
        let base = NSView(frame: bounds)
        base.wantsLayer = true
        base.layer?.contents = snapshot
        base.layer?.contentsGravity = .resize
        base.autoresizingMask = [.width, .height]
        addSubview(base)
        captureView.frame = bounds
        captureView.autoresizingMask = [.width, .height]
        addSubview(captureView)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// One screenshot: an overlay per screen, of which at most one owns the selection.
final class CaptureSession {
    private(set) static var current: CaptureSession?
    private static var isStarting = false

    private var windows: [OverlayWindow] = []
    private var views: [CaptureView] = []
    private weak var owner: CaptureView?
    private let previousApp: NSRunningApplication?

    static func begin() {
        guard current == nil, !isStarting else { return }
        guard CaptureEngine.hasPermission else {
            requestPermission()
            return
        }
        isStarting = true
        let previousApp = NSWorkspace.shared.frontmostApplication
        // Read window frames before anything of ours appears on screen.
        let windowFrames = CaptureEngine.windowFrames()
        Task { @MainActor in
            defer { isStarting = false }
            do {
                let snapshots = try await CaptureEngine.captureScreens()
                guard !snapshots.isEmpty else { return }
                let session = CaptureSession(snapshots: snapshots, windowFrames: windowFrames, previousApp: previousApp)
                current = session
                session.show()
            } catch {
                let alert = NSAlert()
                alert.messageText = "截图失败"
                alert.informativeText = error.localizedDescription
                NSApp.activate()
                alert.runModal()
            }
        }
    }

    static func requestPermission() {
        CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "请在「系统设置 → 隐私与安全性 → 屏幕与系统录音」中允许 Snap，然后重新打开 Snap。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private init(snapshots: [ScreenSnapshot], windowFrames: [CGRect], previousApp: NSRunningApplication?) {
        self.previousApp = previousApp
        for snapshot in snapshots {
            let frame = snapshot.screen.frame
            let local = CGRect(origin: .zero, size: frame.size)
            // Global Cocoa rects → this view's flipped coordinates.
            let rects = windowFrames.compactMap { r -> CGRect? in
                let v = CGRect(x: r.minX - frame.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height)
                let clipped = v.intersection(local)
                return clipped.isNull || clipped.width < 20 || clipped.height < 20 ? nil : clipped
            }
            let displayID = (snapshot.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let window = OverlayWindow(screen: snapshot.screen)
            let view = CaptureView(frame: local, snapshot: snapshot.image, windowRects: rects, displayID: displayID)
            view.session = self
            window.contentView = CaptureRootView(frame: local, snapshot: snapshot.image, captureView: view)
            windows.append(window)
            views.append(view)
        }
    }

    private func show() {
        NSApp.activate()
        for window in windows { window.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        let active = windows.first { $0.frame.contains(mouse) } ?? windows.first
        active?.makeKeyAndOrderFront(nil)
        if let index = active.flatMap({ windows.firstIndex(of: $0) }) {
            active?.makeFirstResponder(views[index])
            views[index].primeCursor()
        }
        NSCursor.crosshair.set()
    }

    func canInteract(_ view: CaptureView) -> Bool {
        owner == nil || owner === view
    }

    func didSelect(_ view: CaptureView) {
        owner = view
    }

    func didClearSelection(_ view: CaptureView) {
        if owner === view { owner = nil }
    }

    /// Hides the overlay while a standard save panel is up; brings it back if the user cancels.
    func presentSavePanel(rep: NSBitmapImageRep, format: ImageFormat) {
        let owner = self.owner
        for window in windows { window.orderOut(nil) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .png ? .png : .jpeg]
        panel.nameFieldStringValue = Exporter.defaultFileName(format: format)
        panel.canCreateDirectories = true
        let directory = Settings.shared.saveDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        panel.directoryURL = directory
        NSApp.activate()
        panel.begin { [weak self] response in
            guard let self else { return }
            if response == .OK, let url = panel.url {
                do {
                    try Exporter.write(rep, format: format, to: url)
                    self.finish()
                    HUD.show("已保存到 \(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                } catch {
                    self.finish()
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            } else {
                NSApp.activate()
                for window in self.windows { window.orderFrontRegardless() }
                if let owner, let window = owner.window {
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(owner)
                }
            }
        }
    }

    func cancel() {
        finish()
    }

    func finish() {
        for view in views { view.tearDown() }
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
        views.removeAll()
        CaptureSession.current = nil
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
        NSCursor.arrow.set()
        if let previousApp, previousApp != NSRunningApplication.current {
            previousApp.activate()
        }
    }
}
