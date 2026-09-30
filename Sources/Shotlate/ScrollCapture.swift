import Accelerate
import AppKit
import ApplicationServices
import ScreenCaptureKit
import ShotlateCore

/// Long screenshot: streams a screen region while it is scrolled, and stitches the frames with `ScrollStitcher`.
///
/// Frames come from an `SCStream` at up to 60 fps. Stitching always takes the newest frame and skips
/// any that arrived while it was busy, so a slow frame never builds a backlog. Scroll-wheel deltas
/// inside the region are passed to the stitcher as a hint. When stitching does lose track, the frame
/// turns orange and the user is told to scroll back; it resumes by itself once a frame overlaps the
/// last stitched one again.
///
/// The user scrolls by hand, or presses 自动滚动 to have Shotlate send scroll events and wait for
/// the content to settle after each one (needs Accessibility permission).
final class ScrollCaptureController: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) static var current: ScrollCaptureController?

    private let rect: CGRect
    private let screen: NSScreen
    private let scale: CGFloat
    private let frameWindow: NSWindow
    private let frameView = DashedFrameView()
    private let panel: ScrollCapturePanel
    private let stitcher: ScrollStitcher
    private let captureQueue = DispatchQueue(label: "app.shotlate.capture", qos: .userInitiated)
    private let stitchQueue = DispatchQueue(label: "app.shotlate.stitch", qos: .userInitiated)
    private var stream: SCStream?
    private var scrollMonitors: [Any] = []
    private var lastPreview = Date.distantPast
    private var finished = false
    private var lost = false
    private let log = ScrollLog.makeIfEnabled()

    // Newest frame waiting to be stitched, guarded by `frameLock`.
    private let frameLock = NSLock()
    private var pendingFrame: CVPixelBuffer?
    private var draining = false
    private var skipped = 0

    // Touched only on `stitchQueue`.
    /// Content movement in pixels since the last stitched frame, from precise scroll events;
    /// nil after a line-based mouse wheel event, whose pixel distance is unknown.
    private var pendingScroll: CGFloat? = 0
    private var stitchedFrames = 0

    // Auto scroll, on the main thread.
    private var autoScrolling = false
    private var autoStep: CGFloat = 0
    private var autoProgress = false
    private var autoIdleSteps = 0
    private var lastFrameAt = Date.distantPast

    private let excludeOwnWindows: Bool
    /// Called with the stitched image instead of opening the result window (used by the dev demo).
    var onFinished: ((CGImage) -> Void)?
    /// Override the system scroll event for testing; called with the requested pixel distance.
    var autoScrollBlock: ((CGFloat) -> Void)?

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
        // Overlay scroll bars can sit at either edge (right-to-left layouts, some web pages).
        stitcher = ScrollStitcher(maxHeight: 60_000, ignoredSideColumns: Int(16 * screen.backingScaleFactor))

        frameWindow = NSWindow(contentRect: r.insetBy(dx: -4, dy: -4), styleMask: .borderless, backing: .buffered, defer: false)
        frameWindow.isOpaque = false
        frameWindow.backgroundColor = .clear
        frameWindow.ignoresMouseEvents = true
        frameWindow.level = .statusBar
        frameWindow.hasShadow = false
        frameWindow.isReleasedWhenClosed = false
        frameWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        frameWindow.contentView = frameView

        panel = ScrollCapturePanel()
        super.init()
        panel.onFinish = { [weak self] in self?.finish() }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onAutoScroll = { [weak self] in self?.toggleAutoScroll() }
    }

    private func begin() {
        frameWindow.orderFrontRegardless()
        panel.place(next: rect, on: screen)
        panel.orderFrontRegardless()
        panel.setStatus("在框内滚动鼠标或触控板，Shotlate 会自动拼接；也可以点「自动滚动」。")
        log?.write("start rect \(rect) scale \(scale) screen \(screen.frame)")

        // Scrolling goes to the app under the region (global monitor), or to our own windows in the demo (local).
        scrollMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] in self?.noteScroll($0) },
            NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] in self?.noteScroll($0); return $0 },
        ].compactMap { $0 }

        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let own = excludeOwnWindows ? content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier } : []
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      let display = content.displays.first(where: { $0.displayID == number.uint32Value })
                else { throw CocoaError(.featureUnsupported) }
                guard !finished else { return }
                let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
                try await stream.startCapture()
                self.stream = stream
                log?.write("stream started")
                if finished { try? await stream.stopCapture() }
            } catch {
                log?.write("stream failed: \(error)")
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
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 4
        return config
    }

    private func noteScroll(_ event: NSEvent) {
guard rect.contains(NSEvent.mouseLocation), event.scrollingDeltaY != 0 else { return }
        // Negative deltaY scrolls towards the end of the document, i.e. the content moves up.
        let delta = event.hasPreciseScrollingDeltas ? -event.scrollingDeltaY * scale : nil
        log?.write("scroll \(event.scrollingDeltaY) precise \(event.hasPreciseScrollingDeltas) phase \(event.phase.rawValue) momentum \(event.momentumPhase.rawValue)")
        stitchQueue.async { [self] in
            if let delta, let pending = pendingScroll { pendingScroll = pending + delta } else { pendingScroll = nil }
        }
    }

    // MARK: SCStreamOutput (on captureQueue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Idle frames repeat the previous content; only complete frames carry new pixels.
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixels = sampleBuffer.imageBuffer
        else { return }
        frameLock.lock()
        if pendingFrame != nil { skipped += 1 }
        pendingFrame = pixels
        let start = !draining
        draining = true
        frameLock.unlock()
        if start { stitchQueue.async { self.drain() } }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log?.write("stream stopped: \(error)")
        DispatchQueue.main.async { [self] in
            guard !finished else { return }
            panel.setStatus("长截图已中断：\(error.localizedDescription)。点完成保留已拼接的部分。")
        }
    }

    // MARK: Stitching (on stitchQueue)

    /// Stitches the newest pending frame until none is left.
    private func drain() {
        while stitchNext(keepDraining: true) {}
    }

    /// Returns false once nothing is pending.
    @discardableResult
    private func stitchNext(keepDraining: Bool) -> Bool {
        frameLock.lock()
        guard let pixels = pendingFrame else {
            if keepDraining { draining = false }
            frameLock.unlock()
            return false
        }
        pendingFrame = nil
        let skippedFrames = skipped
        skipped = 0
        frameLock.unlock()

        guard let frame = PixelBuffer(bgra: pixels) else { return true }
        let began = Date()
        let hint = pendingScroll.flatMap { abs($0) >= 1 ? Int($0.rounded()) : nil }
        let result = stitcher.add(frame, expectedOffset: hint)
        switch result {
        case .started: pendingScroll = 0
        // Events not yet visible in this frame are few; starting over keeps a stale total from drifting.
        case .appended: pendingScroll = 0
        default: break
        }
        stitchedFrames += 1
        if let log {
            let ms = Int(Date().timeIntervalSince(began) * 1000)
            log.write("frame \(stitchedFrames) skipped \(skippedFrames) hint \(hint.map(String.init) ?? "-") \(ms) ms → \(result) height \(stitcher.height) | \(stitcher.lastDiagnostics)")
            log.save(frame, index: stitchedFrames)
        }
        DispatchQueue.main.async { self.handle(result) }
        return true
    }

    // MARK: Main thread

    private func handle(_ result: ScrollStitcher.Result) {
        guard !finished else { return }
        if ProcessInfo.processInfo.environment["SHOTLATE_DEBUG_STITCH"] != nil { print("stitch:", result, stitcher.height) }
        lastFrameAt = Date()
        switch result {
        case .started, .appended:
            if case .appended = result { autoProgress = true }
            setLost(false)
            panel.setStatus("\(stitcher.height.formatted()) px · " + (autoScrolling ? "自动滚动中…" : "继续滚动，或点完成"))
            refreshPreview(force: result == .started)
        case .unchanged:
            // A frame matching the last stitched one means we're back on track, even before new rows arrive.
            if lost {
                setLost(false)
                panel.setStatus("接上了，继续往下滚")
            }
        case .scrolledBack:
            if !lost, !autoScrolling { panel.setStatus("往回滚动的部分不会拼接，继续往下滚即可") }
        case .noOverlap:
            setLost(true)
            panel.setStatus(autoScrolling ? "跟丢了，正在往回找…" : "跟丢了：往回滚一点，回到橙线处的内容，接上后会继续")
        case .limitReached:
            panel.setStatus("已达到长度上限")
            finish()
        }
    }

    private func setLost(_ value: Bool) {
        guard lost != value else { return }
        lost = value
        frameView.isLost = value
        panel.setLost(value)
    }

    private func refreshPreview(force: Bool) {
        guard force || Date().timeIntervalSince(lastPreview) > 0.12 else { return }
        lastPreview = Date()
        let size = panel.previewPixelSize(scale: scale)
        stitchQueue.async { [weak self] in
            guard let self, let preview = self.stitcher.makePreview(targetWidth: size.width, maxHeight: size.height) else { return }
            DispatchQueue.main.async { self.panel.setPreview(preview, scale: self.scale) }
        }
    }

    // MARK: Auto scroll

    func toggleAutoScroll() {
        if autoScrolling {
            stopAutoScroll()
            panel.setStatus("已暂停自动滚动，可以手动滚动，或点完成")
            return
        }
        // Sending scroll events to other apps needs Accessibility permission; ask only when it's first used.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
guard AXIsProcessTrustedWithOptions(options) else {
            panel.setStatus("自动滚动需要辅助功能权限：在「系统设置 › 隐私与安全性 › 辅助功能」里打开 Shotlate，再点一次。")
            return
        }
        autoScrolling = true
        autoIdleSteps = 0
        autoStep = max(40, rect.height * 0.5)
        panel.setAutoScrolling(true)
        panel.setStatus("自动滚动中…移动鼠标不会打断，点暂停可以停下")
        scrollOnce()
    }

    private func stopAutoScroll() {
        autoScrolling = false
        panel.setAutoScrolling(false)
    }

    /// Sends one scroll to the region, then waits for the content to settle before judging it.
    private func scrollOnce() {
        guard autoScrolling, !finished else { return }
        autoProgress = false
        postScroll(-autoStep)
        let sent = Date()
        func check() {
            guard autoScrolling, !finished else { return }
            let now = Date()
            // Settled: no new frame for a while (smooth scrolling has finished), or waited long enough.
            let quiet = now.timeIntervalSince(lastFrameAt) > 0.25 && now.timeIntervalSince(sent) > 0.3
            guard quiet || now.timeIntervalSince(sent) > 1.2 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { check() }
                return
            }
            if lost {
                // Scrolled too far for the overlap: go back part of the way and take smaller steps.
                autoStep = max(40, autoStep * 0.6)
                postScroll(autoStep)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.scrollOnce() }
                return
            }
            autoIdleSteps = autoProgress ? 0 : autoIdleSteps + 1
            // Two scrolls in a row that change nothing: the end of the page.
            if autoIdleSteps >= 2 {
                log?.write("auto scroll reached the end")
                finish()
                return
            }
            scrollOnce()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
    }

    /// Scrolls the content under the region by `points`; negative moves towards the end of the document.
    /// Sent as a short trackpad gesture (began, changed, ended) because some views ignore continuous
    /// scroll events without a phase.
    /// Scrolls the content under the region by `points`; negative moves towards the end of the document.
    /// If `autoScrollBlock` is set (dev demo only), calls it with the magnitude so the block can
    /// drive an NSScrollView directly without Accessibility permission.
    /// Otherwise sends a trackpad gesture over CGEvent so the target app's own scroll view moves.
    private func postScroll(_ points: CGFloat) {
        if let block = autoScrollBlock {
            // Direct-drive path: the block adds `abs(points)` to the current scroll offset.
            let magnitude = -points  // points is negative toward end; block adds positive distance
            DispatchQueue.main.async { block(magnitude) }
            log?.write("auto scroll (block) \(points)")
            return
        }
        // CGEvent path: send a short trackpad gesture so apps that ignore plain scroll events still respond.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let center = CGPoint(x: rect.midX, y: primaryHeight - rect.midY)
        let inside = rect.contains(NSEvent.mouseLocation)
        if !inside { CGWarpMouseCursorPosition(center) }
        let location = inside ? CGEvent(source: nil)?.location ?? center : center
        let steps = 6
        var sent: CGFloat = 0
        for i in 0...steps {
            let phase: Int64 = i == 0 ? 1 : i == steps ? 4 : 2
            let delta = i == steps ? 0 : (points * CGFloat(i + 1) / CGFloat(steps)).rounded() - sent
            sent += delta
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) / 60) { [self] in
                guard !finished, let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                                     wheel1: Int32(delta), wheel2: 0, wheel3: 0) else { return }
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
                event.location = location
                event.post(tap: .cghidEventTap)
            }
        }
        log?.write("auto scroll (event) \(points)")
    }

    // MARK: Finish

    private func tearDown() {
        finished = true
        autoScrolling = false
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
        scrollMonitors.forEach(NSEvent.removeMonitor)
        scrollMonitors = []
        frameWindow.orderOut(nil)
        panel.orderOut(nil)
        if ScrollCaptureController.current === self { ScrollCaptureController.current = nil }
    }

    func cancel() {
        log?.write("cancel")
        tearDown()
    }

    func finish() {
        guard !finished else { return }
        tearDown()
        let scale = self.scale
        let screen = self.screen
        // Queued after any frame being stitched; a frame still waiting is stitched first, so the image includes it.
        stitchQueue.async { [stitcher, self] in
            self.stitchNext(keepDraining: false)
            let image = stitcher.makeImage()
            self.log?.write("finish height \(stitcher.height)")
            DispatchQueue.main.async {
                guard let image else { return }
                if let onFinished = self.onFinished {
                    onFinished(image)
                    return
                }
                ScrollResultWindow.show(image: image, scale: scale, on: screen)
            }
        }
    }
}

