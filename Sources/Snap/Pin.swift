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
    /// While set, only this pin is shown.
    private(set) weak var soloPin: PinWindow?

    /// Named sets of pins; only the current group's pins are on screen. Names persist across launches.
    private(set) var groups: [String] {
        get { UserDefaults.standard.stringArray(forKey: "pin.groups").flatMap { $0.isEmpty ? nil : $0 } ?? [Self.defaultGroup] }
        set { UserDefaults.standard.set(newValue, forKey: "pin.groups") }
    }
    private(set) var currentGroup = PinManager.defaultGroup
    static let defaultGroup = "默认"

    var hasHistory: Bool { !history.isEmpty }
    var hasPins: Bool { !pins.isEmpty }
    var hasPassthrough: Bool { pins.contains { $0.ignoresMouseEvents } }

    /// Shows `rep` as a floating pin in the current group; `frame` is in global screen coordinates at 100% zoom.
    @discardableResult
    func pin(_ rep: NSBitmapImageRep, frame: CGRect) -> PinWindow {
        // A new pin while the others are hidden (or soloed) brings them back, so nothing is left hidden by surprise.
        isHidingAll = false
        soloPin = nil
        if !groups.contains(currentGroup) { currentGroup = groups[0] }
        let window = PinWindow(rep: rep, frame: frame)
        window.group = currentGroup
        pins.append(window)
        refreshVisibility()
        window.orderFrontRegardless()
        window.makeKey()
        return window
    }

    /// Whether `pin` should be on screen given hide-all, the current group and solo.
    func isShown(_ pin: PinWindow) -> Bool {
        guard !isHidingAll, pin.group == currentGroup else { return false }
        return soloPin == nil || soloPin === pin
    }

    /// Brings windows in line with `isShown`, only touching the ones that change so the stacking order is kept.
    private func refreshVisibility() {
        for pin in pins {
            let shown = isShown(pin)
            if shown, !pin.isVisible { pin.orderFrontRegardless() }
            if !shown, pin.isVisible { pin.orderOut(nil) }
        }
    }

    // MARK: Groups

    var pinsInCurrentGroup: [PinWindow] { pins.filter { $0.group == currentGroup } }

    func count(in group: String) -> Int { pins.filter { $0.group == group }.count }

    func switchGroup(to name: String) {
        guard groups.contains(name) else { return }
        currentGroup = name
        isHidingAll = false
        soloPin = nil
        refreshVisibility()
        HUD.show("贴图分组：\(name)（\(count(in: name)) 张）")
    }

    /// Cycles to the next group.
    func switchToNextGroup() {
        let list = groups
        guard let i = list.firstIndex(of: currentGroup) else { return switchGroup(to: list[0]) }
        switchGroup(to: list[(i + 1) % list.count])
    }

    /// Adds a group (a unique name is made if taken) and switches to it.
    @discardableResult
    func createGroup(_ name: String) -> String {
        var unique = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if unique.isEmpty { unique = "分组 \(groups.count + 1)" }
        let base = unique
        var n = 2
        while groups.contains(unique) {
            unique = "\(base) \(n)"
            n += 1
        }
        groups.append(unique)
        switchGroup(to: unique)
        return unique
    }

    func renameGroup(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !groups.contains(name), let i = groups.firstIndex(of: old) else { return }
        groups[i] = name
        for pin in pins where pin.group == old { pin.group = name }
        if currentGroup == old { currentGroup = name }
    }

    /// Removes a group and closes its pins (they can still be restored). The last group can't be deleted.
    func deleteGroup(_ name: String) {
        guard groups.count > 1, let i = groups.firstIndex(of: name) else { return }
        for pin in pins where pin.group == name { pin.close(keepInHistory: true) }
        groups.remove(at: i)
        if currentGroup == name { switchGroup(to: groups[max(0, i - 1)]) }
    }

    func move(_ pin: PinWindow, to group: String) {
        guard groups.contains(group) else { return }
        pin.group = group
        if soloPin === pin { soloPin = nil }
        refreshVisibility()
    }

    // MARK: Solo

    func toggleSolo(_ pin: PinWindow) {
        soloPin = soloPin === pin ? nil : pin
        refreshVisibility()
        if soloPin != nil { HUD.show("只显示这张贴图，再选一次「Solo」恢复其他贴图") }
    }

    /// Pins what is on the clipboard (images, image files, colors, rich or plain text), centered on the mouse.
    /// Returns false when there is nothing that can be pinned.
    @discardableResult
    func pinClipboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let contents = ClipboardPinSource.read(pasteboard, scale: screen?.backingScaleFactor ?? 2)
        guard !contents.isEmpty else {
            HUD.show("剪贴板里没有可以贴的内容")
            return false
        }
        // Several image files fan out from the cursor so they don't cover each other exactly.
        for (i, content) in contents.enumerated() {
            let offset = CGFloat(i) * 24
            pin(content, centeredAt: CGPoint(x: mouse.x + offset, y: mouse.y - offset), on: screen)
        }
        return true
    }

    /// Places a pin centered on `center`, kept inside the screen and scaled down if it is larger than the screen.
    @discardableResult
    func pin(_ content: PinContent, centeredAt center: CGPoint, on screen: NSScreen?) -> PinWindow {
        let size = content.rep.size
        var frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        var fit: CGFloat = 1
        if let visible = screen?.visibleFrame {
            fit = min(1, visible.width * 0.9 / max(size.width, 1), visible.height * 0.9 / max(size.height, 1))
            let shown = CGSize(width: size.width * fit, height: size.height * fit)
            frame.origin.x = min(max(center.x - shown.width / 2, visible.minX), max(visible.minX, visible.maxX - shown.width))
            frame.origin.y = min(max(center.y - shown.height / 2, visible.minY), max(visible.minY, visible.maxY - shown.height))
        }
        let window = pin(content.rep, frame: frame)
        window.sourceText = content.text
        if fit < 1 {
            window.setZoom(fit, anchor: frame.origin)
        }
        return window
    }

    func restoreLast() {
        guard let last = history.popLast() else { return }
        pin(last.rep, frame: last.frame)
    }

    func closeAll() {
        for pin in pins { pin.close(keepInHistory: true) }
        isHidingAll = false
        soloPin = nil
    }

    /// Hides every pin, or shows them again if they are hidden.
    func toggleHidden() {
        if isHidingAll {
            isHidingAll = false
            refreshVisibility()
        } else {
            let shown = pins.filter(isShown)
            guard !shown.isEmpty else {
                HUD.show("当前没有贴图")
                return
            }
            isHidingAll = true
            refreshVisibility()
            HUD.show("已隐藏 \(shown.count) 张贴图，再按一次显示")
        }
    }

    func disablePassthrough() {
        for pin in pins where pin.ignoresMouseEvents { pin.setPassthrough(false) }
    }

    fileprivate func didClose(_ pin: PinWindow, keepInHistory: Bool) {
        pins.removeAll { $0 === pin }
        if soloPin === pin || soloPin == nil {
            soloPin = nil
            refreshVisibility()
        }
        guard keepInHistory else { return }
        history.append((pin.rep, pin.frameAtFullSize))
        if history.count > Self.historyLimit { history.removeFirst() }
    }
}

