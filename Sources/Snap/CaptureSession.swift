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
    /// What each screen showed when the session started, to come back to after replaying history.
    private var liveSnapshots: [CGImage] = []
    private var liveWindowRects: [[CGRect]] = []
    /// -1 is the live screen; 0 is the newest history entry.
    private var historyIndex = -1
    private var historyScreen: Int?
    var history = CaptureHistory.shared

    /// `replay` opens straight into the most recent capture from history.
    static func begin(replay: Bool = false) {
        guard current == nil, !isStarting else { return }
        guard CaptureEngine.hasPermission else {
            requestPermission()
            return
        }
        isStarting = true
        let previousApp = NSWorkspace.shared.frontmostApplication
        Exporter.sourceAppName = previousApp.flatMap { $0 == NSRunningApplication.current ? nil : $0.localizedName }
        // Read window frames and the pointer before anything of ours appears on screen.
        let windowFrames = CaptureEngine.windowFrames()
        let pointer = CaptureEngine.pointer()
        Task { @MainActor in
            defer { isStarting = false }
            do {
                let snapshots = try await CaptureEngine.captureScreens()
                guard !snapshots.isEmpty else { return }
                let session = CaptureSession(snapshots: snapshots, windowFrames: windowFrames, pointer: pointer, previousApp: previousApp)
                current = session
                session.show()
                if replay, let view = session.activeView { session.stepHistory(1, from: view) }
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

    /// An offscreen session over `image`, for scripted checks; nothing is shown on the real screens.
    static func makeForTesting(image: CGImage, size: CGSize, history: CaptureHistory) -> CaptureSession {
        let session = CaptureSession(previousApp: nil)
        session.history = history
        let window = OverlayWindow(screen: NSScreen.screens[0])
        window.setFrame(CGRect(x: -9000, y: -9000, width: size.width, height: size.height), display: false)
        let local = CGRect(origin: .zero, size: size)
        let view = CaptureView(frame: local, snapshot: image, windowRects: [], displayID: 0)
        view.session = session
        window.contentView = CaptureRootView(frame: local, snapshot: image, captureView: view)
        session.windows = [window]
        session.views = [view]
        session.liveSnapshots = [image]
        session.liveWindowRects = [[]]
        return session
    }

    var testing_views: [CaptureView] { views }

    private init(previousApp: NSRunningApplication?) {
        self.previousApp = previousApp
    }

    private init(snapshots: [ScreenSnapshot], windowFrames: [CGRect], pointer: CaptureEngine.Pointer?, previousApp: NSRunningApplication?) {
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
            liveSnapshots.append(snapshot.image)
            liveWindowRects.append(rects)
            var cursor: CapturedCursor?
            if let pointer, frame.contains(pointer.location) {
                let p = CGPoint(x: pointer.location.x - frame.minX, y: frame.maxY - pointer.location.y)
                cursor = CapturedCursor(image: pointer.image, rect: CGRect(x: p.x - pointer.hotSpot.x, y: p.y - pointer.hotSpot.y,
                                                                          width: pointer.image.size.width, height: pointer.image.size.height))
            }
            let view = CaptureView(frame: local, snapshot: snapshot.image, windowRects: rects, displayID: displayID, cursor: cursor)
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

    private var activeView: CaptureView? {
        views.first { $0.window?.isKeyWindow == true } ?? views.first
    }

    // MARK: History

    /// Keeps `view`'s capture for replay. A replayed capture output again without changes is not stored twice.
    func record(_ view: CaptureView) {
        guard let entry = view.historyEntry() else { return }
        history.record(entry, snapshot: view.snapshotImage)
    }

    /// `,` (delta 1) steps to an older capture, `.` (delta -1) back towards the live screen.
    func stepHistory(_ delta: Int, from view: CaptureView) {
        let entries = history.entries
        let target = historyIndex + delta
        guard target >= -1 else {
            view.showMessage("已经是当前屏幕")
            return
        }
        guard target < entries.count else {
            view.showMessage(entries.isEmpty ? "还没有截图历史" : "没有更早的截图了")
            return
        }
        if let other = owner, other !== view, !(historyScreen.map { views[$0] === other } ?? false) {
            view.showMessage("请先取消另一块屏幕上的选区")
            return
        }
        historyIndex = target
        if target == -1 {
            if let screen = historyScreen {
                replaceView(at: screen, snapshot: liveSnapshots[screen], rects: liveWindowRects[screen], entry: nil)
                views[screen].showMessage("回到当前屏幕")
            }
            historyScreen = nil
            return
        }
        let entry = entries[target]
        let index = views.firstIndex { $0.displayID == entry.displayID } ?? views.firstIndex { $0 === view } ?? 0
        guard abs(windows[index].frame.width - entry.screenSize.width) < 1, abs(windows[index].frame.height - entry.screenSize.height) < 1 else {
            view.showMessage("第 \(target + 1) 张来自尺寸不同的屏幕，无法回放，按 , 继续往前")
            return
        }
        guard let image = history.image(for: entry) else {
            view.showMessage("第 \(target + 1) 张截图的文件已丢失")
            return
        }
        if let previous = historyScreen, previous != index {
            replaceView(at: previous, snapshot: liveSnapshots[previous], rects: liveWindowRects[previous], entry: nil)
        }
        historyScreen = index
        replaceView(at: index, snapshot: image, rects: [], entry: entry)
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(entry.date) ? "HH:mm:ss" : "M月d日 HH:mm"
        views[index].showMessage("截图历史 \(target + 1)/\(entries.count) · \(formatter.string(from: entry.date))\n, 更早 · . 更新", duration: 3)
    }

    // MARK: Refresh

    /// Grabs `view`'s screen again (Snap's own windows are left out of captures, so the overlay can stay up),
    /// keeping the selection and annotations. `capture` is replaceable for tests.
    func refresh(from view: CaptureView, capture: @escaping () async throws -> [CGDirectDisplayID: CGImage] = CaptureSession.captureByDisplay) {
        guard let index = views.firstIndex(where: { $0 === view }) else { return }
        guard historyScreen != index else {
            view.showMessage("正在回看历史截图，按 . 回到当前屏幕后再刷新")
            return
        }
        let state = view.currentState()
        Task { @MainActor in
            do {
                let images = try await capture()
                guard index < self.views.count, self.views[index] === view, let image = images[view.displayID] else { return }
                self.liveSnapshots[index] = image
                self.replaceView(at: index, snapshot: image, rects: self.liveWindowRects[index], entry: state, asReplay: false)
                self.views[index].showMessage("已刷新截图", duration: 1)
            } catch {
                view.showMessage("刷新失败：\(error.localizedDescription)")
            }
        }
    }

    static func captureByDisplay() async throws -> [CGDirectDisplayID: CGImage] {
        var result: [CGDirectDisplayID: CGImage] = [:]
        for snapshot in try await CaptureEngine.captureScreens() {
            let id = (snapshot.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            result[id] = snapshot.image
        }
        return result
    }

    private func replaceView(at index: Int, snapshot: CGImage, rects: [CGRect], entry: HistoryEntry?, asReplay: Bool = true) {
        let old = views[index]
        old.tearDown()
        if owner === old { owner = nil }
        let window = windows[index]
        let local = CGRect(origin: .zero, size: window.frame.size)
        let view = CaptureView(frame: local, snapshot: snapshot, windowRects: rects, displayID: old.displayID)
        view.session = self
        window.contentView = CaptureRootView(frame: local, snapshot: snapshot, captureView: view)
        views[index] = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        if let entry {
            view.restore(entry, asReplay: asReplay)
        } else {
            view.primeCursor()
        }
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
                    if let owner { self.record(owner) }
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
        if Settings.shared.keepCancelledHistory, let owner { record(owner) }
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
