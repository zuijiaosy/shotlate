import AppKit
import ScreenCaptureKit
import ShotlateCore
import UniformTypeIdentifiers

/// GIF recording of a screen region.
///
/// Frames come from an `SCStream` at up to `framesPerSecond` and are encoded straight into a file in the
/// temporary folder, so memory stays flat however long the recording runs. Encoding takes the newest frame
/// and skips any that arrived while it was busy; each frame is stamped with the time it arrived, so a
/// skipped frame only lengthens the one before it and playback keeps real time.
///
/// The region is recorded at 1 pixel per point (and smaller for very large regions): GIFs are for
/// sharing, and 2x frames would make files four times the size and encoding four times slower.
/// Recording stops from the panel, the menu bar icon, or the capture shortcut; it also stops at
/// `maxDuration` or `maxBytes`, or when the stream fails, keeping what was recorded.
final class GIFRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) static var current: GIFRecorder?
    /// Posted on the main thread when a recording starts or ends.
    static let didChange = Notification.Name("GIFRecorder.didChange")

    static let framesPerSecond = 15
    static let maxPixels = 1920 * 1200
    static let maxBytes = 200 << 20
    var maxDuration: TimeInterval = 60

    let rect: CGRect
    let screen: NSScreen
    let pixelWidth: Int
    let pixelHeight: Int
    let fileURL: URL
    private let capturesScreen: Bool
    private let frameWindow: NSWindow
    private let frameView = DashedFrameView()
    private let panel = GIFRecordingPanel()
    private let captureQueue = DispatchQueue(label: "app.shotlate.gif.capture", qos: .userInitiated)
    private let encodeQueue = DispatchQueue(label: "app.shotlate.gif.encode", qos: .userInitiated)
    private var stream: SCStream?
    private var timer: Timer?
    private let startedAt = CACurrentMediaTime()
    private var finished = false
    private var stopMessage: String?

    // Newest frame waiting to be encoded, guarded by `frameLock`.
    private let frameLock = NSLock()
    private var pendingFrame: (pixels: CVPixelBuffer, time: CFTimeInterval)?
    private var draining = false
    private var accepting = true

    // Touched only on `encodeQueue`.
    private var encoder: GIFEncoder?
    private var file: FileHandle?
    private var encodeError: Error?

    /// Called with the finished file instead of opening the result window (used by the checks).
    var onFinished: ((URL) -> Void)?

    var elapsed: TimeInterval { CACurrentMediaTime() - startedAt }

    /// `rect` is in global Cocoa coordinates. With `capturesScreen` false no stream is started and frames
    /// come only from `ingest` (for the checks). Returns nil, after telling the user, if it can't start.
    @discardableResult
    static func start(rect: CGRect, screen: NSScreen, capturesScreen: Bool = true) -> GIFRecorder? {
        guard current == nil else { return nil }
        do {
            let recorder = try GIFRecorder(rect: rect, screen: screen, capturesScreen: capturesScreen)
            current = recorder
            recorder.begin()
            NotificationCenter.default.post(name: didChange, object: recorder)
            return recorder
        } catch {
            HUD.show("无法开始录制 GIF：\(error.localizedDescription)", on: screen)
            return nil
        }
    }

    private init(rect: CGRect, screen: NSScreen, capturesScreen: Bool) throws {
        // Whole points, so the stream's source and output have the same shape.
        let r = CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: max(1, rect.width.rounded()), height: max(1, rect.height.rounded()))
        self.rect = r
        self.screen = screen
        self.capturesScreen = capturesScreen
        let shrink = min(1, (Double(Self.maxPixels) / Double(r.width * r.height)).squareRoot())
        pixelWidth = max(1, Int((r.width * shrink).rounded()))
        pixelHeight = max(1, Int((r.height * shrink).rounded()))

        let folder = Self.temporaryFolder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The file keeps this name when copied and pasted into another app.
        fileURL = folder.appendingPathComponent(Exporter.defaultFileName(fileExtension: "gif"))
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let file = try FileHandle(forWritingTo: fileURL)
        self.file = file
        encoder = try GIFEncoder(width: pixelWidth, height: pixelHeight) { try file.write(contentsOf: $0) }

        frameWindow = NSWindow(contentRect: r.insetBy(dx: -4, dy: -4), styleMask: .borderless, backing: .buffered, defer: false)
        frameWindow.isOpaque = false
        frameWindow.backgroundColor = .clear
        frameWindow.ignoresMouseEvents = true
        frameWindow.level = .statusBar
        frameWindow.hasShadow = false
        frameWindow.isReleasedWhenClosed = false
        frameWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        frameView.color = .systemRed
        frameWindow.contentView = frameView
        super.init()
        panel.onStop = { [weak self] in self?.stop() }
        panel.onCancel = { [weak self] in self?.cancel() }
    }

    /// Recordings that were never copied or saved; old ones are removed when a new recording starts.
    static let temporaryFolder = FileManager.default.temporaryDirectory.appendingPathComponent("Shotlate GIF")

    private static func removeOldRecordings() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let folders = (try? fm.contentsOfDirectory(at: temporaryFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders {
            let date = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff { try? fm.removeItem(at: folder) }
        }
    }

    private func begin() {
        Self.removeOldRecordings()
        // Our windows are left out of the stream, so the frame and panel never show up in the GIF.
        frameWindow.orderFrontRegardless()
        panel.place(near: rect, on: screen)
        panel.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        tick()
        guard capturesScreen else { return }

        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      let display = content.displays.first(where: { $0.displayID == number.uint32Value })
                else { throw CocoaError(.featureUnsupported) }
                guard !finished else { return }
                let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
                try await stream.startCapture()
                self.stream = stream
                if finished { try? await stream.stopCapture() }
            } catch {
                guard !finished else { return }
                cancel()
                HUD.show("无法开始录制 GIF：\(error.localizedDescription)", on: screen)
            }
        }
    }

    private var configuration: SCStreamConfiguration {
        let config = SCStreamConfiguration()
        // sourceRect is in the display's points with a top-left origin.
        config.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
                                   width: rect.width, height: rect.height)
        config.width = pixelWidth
        config.height = pixelHeight
        // Rounding can leave the output a fraction of a pixel off the region's shape; stretch rather than add a border.
        config.preservesAspectRatio = false
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.framesPerSecond))
        config.queueDepth = 5
        return config
    }

    private func tick() {
        guard !finished else { return }
        let seconds = elapsed
        panel.setElapsed(seconds)
        if seconds >= maxDuration {
            stop(message: "已录满 \(Int(maxDuration)) 秒，录制结束")
        }
    }

    // MARK: Frames

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Idle frames repeat the previous content; only complete frames carry new pixels.
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixels = sampleBuffer.imageBuffer
        else { return }
        ingest(pixels, time: CACurrentMediaTime())
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [self] in
            guard !finished else { return }
            stop(message: "录制中断：\(error.localizedDescription)")
        }
    }

    /// Queues a 32BGRA frame that appeared at `time` (CACurrentMediaTime); any thread.
    func ingest(_ pixels: CVPixelBuffer, time: CFTimeInterval) {
        frameLock.lock()
        guard accepting else {
            frameLock.unlock()
            return
        }
        pendingFrame = (pixels, time)
        let start = !draining
        draining = true
        frameLock.unlock()
        if start { encodeQueue.async { self.drain() } }
    }

    /// Encodes the newest pending frame until none is left.
    private func drain() {
        while encodeNext(keepDraining: true) {}
    }

    /// Returns false once nothing is pending.
    @discardableResult
    private func encodeNext(keepDraining: Bool) -> Bool {
        frameLock.lock()
        guard let frame = pendingFrame else {
            if keepDraining { draining = false }
            frameLock.unlock()
            return false
        }
        pendingFrame = nil
        frameLock.unlock()

        guard let encoder, encodeError == nil, let pixels = Self.pixels(of: frame.pixels, width: pixelWidth, height: pixelHeight)
        else { return true }
        do {
            try encoder.add(pixels, time: frame.time)
        } catch {
            encodeError = error
            DispatchQueue.main.async { self.stop() }
            return true
        }
        if encoder.byteCount > Self.maxBytes {
            DispatchQueue.main.async { self.stop(message: "GIF 已达到 \(Self.maxBytes >> 20) MB，录制结束") }
        }
        return true
    }

    /// Copies a frame's rows into a tightly packed array; nil if it isn't the size the encoder expects.
    static func pixels(of buffer: CVPixelBuffer, width: Int, height: Int) -> [UInt32]? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        return [UInt32](unsafeUninitializedCapacity: width * height) { out, count in
            for y in 0..<height {
                memcpy(out.baseAddress! + y * width, base + y * rowBytes, width * 4)
            }
            count = width * height
        }
    }

    // MARK: Stop

    private func tearDown() {
        finished = true
        frameLock.lock()
        accepting = false
        frameLock.unlock()
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
        timer?.invalidate()
        timer = nil
        frameWindow.orderOut(nil)
        panel.orderOut(nil)
        if GIFRecorder.current === self { GIFRecorder.current = nil }
        NotificationCenter.default.post(name: GIFRecorder.didChange, object: self)
    }

    /// Ends the recording and opens the result. `message` is shown alongside, for stops the user didn't ask for.
    func stop(message: String? = nil, endTime: CFTimeInterval = CACurrentMediaTime()) {
        guard !finished else { return }
        tearDown()
        stopMessage = message
        let screen = self.screen
        // Queued after any frame being encoded; a frame still waiting is encoded first, so the GIF includes it.
        encodeQueue.async { [self] in
            encodeNext(keepDraining: false)
            let result: Result<GIFInfo, Error>
            do {
                if let encodeError { throw encodeError }
                guard let encoder else { throw GIFEncoder.Failure.noFrames }
                try encoder.finish(endTime: endTime)
                try file?.close()
                file = nil
                result = .success(GIFInfo(url: fileURL, width: pixelWidth, height: pixelHeight, frames: encoder.frameCount,
                                          duration: max(0, endTime - startedAt), bytes: encoder.byteCount))
            } catch {
                try? file?.close()
                file = nil
                try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
                result = .failure(error)
            }
            DispatchQueue.main.async { [self] in
                switch result {
                case let .success(info):
                    if let onFinished {
                        onFinished(info.url)
                    } else {
                        GIFResultWindow.show(info, on: screen)
                    }
                    if let message = stopMessage { HUD.show(message, on: screen) }
                case let .failure(error):
                    if case GIFEncoder.Failure.noFrames? = error as? GIFEncoder.Failure {
                        HUD.show(stopMessage ?? "没有录到画面", on: screen)
                    } else {
                        HUD.show("GIF 录制失败：\(error.localizedDescription)", on: screen)
                    }
                }
            }
        }
    }

    func cancel() {
        guard !finished else { return }
        tearDown()
        encodeQueue.async { [self] in
            try? file?.close()
            file = nil
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
    }

    /// Runs after everything queued for encoding so far (for the checks).
    func testing_waitForEncoder() async {
        await withCheckedContinuation { continuation in encodeQueue.async { continuation.resume() } }
    }

    var testing_panel: GIFRecordingPanel { panel }
}