/// A screenshot floating above other windows. Scroll to zoom, ⌥-scroll for opacity, double-click to close.
final class PinWindow: NSPanel {
    private(set) var rep: NSBitmapImageRep
    /// The text this pin was rendered from, if any, for "copy text".
    var sourceText: String?
    var group = PinManager.defaultGroup
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
        let reference = frameBeforeThumbnail ?? frame
        return CGRect(x: reference.midX - baseSize.width / 2, y: reference.midY - baseSize.height / 2, width: baseSize.width, height: baseSize.height)
    }

    // MARK: Thumbnail

    /// The part of the image shown while collapsed to a thumbnail, in image points with a top-left origin.
    private(set) var thumbnail: CGRect?
    private var frameBeforeThumbnail: CGRect?
    static let thumbnailSide: CGFloat = 64

    /// Collapses the pin to `region` (in view points, top-left origin), keeping that region where it is on screen.
    func enterThumbnail(viewRegion region: CGRect) {
        let bounds = CGRect(origin: .zero, size: frame.size)
        let r = region.intersection(bounds)
        guard r.width >= 4, r.height >= 4, thumbnail == nil else { return }
        let scale = zoom
        thumbnail = CGRect(x: r.minX / scale, y: r.minY / scale, width: r.width / scale, height: r.height / scale)
        frameBeforeThumbnail = frame
        setFrame(CGRect(x: frame.minX + r.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height), display: true)
        pinView.thumbnail = thumbnail
    }

    /// A fixed-size square thumbnail around `point` (view points, top-left origin).
    func enterFixedThumbnail(around point: CGPoint) {
        let side = min(Self.thumbnailSide, frame.width, frame.height)
        var r = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        r.origin.x = min(max(0, r.minX), frame.width - side)
        r.origin.y = min(max(0, r.minY), frame.height - side)
        enterThumbnail(viewRegion: r)
    }

    func exitThumbnail() {
        guard thumbnail != nil, let previous = frameBeforeThumbnail else { return }
        // Put the full image back so the thumbnail's region stays where it is on screen.
        let region = thumbnail!
        let x = frame.minX - region.minX * zoom
        let maxY = frame.maxY + region.minY * zoom
        thumbnail = nil
        frameBeforeThumbnail = nil
        pinView.thumbnail = nil
        setFrame(CGRect(x: x, y: maxY - previous.height, width: previous.width, height: previous.height), display: true)
    }

    private func image(from rep: NSBitmapImageRep) -> NSImage {
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Zoom and opacity

    func setZoom(_ newZoom: CGFloat, anchor: CGPoint? = nil) {
        exitThumbnail()
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
        guard thumbnail == nil else { return }
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
        } else if flags == [.command, .shift] && key == "c" {
            copyText()
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

    @objc func copyText() {
        guard let sourceText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sourceText, forType: .string)
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

    @objc func toggleSolo() { PinManager.shared.toggleSolo(self) }

    @objc func moveToGroup(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        PinManager.shared.move(self, to: name)
    }

    @objc func toggleThumbnail() {
        if thumbnail != nil {
            exitThumbnail()
        } else {
            enterFixedThumbnail(around: CGPoint(x: frame.width / 2, y: frame.height / 2))
        }
    }

    var testing_view: PinView { pinView }

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
        exitThumbnail()
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
        if sourceText != nil {
            let copyTextItem = item("复制文字", #selector(copyText), "c")
            copyTextItem.keyEquivalentModifierMask = [.command, .shift]
            menu.addItem(copyTextItem)
        }
        menu.addItem(item("保存", #selector(saveImage), "s"))
        menu.addItem(item("识别文字", #selector(recognizeText)))
        menu.addItem(.separator())
        menu.addItem(item(thumbnail == nil ? "缩略图" : "恢复原大小", #selector(toggleThumbnail)))

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
        let solo = item("Solo：只显示这张", #selector(toggleSolo))
        solo.state = PinManager.shared.soloPin === self ? .on : .off
        menu.addItem(solo)
        let groups = PinManager.shared.groups
        if groups.count > 1 {
            let moveItem = NSMenuItem(title: "移到分组", action: nil, keyEquivalent: "")
            let moveMenu = NSMenu()
            for name in groups {
                let i = NSMenuItem(title: name, action: #selector(moveToGroup(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = name
                i.state = name == group ? .on : .off
                moveMenu.addItem(i)
            }
            moveItem.submenu = moveMenu
            menu.addItem(moveItem)
        }
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
    /// Region of the image to show while collapsed, in image points (top-left origin).
    var thumbnail: CGRect? { didSet { needsDisplay = true } }
    private let label = ToastView()
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?
    /// Right-drag box that becomes a thumbnail, in view points.
    private var regionStart: CGPoint?
    private var region: CGRect? { didSet { needsDisplay = true } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = (window_?.zoom ?? 1) >= 2 ? .none : .high
        if let image {
            var source = CGRect.zero
            if let t = thumbnail {
                // NSImage source rects have a bottom-left origin.
                source = CGRect(x: t.minX, y: image.size.height - t.maxY, width: t.width, height: t.height)
            }
            image.draw(in: bounds, from: source, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        }
        if let region {
            let path = NSBezierPath(rect: region.insetBy(dx: 0.5, dy: 0.5))
            NSColor.white.withAlphaComponent(0.8).setStroke()
            path.stroke()
            path.setLineDash([4, 3], count: 2, phase: 0)
            selectionBlue.setStroke()
            path.stroke()
        }
        let active = window_?.isKeyWindow ?? false
        let color: NSColor = passthrough ? .systemGreen : active ? selectionBlue : NSColor.gray.withAlphaComponent(0.5)
        color.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = active || passthrough ? 1.5 : 1
        if thumbnail != nil { border.setLineDash([3, 2], count: 2, phase: 0) }
        border.stroke()
    }

    func flash(_ text: String) {
        label.show(text, duration: 1.2, maxWidth: max(120, bounds.width))
        label.setFrameOrigin(CGPoint(x: max(4, bounds.maxX - label.frame.width - 6), y: max(4, bounds.maxY - label.frame.height - 6)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if event.clickCount == 2 {
            let p = convert(event.locationInWindow, from: nil)
            if window_?.thumbnail != nil {
                window_?.exitThumbnail()
            } else if event.modifierFlags.contains(.shift) {
                window_?.enterFixedThumbnail(around: p)
            } else {
                window_?.close(keepInHistory: true)
            }
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

    // Right-drag draws a box that becomes a thumbnail; a right click without dragging opens the menu.
    override func rightMouseDown(with event: NSEvent) {
        window?.makeKey()
        regionStart = window_?.thumbnail == nil ? convert(event.locationInWindow, from: nil) : nil
        region = nil
        if regionStart == nil { showMenu(event) }
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let regionStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        let r = CGRect(corners: regionStart, CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height)))
        region = r.width > 3 || r.height > 3 ? r : nil
    }

    override func rightMouseUp(with event: NSEvent) {
        defer {
            regionStart = nil
            region = nil
        }
        guard regionStart != nil else { return }
        if let region, region.width >= 8, region.height >= 8 {
            window_?.enterThumbnail(viewRegion: region)
        } else {
            showMenu(event)
        }
    }

    private func showMenu(_ event: NSEvent) {
        guard let menu = window_?.makeMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    // Test hooks: drive the right-drag without real events.
    func testing_rightDrag(from a: CGPoint, to b: CGPoint) {
        regionStart = a
        region = CGRect(corners: a, b)
        if let region { window_?.enterThumbnail(viewRegion: region) }
        regionStart = nil
        self.region = nil
    }
}
