import AppKit
import SnapCore

/// Keeps track of open pins and the ones closed recently, so they can be restored.
final class PinManager {
    static let shared = PinManager()
    static let historyLimit = 10

    private(set) var pins: [PinWindow] = []
    private var history: [(rep: NSBitmapImageRep, frame: CGRect)] = []
    /// Hidden pins stay open and don't count as closed, so they are not pushed into the restore history.
    private(set) var isHidingAll = false

    var hasHistory: Bool { !history.isEmpty }
    var hasPins: Bool { !pins.isEmpty }
    var hasPassthrough: Bool { pins.contains { $0.ignoresMouseEvents } }

    /// Shows `rep` as a floating pin; `frame` is in global screen coordinates at 100% zoom.
    @discardableResult
    func pin(_ rep: NSBitmapImageRep, frame: CGRect) -> PinWindow {
        // A new pin while the others are hidden brings them back, so nothing is left hidden by surprise.
        if isHidingAll { showAll() }
        let window = PinWindow(rep: rep, frame: frame)
        pins.append(window)
        window.orderFrontRegardless()
        window.makeKey()
        return window
    }

    /// Pins the image on the clipboard, centered on the mouse. Returns false when there is no image.
    @discardableResult
    func pinClipboard() -> Bool {
        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            HUD.show("剪贴板里没有图片")
            return false
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        let size = image.size.width > 0 ? image.size : CGSize(width: cg.width, height: cg.height)
        rep.size = size
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        var frame = CGRect(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2, width: size.width, height: size.height)
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
            frame.origin.y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
        }
        pin(rep, frame: frame)
        return true
    }

    func restoreLast() {
        guard let last = history.popLast() else { return }
        pin(last.rep, frame: last.frame)
    }

    func closeAll() {
        for pin in pins { pin.close(keepInHistory: true) }
        isHidingAll = false
    }

    /// Hides every pin, or shows them again if they are hidden.
    func toggleHidden() {
        if isHidingAll {
            showAll()
        } else {
            guard hasPins else {
                HUD.show("当前没有贴图")
                return
            }
            for pin in pins { pin.orderOut(nil) }
            isHidingAll = true
            HUD.show("已隐藏 \(pins.count) 张贴图，再按一次显示")
        }
    }

    private func showAll() {
        isHidingAll = false
        for pin in pins { pin.orderFrontRegardless() }
    }

    func disablePassthrough() {
        for pin in pins where pin.ignoresMouseEvents { pin.setPassthrough(false) }
    }

    fileprivate func didClose(_ pin: PinWindow, keepInHistory: Bool) {
        pins.removeAll { $0 === pin }
        guard keepInHistory else { return }
        history.append((pin.rep, pin.frameAtFullSize))
        if history.count > Self.historyLimit { history.removeFirst() }
    }
}