// The encoder and file are only touched on `encodeQueue`, pending frames under `frameLock`;
// everything else runs on the main thread.
extension GIFRecorder: @unchecked Sendable {}

struct GIFInfo {
    var url: URL
    var width: Int
    var height: Int
    var frames: Int
    var duration: TimeInterval
    var bytes: Int
}

/// Small bar by the region while recording: elapsed time, cancel and stop.
final class GIFRecordingPanel: NSPanel {
    var onStop: () -> Void = {}
    var onCancel: () -> Void = {}

    private let root = PanelView()
    private let dot = NSView()
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)
    static let size = CGSize(width: 196, height: 40)

    init() {
        super.init(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
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
        root.radius = 10

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        dot.frame = CGRect(x: 14, y: 15, width: 10, height: 10)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timeLabel.frame = CGRect(x: 30, y: 11, width: 48, height: 18)
        for (button, action) in [(cancelButton, #selector(cancelTapped)), (stopButton, #selector(stopTapped))] {
            button.bezelStyle = .push
            button.controlSize = .small
            button.target = self
            button.action = action
        }
        cancelButton.frame = CGRect(x: 80, y: 8, width: 52, height: 24)
        stopButton.frame = CGRect(x: 134, y: 8, width: 52, height: 24)
        stopButton.keyEquivalent = "\r"
        for view in [dot, timeLabel, cancelButton, stopButton] { root.addSubview(view) }
    }

    /// Below the region's right end; above it if there's no room; inside its bottom edge for full-screen regions.
    func place(near rect: CGRect, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = Self.size
        var origin = CGPoint(x: rect.maxX - size.width, y: rect.minY - size.height - 10)
        if origin.y < visible.minY + 4 { origin.y = rect.maxY + 10 }
        if origin.y + size.height > visible.maxY - 4 { origin.y = max(visible.minY, rect.minY) + 12 }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        setFrame(CGRect(origin: origin, size: size), display: false)
    }

    func setElapsed(_ seconds: TimeInterval) {
        let s = Int(seconds)
        timeLabel.stringValue = String(format: "%d:%02d", s / 60, s % 60)
        // Blink the dot once a second.
        dot.alphaValue = seconds.truncatingRemainder(dividingBy: 1) < 0.6 ? 1 : 0.25
    }

    var testing_time: String { timeLabel.stringValue }

    @objc private func cancelTapped() { onCancel() }
    @objc private func stopTapped() { onStop() }

    override func cancelOperation(_ sender: Any?) { onCancel() }
}

/// Plays a finished recording with copy and save. Closing it without copying discards the file.
final class GIFResultWindow: NSWindow, NSWindowDelegate {
    private static var open: [GIFResultWindow] = []
    let info: GIFInfo
    private var copied = false

    static func show(_ info: GIFInfo, on screen: NSScreen) {
        let window = GIFResultWindow(info: info, screen: screen)
        open.append(window)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private init(info: GIFInfo, screen: NSScreen) {
        self.info = info
        // One GIF pixel was one point on screen.
        let natural = CGSize(width: info.width, height: info.height)
        let visible = screen.visibleFrame
        let fit = min(1, visible.width * 0.8 / natural.width, (visible.height * 0.8 - 52) / natural.height)
        let shown = CGSize(width: (natural.width * fit).rounded(), height: (natural.height * fit).rounded())
        let contentWidth = max(shown.width, 360), contentHeight = shown.height + 52
        let frame = CGRect(x: visible.midX - contentWidth / 2, y: visible.midY - contentHeight / 2, width: contentWidth, height: contentHeight)
        super.init(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        let size = ByteCountFormatter.string(fromByteCount: Int64(info.bytes), countStyle: .file)
        title = "GIF · \(info.width) × \(info.height) · \(String(format: "%.1f", info.duration)) 秒 · \(size)"
        isReleasedWhenClosed = false
        delegate = self

        let root = NSView(frame: CGRect(origin: .zero, size: frame.size))
        let imageView = NSImageView(frame: CGRect(x: (contentWidth - shown.width) / 2, y: 52, width: shown.width, height: shown.height))
        imageView.image = NSImage(contentsOf: info.url)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        root.addSubview(imageView)

        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.frame = CGRect(x: 12, y: 12, width: contentWidth - 24, height: 28)
        let hint = NSTextField(labelWithString: "关闭窗口即放弃")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        bar.addArrangedSubview(hint)
        bar.addArrangedSubview(NSView())
        for (title, action) in [("保存 (S)", #selector(saveGIF)), ("复制 (C)", #selector(copyGIF))] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .push
            if action == #selector(copyGIF) { button.keyEquivalent = "\r" }
            bar.addArrangedSubview(button)
        }
        root.addSubview(bar)
        contentView = root
    }

    /// The file and its GIF data: chat apps take the file, so the animation survives pasting.
    @objc private func copyGIF() {
        let item = NSPasteboardItem()
        item.setString(info.url.absoluteString, forType: .fileURL)
        if let data = try? Data(contentsOf: info.url) { item.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier)) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        copied = true
        close()
        HUD.show("已复制 GIF")
    }

    @objc private func saveGIF() {
        do {
            let directory = Settings.shared.saveDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = Exporter.availableURL(in: directory, name: info.url.lastPathComponent)
            try FileManager.default.copyItem(at: info.url, to: url)
            close()
            HUD.show("已保存到 \(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard event.keyCode != 53 else { return close() }
        guard flags.isEmpty else { return super.keyDown(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": copyGIF()
        case "s": saveGIF()
        default: super.keyDown(with: event)
        }
    }

    static var testing_open: [GIFResultWindow] { open }

    func windowWillClose(_ notification: Notification) {
        GIFResultWindow.open.removeAll { $0 === self }
        // A copied file stays for pasting; old ones are cleared when a later recording starts.
        if !copied { try? FileManager.default.removeItem(at: info.url.deletingLastPathComponent()) }
    }
}
