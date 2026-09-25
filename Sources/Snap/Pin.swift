import AppKit
import SnapCore

/// Keeps track of open pins, and whether they are all hidden.
final class PinManager {
    static let shared = PinManager()

    private(set) var pins: [PinWindow] = []
    /// Hidden pins stay open; showing them again brings back every one.
    private(set) var isHidingAll = false

    var hasPins: Bool { !pins.isEmpty }

    /// Shows `rep` as a floating pin; `frame` is in global screen coordinates at 100% zoom.
    @discardableResult
    func pin(_ rep: NSBitmapImageRep, frame: CGRect) -> PinWindow {
        // A new pin while the others are hidden brings them back, so nothing is left hidden by surprise.
        if isHidingAll {
            isHidingAll = false
            refreshVisibility()
        }
        let window = PinWindow(rep: rep, frame: frame)
        pins.append(window)
        window.orderFrontRegardless()
        window.makeKey()
        window.prepareText()
        return window
    }

    func isShown(_ pin: PinWindow) -> Bool { !isHidingAll }

    private func refreshVisibility() {
        for pin in pins {
            if isHidingAll { pin.orderOut(nil) } else if !pin.isVisible { pin.orderFrontRegardless() }
        }
    }

    /// Pins the images on the clipboard (image data, or image files copied in Finder), centered on the mouse.
    /// Returns false when there is no image.
    @discardableResult
    func pinClipboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let images = ClipboardPinSource.read(pasteboard)
        guard !images.isEmpty else {
            HUD.show("剪贴板里没有图片")
            return false
        }
        // Several image files fan out from the cursor so they don't cover each other exactly.
        for (i, rep) in images.enumerated() {
            let offset = CGFloat(i) * 24
            pin(rep, centeredAt: CGPoint(x: mouse.x + offset, y: mouse.y - offset), on: screen)
        }
        return true
    }

    /// Places a pin centered on `center`, kept inside the screen and scaled down if it is larger than the screen.
    @discardableResult
    func pin(_ rep: NSBitmapImageRep, centeredAt center: CGPoint, on screen: NSScreen?) -> PinWindow {
        let size = rep.size
        var frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        var fit: CGFloat = 1
        if let visible = screen?.visibleFrame {
            fit = min(1, visible.width * 0.9 / max(size.width, 1), visible.height * 0.9 / max(size.height, 1))
            let shown = CGSize(width: size.width * fit, height: size.height * fit)
            frame.origin.x = min(max(center.x - shown.width / 2, visible.minX), max(visible.minX, visible.maxX - shown.width))
            frame.origin.y = min(max(center.y - shown.height / 2, visible.minY), max(visible.minY, visible.maxY - shown.height))
        }
        // Whole-point origin: a half-point one makes the window server grow the window by a point.
        frame.origin = CGPoint(x: frame.minX.rounded(), y: frame.minY.rounded())
        let window = pin(rep, frame: frame)
        if fit < 1 {
            window.setZoom(fit, anchor: frame.origin)
        }
        return window
    }

    func closeAll() {
        for pin in pins { pin.closePin() }
        isHidingAll = false
    }

    /// Hides every pin, or shows them again if they are hidden.
    func toggleHidden() {
        if isHidingAll {
            isHidingAll = false
            refreshVisibility()
        } else {
            guard !pins.isEmpty else {
                HUD.show("当前没有贴图")
                return
            }
            isHidingAll = true
            refreshVisibility()
            HUD.show("已隐藏 \(pins.count) 张贴图，再按一次显示")
        }
    }

    fileprivate func didClose(_ pin: PinWindow) {
        pins.removeAll { $0 === pin }
    }
}

/// A screenshot floating above other windows. Scroll to zoom, ⌥-scroll for opacity, Esc to close.
final class PinWindow: NSPanel {
    private(set) var rep: NSBitmapImageRep

    private func refreshImage() {
        pinView.image = image(from: rep)
    }

    private var baseSize: CGSize
    private(set) var zoom: CGFloat = 1
    private let pinView = PinView()
    private var scrollAccumulator: CGFloat = 0
    private var isClosing = false

    init(rep: NSBitmapImageRep, frame: CGRect) {
        self.rep = rep
        self.baseSize = frame.size
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        pinView.window_ = self
        pinView.image = image(from: rep)
        contentView = pinView
    }