// Stitcher state and the scroll accumulator are only touched on `stitchQueue`, pending frames under
// `frameLock`; everything else runs on the main thread.
extension ScrollCaptureController: @unchecked Sendable {}

/// Per-session log and frame dump for diagnosing stitching, written to ~/Library/Logs/Shotlate/scroll-<time>/.
/// On with `defaults write app.shotlate.Shotlate scroll.debug -bool YES`, or SHOTLATE_DEBUG_STITCH / SHOTLATE_DUMP_FRAMES=<dir>.
/// Replay the frames with `Shotlate --stitch-replay <dir>`.
final class ScrollLog: @unchecked Sendable {
    let directory: URL
    private let handle: FileHandle
    private let started = Date()
    private let queue = DispatchQueue(label: "app.shotlate.scroll-log", qos: .utility)
    private var saved = 0
    static let maxFrames = 300

    static func makeIfEnabled() -> ScrollLog? {
        let env = ProcessInfo.processInfo.environment
        guard UserDefaults.standard.bool(forKey: "scroll.debug") || env["SHOTLATE_DEBUG_STITCH"] != nil || env["SHOTLATE_DUMP_FRAMES"] != nil
        else { return nil }
        let directory: URL
        if let dir = env["SHOTLATE_DUMP_FRAMES"] {
            directory = URL(fileURLWithPath: dir)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/Shotlate/scroll-\(formatter.string(from: Date()))")
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("log.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        return ScrollLog(directory: directory, handle: handle)
    }

    private init(directory: URL, handle: FileHandle) {
        self.directory = directory
        self.handle = handle
    }

    func write(_ line: String) {
        let t = String(format: "%7.3f", Date().timeIntervalSince(started))
        queue.async { self.handle.write(Data("\(t) \(line)\n".utf8)) }
    }

    /// Saves a frame that was handed to the stitcher, up to `maxFrames` per session.
    func save(_ frame: PixelBuffer, index: Int) {
        queue.async { [self] in
            guard saved < Self.maxFrames else { return }
            saved += 1
            guard let provider = CGDataProvider(data: Data(frame.data) as CFData),
                  let image = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: frame.bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent(String(format: "frame%04d.png", index)))
        }
    }
}

extension PixelBuffer {
    /// Copies a BGRA stream frame into RGBA, the layout `ScrollStitcher` and `CGImage` expect.
    init?(bgra pixels: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let error = data.withUnsafeMutableBytes { out -> vImage_Error in
            var source = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                       rowBytes: CVPixelBufferGetBytesPerRow(pixels))
            var destination = vImage_Buffer(data: out.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                            rowBytes: width * 4)
            return vImagePermuteChannels_ARGB8888(&source, &destination, [2, 1, 0, 3], vImage_Flags(kvImageNoFlags))
        }
        guard error == kvImageNoError else { return nil }
        self.init(width: width, height: height, bytesPerRow: width * 4, data: data)
    }
}