/// A screenshot floating above other windows. Scroll to zoom, ⌥-scroll for opacity, double-click to close.
final class PinWindow: NSPanel {
    private(set) var rep: NSBitmapImageRep
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
    }

    override func resignKey() {
        super.resignKey()
        pinView.needsDisplay = true
    }

    /// The window frame this pin would have at 100%, keeping its current center.
    var frameAtFullSize: CGRect {
        CGRect(x: frame.midX - baseSize.width / 2, y: frame.midY - baseSize.height / 2, width: baseSize.width, height: baseSize.height)
    }

    private func image(from rep: NSBitmapImageRep) -> NSImage {
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Zoom and opacity

    func setZoom(_ newZoom: CGFloat, anchor: CGPoint? = nil) {
        let clamped = min(max(newZoom, 0.1), 8)
        let anchor = anchor ?? CGPoint(x: frame.midX, y: frame.midY)
        let rx = (anchor.x - frame.minX) / max(frame.width, 1)
        let ry = (anchor.y - frame.minY) / max(frame.height, 1)
        let size = CGSize(width: max(8, baseSize.width * clamped), height: max(8, baseSize.height * clamped))
        let origin = CGPoint(x: anchor.x - rx * size.width, y: anchor.y - ry * size.height)
        zoom = clamped
        setFrame(CGRect(origin: origin, size: size), display: true)
        pinView.flash("\(Int((clamped * 100).rounded()))%")
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
        if event.keyCode == 53 && flags == .shift {
            destroy()
        } else if event.keyCode == 53 || (flags == .command && key == "w") {
            close(keepInHistory: true)
        } else if flags.isEmpty, let action = Self.digitActions[key] {
            action(self)()
        } else if flags.subtracting(.shift).isEmpty, key == "=" || key == "+" {
            setZoom(zoom * 1.1)
        } else if flags.isEmpty, key == "-" {
            setZoom(zoom / 1.1)
        } else if flags == .command && key == "c" {
            copyImage()
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

    override func cancelOperation(_ sender: Any?) {
        close(keepInHistory: true)
    }

    /// Same number keys as Snipaste: 1/2 rotate clockwise/counter-clockwise, 3/4 flip horizontally/vertically.
    private static let digitActions: [String: (PinWindow) -> () -> Void] = [
        "1": { $0.rotateRight }, "2": { $0.rotateLeft }, "3": { $0.flipHorizontal }, "4": { $0.flipVertical },
    ]

    // MARK: Actions

    @objc func copyImage() {
        Exporter.copy(rep)
        pinView.flash("已复制")
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

    @objc func recognizeText() {
        guard let cg = rep.cgImage else { return }
        pinView.flash("正在识别…")
        Task { @MainActor in
            do {
                let result = try await TextRecognizer.recognize(cg, selection: CGRect(origin: .zero, size: rep.size))
                let text = result.plainText
                guard !text.isEmpty else {
                    pinView.flash("没有识别到文字")
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                pinView.flash("已复制 \(result.lines.count) 行文字")
            } catch {
                pinView.flash("识别失败")
            }
        }
    }

    @objc func zoomMenuItem(_ sender: NSMenuItem) { setZoom(CGFloat(sender.tag) / 100) }
    @objc func opacityMenuItem(_ sender: NSMenuItem) { setOpacity(CGFloat(sender.tag) / 100) }
    @objc func rotateLeft() { transform(.rotateLeft) }
    @objc func rotateRight() { transform(.rotateRight) }
    @objc func flipHorizontal() { transform(.flipHorizontal) }
    @objc func flipVertical() { transform(.flipVertical) }
    @objc func togglePassthrough() { setPassthrough(!ignoresMouseEvents) }

    @objc func toggleFloating() {
        level = level == .floating ? .normal : .floating
        pinView.flash(level == .floating ? "已置顶" : "已取消置顶")
    }

    @objc func closeFromMenu() { close(keepInHistory: true) }

    /// Closes without keeping a copy to restore.
    @objc func destroy() { close(keepInHistory: false) }
    @objc func closeAllFromMenu() { PinManager.shared.closeAll() }

    func setPassthrough(_ on: Bool) {
        ignoresMouseEvents = on
        pinView.passthrough = on
        if on { HUD.show("鼠标穿透已开启，可从菜单栏 Snap → 取消贴图的鼠标穿透 恢复") }
    }

    func close(keepInHistory: Bool) {
        guard !isClosing else { return }
        isClosing = true
        PinManager.shared.didClose(self, keepInHistory: keepInHistory)
        orderOut(nil)
    }

    private enum Transform { case rotateLeft, rotateRight, flipHorizontal, flipVertical }

    private func transform(_ t: Transform) {
        guard let cg = rep.cgImage else { return }
        let w = cg.width, h = cg.height
        let rotates = t == .rotateLeft || t == .rotateRight
        let (ow, oh) = rotates ? (h, w) : (w, h)
        guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        switch t {
        case .rotateRight:
            ctx.translateBy(x: 0, y: CGFloat(oh))
            ctx.rotate(by: -.pi / 2)
        case .rotateLeft:
            ctx.translateBy(x: CGFloat(ow), y: 0)
            ctx.rotate(by: .pi / 2)
        case .flipHorizontal:
            ctx.translateBy(x: CGFloat(ow), y: 0)
            ctx.scaleBy(x: -1, y: 1)
        case .flipVertical:
            ctx.translateBy(x: 0, y: CGFloat(oh))
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return }
        let newRep = NSBitmapImageRep(cgImage: out)
        newRep.size = rotates ? CGSize(width: rep.size.height, height: rep.size.width) : rep.size
        rep = newRep
        if rotates { baseSize = CGSize(width: baseSize.height, height: baseSize.width) }
        pinView.image = image(from: newRep)
        setZoom(zoom)
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String = "", tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.tag = tag
            return item
        }
        menu.addItem(item("复制", #selector(copyImage), "c"))
        menu.addItem(item("保存", #selector(saveImage), "s"))
        menu.addItem(item("识别文字", #selector(recognizeText)))
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

        menu.addItem(item("向右旋转", #selector(rotateRight), "1"))
        menu.addItem(item("向左旋转", #selector(rotateLeft), "2"))
        menu.addItem(item("水平翻转", #selector(flipHorizontal), "3"))
        menu.addItem(item("垂直翻转", #selector(flipVertical), "4"))
        for i in menu.items.suffix(4) { i.keyEquivalentModifierMask = [] }
        menu.addItem(.separator())
        let passthrough = item("鼠标穿透", #selector(togglePassthrough))
        passthrough.state = ignoresMouseEvents ? .on : .off
        menu.addItem(passthrough)
        let floating = item("始终置顶", #selector(toggleFloating))
        floating.state = level == .floating ? .on : .off
        menu.addItem(floating)
        menu.addItem(.separator())
        menu.addItem(item("关闭", #selector(closeFromMenu), "w"))
        let destroyItem = item("销毁（不可恢复）", #selector(destroy), "\u{1b}")
        destroyItem.keyEquivalentModifierMask = .shift
        menu.addItem(destroyItem)
        menu.addItem(item("关闭全部贴图", #selector(closeAllFromMenu)))
        return menu
    }
}

/// Draws the pinned image with a thin border that shows whether this pin is the active one.
final class PinView: NSView {
    weak var window_: PinWindow?
    var image: NSImage? { didSet { needsDisplay = true } }
    var passthrough = false { didSet { needsDisplay = true } }
    private let label = ToastView()
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = (window_?.zoom ?? 1) >= 2 ? .none : .high
        image?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        let active = window_?.isKeyWindow ?? false
        let color: NSColor = passthrough ? .systemGreen : active ? selectionBlue : NSColor.gray.withAlphaComponent(0.5)
        color.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = active || passthrough ? 1.5 : 1
        border.stroke()
    }

    func flash(_ text: String) {
        label.show(text, duration: 1.2, maxWidth: max(120, bounds.width))
        label.setFrameOrigin(CGPoint(x: max(4, bounds.maxX - label.frame.width - 6), y: 6))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if event.clickCount == 2 {
            window_?.close(keepInHistory: true)
            return
        }
        dragStart = (NSEvent.mouseLocation, window?.frame.origin ?? .zero)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let window else { return }
        let m = NSEvent.mouseLocation
        window.setFrameOrigin(CGPoint(x: dragStart.origin.x + m.x - dragStart.mouse.x, y: dragStart.origin.y + m.y - dragStart.mouse.y))
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }

    override func otherMouseDown(with event: NSEvent) {
        // Middle click: back to 100%.
        window_?.setZoom(1)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window_?.makeMenu()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