    override var canBecomeKey: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        pinView.needsDisplay = true
        prepareText()
    }

    override func resignKey() {
        super.resignKey()
        pinView.needsDisplay = true
    }

    private func image(from rep: NSBitmapImageRep) -> NSImage {
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Zoom and opacity

    func setZoom(_ newZoom: CGFloat, anchor: CGPoint? = nil, flash: Bool = true) {
        let clamped = min(max(newZoom, 0.1), 8)
        let anchor = anchor ?? CGPoint(x: frame.midX, y: frame.midY)
        let rx = (anchor.x - frame.minX) / max(frame.width, 1)
        let ry = (anchor.y - frame.minY) / max(frame.height, 1)
        let size = CGSize(width: max(8, baseSize.width * clamped), height: max(8, baseSize.height * clamped))
        let origin = CGPoint(x: anchor.x - rx * size.width, y: anchor.y - ry * size.height)
        zoom = clamped
        setFrame(CGRect(origin: origin, size: size), display: true)
        if flash { pinView.flash("\(Int((clamped * 100).rounded()))%") }
    }

    func setOpacity(_ value: CGFloat) {
        alphaValue = min(max(value, 0.2), 1)
        pinView.flash("透明度 \(Int((alphaValue * 100).rounded()))%")
    }

    override func scrollWheel(with event: NSEvent) {
        scrollAccumulator += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10 : event.scrollingDeltaY
        guard abs(scrollAccumulator) >= 1 else { return }
        let steps = scrollAccumulator.rounded(.towardZero)
        scrollAccumulator -= steps
        if event.modifierFlags.contains(.option) {
            setOpacity(alphaValue + steps * 0.05)
        } else {
            setZoom(zoom * pow(1.1, steps), anchor: NSEvent.mouseLocation)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let arrows: [UInt16: CGPoint] = [123: CGPoint(x: -1, y: 0), 124: CGPoint(x: 1, y: 0), 125: CGPoint(x: 0, y: -1), 126: CGPoint(x: 0, y: 1)]
        if flags == .command && key == "w" {
            closePin()
        } else if event.keyCode == 53 {
            cancelOperation(nil)
        } else if flags.isEmpty, key == " " {
            annotate()
        } else if flags.isEmpty, key == "y" {
            toggleTranslation()
        } else if flags.subtracting(.shift).isEmpty, key == "=" || key == "+" {
            setZoom(zoom * 1.1)
        } else if flags.isEmpty, key == "-" {
            setZoom(zoom / 1.1)
        } else if flags == .command && key == "c" {
            if pinView.selectedText != nil { copySelectedText() } else { copyImage() }
        } else if flags == .command && key == "s" {
            saveImage()
        } else if (flags.isEmpty || flags == .command) && key == "0" {
            setZoom(1)
        } else if let d = arrows[event.keyCode], flags.isEmpty || flags == .shift {
            let step: CGFloat = flags == .shift ? 10 : 1
            setFrameOrigin(CGPoint(x: frame.minX + d.x * step, y: frame.minY + d.y * step))
        } else {
            super.keyDown(with: event)
        }
    }

    /// `Esc` first drops a text selection, then closes the pin.
    override func cancelOperation(_ sender: Any?) {
        if pinView.textSelection != nil {
            pinView.textSelection = nil
        } else {
            closePin()
        }
    }

    // MARK: Actions

    @objc func copyImage() {
        Exporter.copy(rep)
        pinView.flash("已复制")
    }

    @objc func copySelectedText() {
        guard let text = pinView.selectedText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        pinView.flash("已复制文字")
    }

    @objc func saveImage() {
        do {
            let url = try Exporter.save(rep, format: Settings.shared.imageFormat, directory: Settings.shared.saveDirectory)
            pinView.flash("已保存")
            HUD.show("已保存到 \(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
        } catch {
            pinView.flash("保存失败")
        }
    }

    @objc func zoomMenuItem(_ sender: NSMenuItem) { setZoom(CGFloat(sender.tag) / 100) }
    @objc func opacityMenuItem(_ sender: NSMenuItem) { setOpacity(CGFloat(sender.tag) / 100) }
    @objc func closeFromMenu() { closePin() }

    // MARK: Text selection

    /// The picture the text layout was (or is being) recognized from.
    private var textSource: NSBitmapImageRep?
    private var textTask: Task<Void, Never>?

    /// Recognizes the pin's text in the background so it can be selected with the mouse; once per picture.
    func prepareText() {
        guard textSource !== rep, let cg = rep.cgImage else { return }
        let source = rep
        textSource = source
        pinView.textLayout = nil
        textTask?.cancel()
        textTask = Task { @MainActor [weak self] in
            let layout = try? await TextRecognizer.layout(cg, bounds: CGRect(origin: .zero, size: source.size))
            guard let self, !Task.isCancelled, self.rep === source else { return }
            self.pinView.textLayout = layout
        }
    }

    /// The picture changed (replaced, translated): the old text layout no longer fits.
    private func pictureChanged() {
        textSource = nil
        pinView.textLayout = nil
        prepareText()
    }

    // MARK: Translation

    /// The untranslated and translated pictures once translated; `Y` switches between them.
    private var translationPair: (original: NSBitmapImageRep, translated: NSBitmapImageRep)?
    private(set) var showsTranslation = false
    private var isTranslating = false
    /// Replaceable for the self-checks, which translate without a network.
    var translate: (NSBitmapImageRep) async throws -> NSBitmapImageRep = { try await ImageTranslator.translate($0) }

    @objc func toggleTranslation() {
        if let pair = translationPair {
            showsTranslation.toggle()
            swapImage(showsTranslation ? pair.translated : pair.original)
            pinView.flash(showsTranslation ? "译文" : "原文")
            return
        }
        guard !isTranslating else { return }
        // Only the real translator needs the key.
        if translateUsesDefault, Settings.shared.apiKey.isEmpty {
            pinView.flash("请先在设置里填写翻译的 API Key")
            return
        }
        isTranslating = true
        pinView.flash("正在翻译…")
        let original = rep
        Task { @MainActor in
            defer { isTranslating = false }
            do {
                let translated = try await translate(original)
                translationPair = (original, translated)
                showsTranslation = true
                swapImage(translated)
                pinView.flash("已翻译 · Y 切换原文")
            } catch {
                pinView.flash((error as? LocalizedError)?.errorDescription ?? "翻译失败")
            }
        }
    }

    /// Whether `translate` is still the real translator (then an API key is needed).
    var translateUsesDefault = true

    /// Shows another picture of the same size without resetting zoom or position.
    private func swapImage(_ newRep: NSBitmapImageRep) {
        rep = newRep
        refreshImage()
        pictureChanged()
    }

    /// Replaces the picture after annotating; the pin keeps its place and zoom.
    func replaceImage(_ newRep: NSBitmapImageRep) {
        translationPair = nil
        showsTranslation = false
        let zoomNow = zoom
        rep = newRep
        baseSize = newRep.size
        refreshImage()
        pictureChanged()
        setZoom(zoomNow, anchor: CGPoint(x: frame.minX, y: frame.maxY), flash: false)
    }

    @objc func annotate() {
        CaptureSession.beginPinEdit(self)
    }

    var testing_view: PinView { pinView }

    @objc func closeAllFromMenu() { PinManager.shared.closeAll() }

    func closePin() {
        guard !isClosing else { return }
        isClosing = true
        PinManager.shared.didClose(self)
        orderOut(nil)
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String = "", tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.tag = tag
            return item
        }
        if pinView.selectedText != nil {
            menu.addItem(item("复制选中文字", #selector(copySelectedText), "c"))
            menu.addItem(item("复制图片", #selector(copyImage)))
        } else {
            menu.addItem(item("复制", #selector(copyImage), "c"))
        }
        menu.addItem(item("保存", #selector(saveImage), "s"))
        menu.addItem(item("标注…", #selector(annotate), " "))
        menu.items.last?.keyEquivalentModifierMask = []
        let translateItem = item(translationPair == nil ? "翻译" : (showsTranslation ? "显示原文" : "显示译文"), #selector(toggleTranslation), "y")
        translateItem.keyEquivalentModifierMask = []
        menu.addItem(translateItem)
        menu.addItem(.separator())

        let zoomItem = NSMenuItem(title: "缩放", action: nil, keyEquivalent: "")
        let zoomMenu = NSMenu()
        for percent in [25, 50, 100, 150, 200, 300] {
            let i = item("\(percent)%", #selector(zoomMenuItem(_:)), tag: percent)
            i.state = abs(zoom * 100 - CGFloat(percent)) < 0.5 ? .on : .off
            zoomMenu.addItem(i)
        }
        zoomItem.submenu = zoomMenu
        menu.addItem(zoomItem)

        let opacityItem = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for percent in [100, 80, 60, 40, 20] {
            let i = item("\(percent)%", #selector(opacityMenuItem(_:)), tag: percent)
            i.state = abs(alphaValue * 100 - CGFloat(percent)) < 0.5 ? .on : .off
            opacityMenu.addItem(i)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        menu.addItem(.separator())
        menu.addItem(item("关闭", #selector(closeFromMenu), "w"))
        menu.addItem(item("关闭全部贴图", #selector(closeAllFromMenu)))
        return menu
    }
}

/// Draws the pinned image with a thin border that shows whether this pin is the active one.
final class PinView: NSView {
    weak var window_: PinWindow?
    var image: NSImage? { didSet { needsDisplay = true } }
    private let label = ToastView()
    /// Where the drag started: the mouse and the window's origin.
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?
    /// The picture's recognized text, in image points; nil until recognized or when there is none.
    var textLayout: TextLayout? { didSet { textSelection = nil } }
    var textSelection: TextSpan? { didSet { needsDisplay = true } }
    private var selectingText = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(label)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = (window_?.zoom ?? 1) >= 2 ? .none : .high
        image?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        if let textSelection, let textLayout {
            selectionBlue.withAlphaComponent(0.3).setFill()
            for rect in textLayout.rects(for: textSelection) { NSBezierPath(rect: viewRect(rect)).fill() }
        }
        let active = window_?.isKeyWindow ?? false
        (active ? selectionBlue : NSColor.gray.withAlphaComponent(0.5)).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = active ? 1.5 : 1
        border.stroke()
    }

    func flash(_ text: String) {
        label.show(text, duration: 1.2, maxWidth: max(120, bounds.width))
        label.setFrameOrigin(CGPoint(x: max(4, bounds.maxX - label.frame.width - 6), y: max(4, bounds.maxY - label.frame.height - 6)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount >= 2 {
            // Closing is Esc's job; double-click selects a word, triple-click the line.
            if let layout = textLayout, textPosition(at: p) != nil {
                textSelection = event.clickCount == 2 ? layout.word(at: imagePoint(p)) : layout.line(at: imagePoint(p))
            }
            return
        }
        // Pressing on text selects it, like a text field; anywhere else drags the pin.
        if let position = textPosition(at: p) {
            if event.modifierFlags.contains(.shift), let current = textSelection {
                textSelection = TextSpan(anchor: current.anchor, focus: position)
            } else {
                textSelection = TextSpan(anchor: position, focus: position)
            }
            selectingText = true
            return
        }
        textSelection = nil
        guard let window else { return }
        dragStart = (NSEvent.mouseLocation, window.frame.origin)
    }

    override func mouseDragged(with event: NSEvent) {
        if selectingText {
            extendTextSelection(to: convert(event.locationInWindow, from: nil))
            return
        }
        drag(to: NSEvent.mouseLocation)
    }

    // MARK: Text

    var selectedText: String? {
        guard let textSelection, let textLayout else { return nil }
        let text = textLayout.text(for: textSelection)
        return text.isEmpty ? nil : text
    }

    private var imageSize: CGSize { image?.size ?? bounds.size }

    private func imagePoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * imageSize.width / max(bounds.width, 1), y: p.y * imageSize.height / max(bounds.height, 1))
    }

    private func viewRect(_ r: CGRect) -> CGRect {
        let sx = bounds.width / max(imageSize.width, 1), sy = bounds.height / max(imageSize.height, 1)
        return CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy)
    }

    /// The caret under a view point when it is on recognized text.
    func textPosition(at p: CGPoint) -> TextPosition? {
        textLayout?.hitTest(imagePoint(p))
    }

    func extendTextSelection(to p: CGPoint) {
        guard let textLayout, let position = textLayout.nearestPosition(to: imagePoint(p)) else { return }
        textSelection?.focus = position
    }

    override func mouseEntered(with event: NSEvent) {
        window_?.prepareText()
    }

    override func mouseMoved(with event: NSEvent) {
        (textPosition(at: convert(event.locationInWindow, from: nil)) != nil ? NSCursor.iBeam : NSCursor.openHand).set()
    }

    func drag(to mouse: CGPoint) {
        guard let dragStart, let window else { return }
        window.setFrameOrigin(CGPoint(x: dragStart.origin.x + mouse.x - dragStart.mouse.x, y: dragStart.origin.y + mouse.y - dragStart.mouse.y))
    }

    func testing_beginDrag(at mouse: CGPoint) {
        guard let window else { return }
        dragStart = (mouse, window.frame.origin)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        if selectingText, textSelection?.isEmpty == true { textSelection = nil }
        selectingText = false
    }

    override func otherMouseDown(with event: NSEvent) {
        // Middle click: back to 100%.
        window_?.setZoom(1)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeKey()
        guard let menu = window_?.makeMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