/// Dashed outline drawn just outside the captured region; orange while stitching has lost track.
private final class DashedFrameView: NSView {
    var isLost = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        (isLost ? NSColor.systemOrange : selectionBlue).setStroke()
        path.stroke()
    }
}

/// Control panel beside the region: live preview, status, auto scroll, cancel and done.
final class ScrollCapturePanel: NSPanel {
    var onFinish: () -> Void = {}
    var onCancel: () -> Void = {}
    var onAutoScroll: () -> Void = {}
    let previewWidth: CGFloat = 150

    private let root = PanelView()
    private let titleLabel = NSTextField(labelWithString: "长截图")
    private let preview = NSImageView()
    private let previewBox = FlippedView()
    /// Marks where stitching stopped, at the bottom of the preview, while it has lost track.
    private let breakLine = NSView()
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
        preview.imageScaling = .scaleAxesIndependently
        previewBox.addSubview(preview)
        breakLine.wantsLayer = true
        breakLine.layer?.backgroundColor = NSColor.systemOrange.cgColor
        breakLine.isHidden = true
        previewBox.addSubview(breakLine)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 4

        for (button, action) in [(autoButton, #selector(autoTapped)), (cancelButton, #selector(cancelTapped)), (doneButton, #selector(doneTapped))] {
            button.bezelStyle = .push
            button.controlSize = .small
            button.target = self
            button.action = action
        }
        doneButton.keyEquivalent = "\r"
        for view in [titleLabel, previewBox, status, autoButton, cancelButton, doneButton] as [NSView] { root.addSubview(view) }
    }

