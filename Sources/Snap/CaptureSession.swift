import AppKit
import SnapCore

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
    /// Grabs the screens as they are now; replaceable for tests.
    var liveCapture: () async throws -> [CGDirectDisplayID: CGImage] = CaptureSession.captureByDisplay
    private(set) var isFinished = false

    /// Outputs to perform as soon as a selection is made (`snap://capture?output=…`, `snip -o …`).
    var autoOutputs: [CaptureRequest.Output] = []

    /// `replay` opens straight into the most recent capture from history.
    /// `initialSelection` (Cocoa global) opens with that area already selected, as after a super snip.
    static func begin(replay: Bool = false, autoOutputs: [CaptureRequest.Output] = [], initialSelection: CGRect? = nil) {
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
        // Element frames are read in the background and arrive a moment after the overlay; until then windows are used.
        let elements: Task<[UIElementNode], Never>? = Settings.shared.detectElements && ElementCollector.isTrusted
            ? Task.detached(priority: .userInitiated) { ElementCollector.collect(pids: ElementCollector.frontApps()) } : nil
        Task { @MainActor in
            defer { isStarting = false }
            do {
                let snapshots = try await CaptureEngine.captureScreens()
                guard !snapshots.isEmpty else { return }
                let session = CaptureSession(snapshots: snapshots, windowFrames: windowFrames, pointer: pointer, previousApp: previousApp)
                session.autoOutputs = autoOutputs
                current = session
                session.show()
                if replay, let view = session.activeView { session.stepHistory(1, from: view) }
                if let area = initialSelection { session.preselect(area) }
                if let elements {
                    let nodes = await elements.value
                    if !session.isFinished { session.deliver(elements: nodes) }
                }
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

    // MARK: Boards

    /// A whiteboard (solid canvas) or transparent board over the live screen, on the screen with the pointer.
    static func beginBoard(transparent: Bool, color: NSColor = .white) {
        guard current == nil, !isStarting else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        if transparent, !CaptureEngine.hasPermission {
            // Exporting a transparent board needs a screenshot of what is under it.
            requestPermission()
            return
        }
        let session = CaptureSession(previousApp: NSWorkspace.shared.frontmostApplication)
        let image = boardImage(size: screen.frame.size, scale: screen.backingScaleFactor, color: transparent ? .clear : color)
        let window = OverlayWindow(screen: screen)
        if transparent {
            window.isOpaque = false
            window.backgroundColor = .clear
            // Clear pixels would otherwise let clicks fall through to the apps below.
            window.ignoresMouseEvents = false
        }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        session.install(window: window, image: image, displayID: displayID, mode: transparent ? .transparentBoard : .whiteboard)
        current = session
        session.show()
        session.views.first?.startBoard()
    }

    static func boardImage(size: CGSize, scale: CGFloat, color: NSColor) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(color.usingColorSpace(.sRGB)?.cgColor ?? CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        return ctx.makeImage()!
    }

    // MARK: Pin editing

    private weak var editingPin: PinWindow?
    private var editingPinZoom: CGFloat = 1

    /// Opens the annotation tools over `pin`. `frame` overrides the screen frame (for offscreen checks).
    @discardableResult
    static func beginPinEdit(_ pin: PinWindow, in frame: CGRect? = nil) -> CaptureSession? {
        guard current == nil, !isStarting else { return nil }
        pin.exitThumbnail()
        let zoom = pin.zoom
        // Edit at 100% so the pin keeps its full resolution.
        pin.setZoom(1, anchor: CGPoint(x: pin.frame.minX, y: pin.frame.maxY), flash: false)
        let screen = pin.screen ?? NSScreen.screens.first { $0.frame.intersects(pin.frame) } ?? NSScreen.main
        guard let screenFrame = frame ?? screen?.frame else { return nil }
        let scale = screen?.backingScaleFactor ?? 2
        let local = CGRect(x: pin.frame.minX - screenFrame.minX, y: screenFrame.maxY - pin.frame.maxY,
                           width: pin.frame.width, height: pin.frame.height)
        let image = pinCanvas(pin.rep, at: local, screenSize: screenFrame.size, scale: scale)

        let session = CaptureSession(previousApp: NSWorkspace.shared.frontmostApplication)
        let window = OverlayWindow(screen: screen ?? NSScreen.screens[0])
        window.setFrame(screenFrame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        session.editingPin = pin
        session.editingPinZoom = zoom
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        session.install(window: window, image: image, displayID: displayID, mode: .pinEdit)
        current = session
        pin.orderOut(nil)
        if frame == nil { session.show() }
        session.views[0].startPinEdit(rect: local)
        return session
    }

    /// A transparent screen-size image with the pin drawn where it sits.
    private static func pinCanvas(_ rep: NSBitmapImageRep, at rect: CGRect, screenSize: CGSize, scale: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(screenSize.width * scale), height: Int(screenSize.height * scale), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        if let cg = rep.cgImage {
            // CG's origin is bottom-left.
            ctx.draw(cg, in: CGRect(x: rect.minX * scale, y: (screenSize.height - rect.maxY) * scale, width: rect.width * scale, height: rect.height * scale))
        }
        return ctx.makeImage()!
    }

    func applyPinEdit(_ rep: NSBitmapImageRep) {
        editingPin?.replaceImage(rep)
        finish()
    }

    private func install(window: OverlayWindow, image: CGImage, displayID: CGDirectDisplayID, mode: CaptureMode) {
        let local = CGRect(origin: .zero, size: window.frame.size)
        let view = CaptureView(frame: local, snapshot: image, windowRects: [], displayID: displayID, mode: mode)
        view.session = self
        window.contentView = CaptureRootView(frame: local, snapshot: image, captureView: view)
        windows = [window]
        views = [view]
        liveSnapshots = [image]
        liveWindowRects = [[]]
    }

    /// An offscreen session over `image`, for scripted checks; nothing is shown on the real screens.
    static func makeForTesting(image: CGImage, size: CGSize, history: CaptureHistory, mode: CaptureMode = .screenshot) -> CaptureSession {
        let session = CaptureSession(previousApp: nil)
        session.history = history
        let window = OverlayWindow(screen: NSScreen.screens[0])
        window.setFrame(CGRect(x: -9000, y: -9000, width: size.width, height: size.height), display: false)
        session.install(window: window, image: image, displayID: 0, mode: mode)
        session.views[0].startBoard()
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

    /// Hands element frames (Cocoa global coordinates) to each screen's view, converted to its flipped local space.
    func deliver(elements: [UIElementNode]) {
        for (view, window) in zip(views, windows) where view.mode == .screenshot {
            let frame = window.frame
            let local = elements.map { node in
                UIElementNode(rect: CGRect(x: node.rect.minX - frame.minX, y: frame.maxY - node.rect.maxY,
                                           width: node.rect.width, height: node.rect.height), parent: node.parent)
            }
            view.setElements(local)
        }
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

    /// Selects `area` (Cocoa global) on the screen that holds its center.
    func preselect(_ area: CGRect) {
        let center = CGPoint(x: area.midX, y: area.midY)
        guard let index = windows.firstIndex(where: { $0.frame.contains(center) }) else { return }
        let frame = windows[index].frame
        views[index].preselect(CGRect(x: area.minX - frame.minX, y: frame.maxY - area.maxY, width: area.width, height: area.height))
        windows[index].makeKeyAndOrderFront(nil)
    }

    /// Runs the requested outputs for `view`'s fresh selection and closes the capture.
    func performAutoOutputs(from view: CaptureView) {
        guard !autoOutputs.isEmpty, let rep = view.exportImage(format: .png), let frame = view.selectionOnScreen,
              let pinRep = view.exportImage(format: .png, shadow: false) else { return }
        let outputs = autoOutputs
        autoOutputs = []
        record(view)
        finish()
        // Pins never carry the drop shadow; copies and files follow the shadow setting like a normal capture.
        let results = AutomationRunner.deliver(pinRep, frame: frame, outputs: outputs.filter { $0 == .pin })
            + AutomationRunner.deliver(rep, frame: frame, outputs: outputs.filter { $0 != .pin })
        Sound.playCapture()
        HUD.show(results.joined(separator: "，"))
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
        isFinished = true
        if let pin = editingPin {
            editingPin = nil
            if PinManager.shared.isShown(pin) { pin.orderFrontRegardless() }
            if abs(editingPinZoom - 1) > 0.001 {
                pin.setZoom(editingPinZoom, anchor: CGPoint(x: pin.frame.minX, y: pin.frame.maxY), flash: false)
            }
            pin.makeKey()
        }
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