    override var canBecomeKey: Bool { true }

    func place(next rect: CGRect, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let height = min(max(rect.height, 320), min(540, visible.height - 20))
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
        autoButton.frame = CGRect(x: 12, y: buttonsY - 28, width: w - 24, height: 24)
        status.frame = CGRect(x: 14, y: autoButton.frame.minY - 50, width: w - 28, height: 46)
        previewBox.frame = CGRect(x: (w - previewWidth) / 2, y: 38, width: previewWidth, height: max(40, status.frame.minY - 44))
        layoutPreview()
    }

    /// The preview fills the box's width and grows down from the top; once full, it shows the newest rows.
    private func layoutPreview() {
        let box = previewBox.bounds
        let size = preview.image?.size ?? .zero
        let width = min(box.width, size.width), height = min(box.height, size.height)
        preview.frame = CGRect(x: (box.width - width) / 2, y: 0, width: width, height: height)
        breakLine.frame = CGRect(x: 0, y: max(0, height - 3), width: box.width, height: 3)
    }

    /// Pixel size of the preview box, so previews are rendered at exactly the size they are shown.
    func previewPixelSize(scale: CGFloat) -> (width: Int, height: Int) {
        (Int(previewBox.bounds.width * scale), Int(previewBox.bounds.height * scale))
    }

    func setStatus(_ text: String) {
        status.stringValue = text
    }

    func setLost(_ lost: Bool) {
        breakLine.isHidden = !lost
        status.textColor = lost ? .systemOrange : .secondaryLabelColor
    }

    func setAutoScrolling(_ on: Bool) {
        autoButton.title = on ? "暂停自动滚动" : "自动滚动"
    }

    func setPreview(_ image: CGImage, scale: CGFloat) {
        preview.image = NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        layoutPreview()
    }

    @objc private func autoTapped() { onAutoScroll() }
    @objc private func cancelTapped() { onCancel() }
    @objc private func doneTapped() { onFinish() }

    override func cancelOperation(_ sender: Any?) { onCancel() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
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
