import AppKit

/// Selection blue, matching iShot's selection frame and top bar.
let selectionBlue = NSColor(srgbRed: 0.16, green: 0.58, blue: 0.93, alpha: 1)

/// Rounded panel drawn to match the system appearance, with an optional caret pointing
/// at the control it belongs to. The caret sits outside `contentRect`.
class PanelView: NSView {
    enum CaretEdge {
        case top, bottom, left, right
        var isVertical: Bool { self == .top || self == .bottom }
    }

    static let caretHeight: CGFloat = 6
    var fill: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
    var radius: CGFloat = 9
    /// Edge and position along it (x for top/bottom, y for left/right).
    var caret: (edge: CaretEdge, offset: CGFloat)? {
        didSet {
            needsDisplay = true
            caretDidChange()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Swallow clicks in the padding so they don't reach the capture view.
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}

    func caretDidChange() {}

    var contentRect: CGRect {
        var r = bounds
        if let caret {
            switch caret.edge {
            case .top: r.origin.y += Self.caretHeight; r.size.height -= Self.caretHeight
            case .bottom: r.size.height -= Self.caretHeight
            case .left: r.origin.x += Self.caretHeight; r.size.width -= Self.caretHeight
            case .right: r.size.width -= Self.caretHeight
            }
        }
        return r
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = contentRect.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        if let caret {
            let tri = NSBezierPath()
            let h = Self.caretHeight
            if caret.edge.isVertical {
                let x = min(max(caret.offset, body.minX + radius + 6), body.maxX - radius - 6)
                let base = caret.edge == .top ? body.minY + 1 : body.maxY - 1
                let tip = caret.edge == .top ? body.minY - h + 0.5 : body.maxY + h - 0.5
                tri.move(to: CGPoint(x: x - 7, y: base))
                tri.line(to: CGPoint(x: x, y: tip))
                tri.line(to: CGPoint(x: x + 7, y: base))
            } else {
                let y = min(max(caret.offset, body.minY + radius + 6), body.maxY - radius - 6)
                let base = caret.edge == .left ? body.minX + 1 : body.maxX - 1
                let tip = caret.edge == .left ? body.minX - h + 0.5 : body.maxX + h - 0.5
                tri.move(to: CGPoint(x: base, y: y - 7))
                tri.line(to: CGPoint(x: tip, y: y))
                tri.line(to: CGPoint(x: base, y: y + 7))
            }
            tri.close()
            path.append(tri)
        }
        fill.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

/// Borderless button that runs a closure, with hover and "active" states.
final class ChromeButton: NSButton {
    private let handler: () -> Void
    private var hovering = false
    var tint: NSColor = .labelColor { didSet { needsDisplay = true } }
    /// Called when the pointer enters (true) or leaves (false); the toolbar shows its hover card with it.
    var onHover: ((Bool) -> Void)?

    var isActive = false {
        didSet { needsDisplay = true }
    }

    /// `tooltip` nil leaves the system tooltip off, for buttons that show their own hover card.
    init(image: NSImage, tooltip: String?, size: CGFloat = 30, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        self.image = image
        toolTip = tooltip
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
        NSCursor.arrow.set()
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
        onHover?(false)
    }

    override func draw(_ dirtyRect: NSRect) {
        let background: NSColor? = isActive ? selectionBlue.withAlphaComponent(0.18)
            : hovering && isEnabled ? NSColor.labelColor.withAlphaComponent(0.08) : nil
        if let background {
            background.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        contentTintColor = isActive ? selectionBlue : tint
        super.draw(dirtyRect)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The black "OCR" badge from iShot's toolbar; a template image so it follows the tint color.
func badgeImage(_ text: String) -> NSImage {
    let font = NSFont.systemFont(ofSize: 9.5, weight: .heavy)
    let size = CGSize(width: NSAttributedString(string: text, attributes: [.font: font]).size().width + 8, height: 15)
    let image = NSImage(size: size, flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        // Knock the letters out of the badge.
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        let label = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        let textSize = label.size()
        label.draw(at: CGPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2))
        return true
    }
    image.isTemplate = true
    return image
}

func symbolImage(_ name: String, size: CGFloat = 15, weight: NSFont.Weight = .regular) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
}

private func separator(height: CGFloat = 18) -> NSView {
    let line = NSBox()
    line.boxType = .separator
    line.translatesAutoresizingMaskIntoConstraints = false
    line.widthAnchor.constraint(equalToConstant: 1).isActive = true
    line.heightAnchor.constraint(equalToConstant: height).isActive = true
    return line
}

enum ToolbarAction {
    case tool(Tool), undo, ocr, translate, pin, longCapture, cancel, save, done

    /// Buttons with a single key can have it changed; undo, save, cancel and done keep the shortcuts everyone knows.
    var keyID: String? {
        switch self {
        case let .tool(t): return t.rawValue
        case .ocr: return "ocr"
        case .translate: return "translate"
        case .pin: return "pin"
        case .longCapture: return "longCapture"
        default: return nil
        }
    }

    /// Shown in the hover card.
    var shortcut: String {
        if let keyID { return ToolbarKeys.key(for: keyID).uppercased() }
        switch self {
        case .undo: return "⌘Z"
        case .cancel: return "Esc"
        case .save: return "⌘S"
        case .done: return "↩"
        default: return ""
        }
    }

    var title: String {
        switch self {
        case let .tool(t): return t.title
        case .undo: return "撤销"
        case .ocr: return "识别文字"
        case .translate: return "翻译到原位"
        case .pin: return "贴到屏幕上"
        case .longCapture: return "长截图"
        case .cancel: return "退出截图"
        case .save: return "保存"
        case .done: return "复制到剪贴板"
        }
    }

    /// An extra line under the shortcut, for what isn't obvious from the title.
    var note: String? {
        switch self {
        case .ocr: return "结果可以编辑，再点复制"
        case .translate: return "再按一次切换原文"
        case .longCapture: return "在选区里滚动，自动拼接"
        case .save: return "⇧⌘S 另存为"
        case .done: return "也可以双击选区"
        default: return nil
        }
    }

    /// Every button that has a single key, in toolbar order.
    static let keyed: [ToolbarAction] = Tool.allCases.map { .tool($0) } + [.ocr, .translate, .pin, .longCapture]

    /// The button an unmodified key press triggers.
    static func action(forKey key: String) -> ToolbarAction? {
        keyed.first { $0.keyID.map(ToolbarKeys.key(for:)) == key }
    }
}

/// The toolbar's single-key shortcuts, remembered across launches. A key belongs to one button at a time.
enum ToolbarKeys {
    private static let storageKey = "toolbar.keys"
    static let defaults: [String: String] = Dictionary(uniqueKeysWithValues: Tool.allCases.map { ($0.rawValue, $0.defaultKey) })
        .merging(["ocr": "x", "translate": "y", "pin": "t", "longCapture": "s"]) { a, _ in a }

    private static var stored: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }

    static func key(for id: String) -> String { stored[id] ?? defaults[id] ?? "" }

    /// Letters and digits, typed without modifiers.
    static func isAllowed(_ key: String) -> Bool {
        key.count == 1 && key.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    /// Gives `key` to `id`. The button that had it takes `id`'s old key, so no two share one; returns that button's id.
    @discardableResult
    static func assign(_ key: String, to id: String) -> String? {
        let old = self.key(for: id)
        guard key != old else { return nil }
        var all = defaults.merging(stored) { _, new in new }
        let other = all.first { $0.key != id && $0.value == key }?.key
        all[id] = key
        if let other { all[other] = old }
        stored = all
        return other
    }

    static func reset() { stored = [:] }
}

/// Bottom toolbar: plain icons in one row, like iShot's. A button's name and shortcut appear in a card
/// once the pointer rests on it for `cardDelay`.
/// Turns vertical when there is no room under the selection, to sit beside it instead.
final class ToolbarView: PanelView {
    private(set) var toolButtons: [Tool: ChromeButton] = [:]
    private(set) var translateButton: ChromeButton!
    private(set) var undoButton: ChromeButton!
    private let stack = NSStackView()
    private(set) var isVertical = false
    /// Sizes of the horizontal and vertical layouts, measured once.
    private(set) var horizontalSize = CGSize.zero
    private(set) var verticalSize = CGSize.zero
    /// Sits in the toolbar's superview so it can extend past the toolbar.
    let hoverCard = HoverCardView()

    init(handler: @escaping (ToolbarAction) -> Void) {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 4
        addSubview(stack)

        func add(_ action: ToolbarAction, _ image: NSImage) -> ChromeButton {
            let button = ChromeButton(image: image, tooltip: nil, size: 32) { handler(action) }
            button.onHover = { [unowned self, unowned button] inside in
                inside ? self.scheduleShow(for: action, at: button) : self.scheduleHide()
            }
            stack.addArrangedSubview(button)
            return button
        }
        for tool in Tool.allCases {
            toolButtons[tool] = add(.tool(tool), symbolImage(tool.symbol, size: 16, weight: .light))
        }
        undoButton = add(.undo, symbolImage("arrow.uturn.backward", size: 16, weight: .light))
        _ = add(.ocr, badgeImage("OCR"))
        translateButton = add(.translate, symbolImage("translate", size: 16, weight: .light))
        _ = add(.pin, symbolImage("pin", size: 16, weight: .light))
        _ = add(.longCapture, symbolImage("arrow.up.and.down.text.horizontal", size: 16, weight: .light))
        _ = add(.cancel, symbolImage("xmark", size: 16, weight: .light))
        _ = add(.save, symbolImage("square.and.arrow.down", size: 16, weight: .light))
        add(.done, symbolImage("checkmark", size: 16, weight: .regular)).tint = selectionBlue
        setVertical(true)
        verticalSize = frame.size
        setVertical(false)
        horizontalSize = frame.size
        hoverCard.onHover = { [unowned self] inside in
            if inside { self.cancelHide() } else if !self.hoverCard.isRecording { self.scheduleHide() }
        }
        hoverCard.onPick = { [unowned self] key in
            guard let action = self.cardAction, let id = action.keyID else { return }
            let other = ToolbarKeys.assign(key, to: id)
            let swapped = other.flatMap { id in ToolbarAction.keyed.first { $0.keyID == id } }
            self.hoverCard.configure(title: action.title, shortcut: action.shortcut, editable: true,
                                     note: swapped.map { "已和「\($0.title)」互换，它现在是 \($0.shortcut)" } ?? action.note)
            self.placeCard()
        }
    }

    /// The button the card is showing.
    private var cardAction: ToolbarAction?
    private weak var cardButton: ChromeButton?
    private var hideWork: DispatchWorkItem?
    private var showWork: DispatchWorkItem?
    /// How long the pointer must rest on a button before its card appears, so sweeping across the toolbar shows nothing.
    static let cardDelay: TimeInterval = 0.5

    /// Once a card is up, moving to the next button switches it at once, like system tooltips.
    private func scheduleShow(for action: ToolbarAction, at button: ChromeButton) {
        cancelShow()
        if !hoverCard.isHidden {
            showCard(for: action, at: button)
            return
        }
        let work = DispatchWorkItem { [weak self, weak button] in
            guard let self, let button else { return }
            self.showCard(for: action, at: button)
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cardDelay, execute: work)
    }

    private func cancelShow() {
        showWork?.cancel()
        showWork = nil
    }

    /// Leaves time to move the pointer from the button onto the card.
    private func scheduleHide() {
        cancelShow()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hoverCard.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func cancelHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    func setVertical(_ vertical: Bool) {
        isVertical = vertical
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .centerX : .centerY
        stack.edgeInsets = vertical ? NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 6) : NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        setFrameSize(stack.fittingSize)
        stack.frame = bounds
        // Lay out now: the style bar's caret uses the button positions before the toolbar is first drawn.
        stack.layoutSubtreeIfNeeded()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        hoverCard.removeFromSuperview()
        superview?.addSubview(hoverCard)
    }

    // The card belongs to the button under the pointer; any move or hide of the toolbar drops it.
    override var isHidden: Bool {
        didSet { if isHidden { cancelShow(); hoverCard.hide() } }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        if newOrigin != frame.origin { cancelShow(); hoverCard.hide() }
        super.setFrameOrigin(newOrigin)
    }

    /// Above the button for a row (below if there's no room); for a column, on whichever side has room.
    func showCard(for action: ToolbarAction, at button: ChromeButton) {
        guard superview != nil else { return }
        cancelShow()
        cancelHide()
        hoverCard.hide()
        cardAction = action
        cardButton = button
        hoverCard.configure(title: action.title, shortcut: action.shortcut, editable: action.keyID != nil, note: action.note)
        placeCard()
        hoverCard.isHidden = false
    }

    /// Positions the card for its button; again whenever its size changes.
    private func placeCard() {
        guard let container = superview, let button = cardButton else { return }
        let size = hoverCard.frame.size
        let b = button.convert(button.bounds, to: container)
        let bounds = container.bounds
        var origin: CGPoint
        if isVertical {
            origin = CGPoint(x: frame.maxX + 8, y: b.midY - size.height / 2)
            if origin.x + size.width > bounds.maxX - 4 { origin.x = frame.minX - 8 - size.width }
        } else {
            // The container is flipped: smaller y is higher on screen.
            origin = CGPoint(x: b.midX - size.width / 2, y: frame.minY - 8 - size.height)
            if origin.y < 4 { origin.y = frame.maxY + 8 }
        }
        origin.x = min(max(4, origin.x), bounds.maxX - size.width - 4)
        origin.y = min(max(4, origin.y), bounds.maxY - size.height - 4)
        hoverCard.setFrameOrigin(origin)
    }

    func setActiveTool(_ tool: Tool?) {
        for (t, button) in toolButtons { button.isActive = t == tool }
    }

    func setCanUndo(_ canUndo: Bool) {
        undoButton.isEnabled = canUndo
        undoButton.alphaValue = canUndo ? 1 : 0.35
    }

    /// Center of a tool button's icon, in toolbar coordinates.
    func anchor(for tool: Tool) -> CGPoint? {
        guard let button = toolButtons[tool] else { return nil }
        let frame = button.convert(button.bounds, to: self)
        return CGPoint(x: frame.midX, y: frame.midY)
    }
}

/// Dark card with a button's name, its shortcut in a key cap, and an optional note, like iShot's.
/// Clicking the key cap of a single-key button waits for a new key.
final class HoverCardView: PanelView {
    private let title = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "快捷键")
    private let keyCap = NSView()
    private let key = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private var editable = false
    private var shortcut = ""
    private var noteText: String?
    private(set) var isRecording = false
    var onHover: ((Bool) -> Void)?
    /// A new key (lowercase letter or digit) was pressed while recording.
    var onPick: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        fill = NSColor(white: 0.16, alpha: 0.96)
        radius = 8
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        shortcutLabel.font = .systemFont(ofSize: 12)
        shortcutLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        key.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        key.textColor = .black
        key.alignment = .center
        keyCap.wantsLayer = true
        keyCap.layer?.cornerRadius = 4
        keyCap.addSubview(key)
        note.font = .systemFont(ofSize: 11)
        note.textColor = NSColor.white.withAlphaComponent(0.55)
        for view in [title, shortcutLabel, keyCap, note] { addSubview(view) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { isRecording }

    /// A click elsewhere takes the keyboard back: stop waiting for a key.
    override func resignFirstResponder() -> Bool {
        if isRecording {
            isRecording = false
            layoutContent()
            onHover?(false)
        }
        return true
    }

    func configure(title text: String, shortcut: String, editable: Bool, note noteText: String?) {
        self.shortcut = shortcut
        self.editable = editable
        self.noteText = noteText
        title.stringValue = text
        layoutContent()
    }

    private func layoutContent() {
        key.stringValue = isRecording ? "按下新按键" : shortcut
        keyCap.layer?.backgroundColor = (isRecording ? selectionBlue : NSColor.white).cgColor
        key.textColor = isRecording ? .white : .black
        let hint = editable && !isRecording ? "点击按键可修改" : nil
        let lines = [isRecording ? "Esc 取消" : noteText, hint].compactMap { $0 }
        note.stringValue = lines.joined(separator: "\n")
        note.isHidden = lines.isEmpty
        let pad: CGFloat = 12
        let t = title.fittingSize, s = shortcutLabel.fittingSize, k = key.fittingSize, n = note.fittingSize
        title.frame = CGRect(x: pad, y: 9, width: t.width, height: t.height)
        let rowY = title.frame.maxY + 7
        let keySize = CGSize(width: max(24, k.width + 12), height: 20)
        shortcutLabel.frame = CGRect(x: pad, y: rowY + (keySize.height - s.height) / 2, width: s.width, height: s.height)
        keyCap.frame = CGRect(origin: CGPoint(x: shortcutLabel.frame.maxX + 8, y: rowY), size: keySize)
        key.frame = CGRect(x: 0, y: (keySize.height - k.height) / 2, width: keySize.width, height: k.height)
        var height = rowY + keySize.height + 10
        var width = max(t.width, keyCap.frame.maxX - pad)
        if !lines.isEmpty {
            note.frame = CGRect(x: pad, y: height - 3, width: n.width, height: n.height)
            height = note.frame.maxY + 9
            width = max(width, n.width)
        }
        setFrameSize(CGSize(width: ceil(width + pad * 2), height: ceil(height)))
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        (editable && keyCap.frame.contains(p) ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard editable, !isRecording, keyCap.frame.insetBy(dx: -4, dy: -4).contains(p) else { return }
        startRecording()
    }

    func startRecording() {
        isRecording = true
        layoutContent()
        window?.makeFirstResponder(self)
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        layoutContent()
        // Hand the keyboard back to the capture view.
        if window?.firstResponder === self { window?.makeFirstResponder(superview) }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        if event.keyCode == 53 {
            stopRecording()
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard flags.isEmpty, ToolbarKeys.isAllowed(typed) else {
            NSSound.beep()
            return
        }
        isRecording = false
        onPick?(typed)
        if window?.firstResponder === self { window?.makeFirstResponder(superview) }
    }

    func hide() {
        stopRecording()
        isHidden = true
    }
}

struct StyleState {
    static let palette: [NSColor] = [
        NSColor(srgbRed: 0.96, green: 0.23, blue: 0.19, alpha: 1), // red
        NSColor(srgbRed: 1.00, green: 0.55, blue: 0.10, alpha: 1), // orange
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.10, alpha: 1), // yellow
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1), // green
        NSColor(srgbRed: 0.12, green: 0.56, blue: 0.95, alpha: 1), // blue
        NSColor(srgbRed: 0.62, green: 0.32, blue: 0.95, alpha: 1), // purple
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
    ]

    var tool: Tool
    var color: NSColor
    var size: CGFloat
    var mosaicMode: MosaicMode
    var mosaicEffect: MosaicEffect
    var options = ItemStyle()
}

enum StyleAction {
    case size(CGFloat), color(NSColor), customColor, mosaicMode(MosaicMode), mosaicEffect(MosaicEffect)
    /// Changes dash, arrowhead, rounded corners or text decoration.
    case options((inout ItemStyle) -> Void)
}

/// Small template icons for the style options, drawn so each one shows exactly what it does.
enum OptionIcon {
    static func dash(_ dash: DashStyle) -> NSImage {
        icon { rect in
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 1, y: rect.midY))
            path.line(to: CGPoint(x: rect.maxX - 1, y: rect.midY))
            path.lineWidth = 2
            switch dash {
            case .solid: break
            case .dashed: path.setLineDash([4, 2.5], count: 2, phase: 0)
            case .dotted:
                path.lineCapStyle = .round
                path.setLineDash([0.01, 3.5], count: 2, phase: 0)
            }
            path.stroke()
        }
    }

    static func rounded(_ on: Bool) -> NSImage {
        icon { rect in
            let r = rect.insetBy(dx: 2, dy: 3)
            let path = on ? NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4) : NSBezierPath(rect: r)
            path.lineWidth = 1.6
            path.stroke()
        }
    }

    static func arrow(_ head: ArrowHead) -> NSImage {
        icon { rect in
            let a = CGPoint(x: 2, y: 3), b = CGPoint(x: rect.maxX - 2, y: rect.maxY - 3)
            let shaft = NSBezierPath()
            shaft.move(to: a)
            shaft.line(to: b)
            shaft.lineWidth = 1.6
            shaft.stroke()
            func drawHead(at tip: CGPoint, from tail: CGPoint, filled: Bool) {
                let angle = atan2(tip.y - tail.y, tip.x - tail.x)
                let p = NSBezierPath()
                p.move(to: CGPoint(x: tip.x - 6 * cos(angle - 0.5), y: tip.y - 6 * sin(angle - 0.5)))
                p.line(to: tip)
                p.line(to: CGPoint(x: tip.x - 6 * cos(angle + 0.5), y: tip.y - 6 * sin(angle + 0.5)))
                p.lineWidth = 1.6
                if filled {
                    p.close()
                    p.fill()
                } else {
                    p.stroke()
                }
            }
            drawHead(at: b, from: a, filled: head != .open)
            if head == .double { drawHead(at: a, from: b, filled: true) }
        }
    }

    static func text(_ decoration: TextDecoration) -> NSImage {
        icon { rect in
            let font = NSFont.systemFont(ofSize: 12, weight: .heavy)
            if decoration == .background {
                NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 1), xRadius: 3, yRadius: 3).fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            if decoration == .outline {
                attributes[.strokeWidth] = 4
                attributes[.strokeColor] = NSColor.black
            }
            let a = NSAttributedString(string: "A", attributes: attributes)
            let size = a.size()
            a.draw(at: CGPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
        }
    }

    private static func icon(_ draw: @escaping (CGRect) -> Void) -> NSImage {
        let image = NSImage(size: CGSize(width: 16, height: 14), flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            draw(rect)
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Size, color and mosaic options for the active tool or the selected annotation.
final class StyleBarView: PanelView {
    private let stack = NSStackView()
    private var sizeButtons: [(CGFloat, ChromeButton)] = []
    private var colorButtons: [(NSColor, ChromeButton)] = []
    private let sizeLabel = NSTextField(labelWithString: "")
    private var modeButtons: [MosaicMode: ChromeButton] = [:]
    private var effectButtons: [MosaicEffect: ChromeButton] = [:]
    private var customButton: ChromeButton?
    private var dashButtons: [DashStyle: ChromeButton] = [:]
    private var headButtons: [ArrowHead: ChromeButton] = [:]
    private var textButtons: [TextDecoration: ChromeButton] = [:]
    private var roundedButton: ChromeButton?
    private let handler: (StyleAction) -> Void
    private(set) var configuredTool: Tool?
    private var configuredMode: MosaicMode?

    init(handler: @escaping (StyleAction) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        addSubview(stack)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.alignment = .center
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        sizeLabel.widthAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Rebuilds the controls when the tool (or mosaic mode) changes, otherwise just refreshes state.
    func configure(_ state: StyleState) {
        guard configuredTool != state.tool || (state.tool == .mosaic && configuredMode != state.mosaicMode) else {
            update(state)
            return
        }
        configuredTool = state.tool
        configuredMode = state.mosaicMode
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        sizeButtons = []
        colorButtons = []
        modeButtons = [:]
        effectButtons = [:]
        customButton = nil
        dashButtons = [:]
        headButtons = [:]
        textButtons = [:]
        roundedButton = nil

        if state.tool == .mosaic {
            for (mode, symbol, tip) in [(MosaicMode.brush, "paintbrush.pointed", "画笔涂抹"), (.rect, "rectangle.dashed", "框选区域")] {
                let b = ChromeButton(image: symbolImage(symbol, size: 13), tooltip: tip, size: 28) { [unowned self] in self.handler(.mosaicMode(mode)) }
                modeButtons[mode] = b
                stack.addArrangedSubview(b)
            }
            stack.addArrangedSubview(separator(height: 16))
            for (effect, symbol, tip) in [(MosaicEffect.pixelate, "square.grid.3x3.fill", "格子"), (.blur, "drop.fill", "毛玻璃")] {
                let b = ChromeButton(image: symbolImage(symbol, size: 13), tooltip: tip, size: 28) { [unowned self] in self.handler(.mosaicEffect(effect)) }
                effectButtons[effect] = b
                stack.addArrangedSubview(b)
            }
            if state.mosaicMode == .brush {
                stack.addArrangedSubview(separator(height: 16))
                addSizeButtons(state.tool)
            }
        } else {
            addSizeButtons(state.tool)
            addOptionButtons(state.tool)
            stack.addArrangedSubview(separator(height: 16))
            for color in StyleState.palette {
                let b = ChromeButton(image: swatch(color), tooltip: "颜色", size: 24) { [unowned self] in self.handler(.color(color)) }
                colorButtons.append((color, b))
                stack.addArrangedSubview(b)
            }
            let custom = ChromeButton(image: rainbowSwatch(), tooltip: "自定义颜色", size: 24) { [unowned self] in self.handler(.customColor) }
            customButton = custom
            stack.addArrangedSubview(custom)
        }
        update(state)

        stack.layoutSubtreeIfNeeded()
        let content = stack.fittingSize
        let caretSize = caret == nil ? 0 : PanelView.caretHeight
        let sideways = caret.map { !$0.edge.isVertical } ?? false
        setFrameSize(CGSize(width: content.width + 16 + (sideways ? caretSize : 0), height: content.height + 8 + (sideways ? 0 : caretSize)))
        layoutStack()
    }

    /// Line style, arrowheads, rounded corners or text decoration, depending on the tool.
    private func addOptionButtons(_ tool: Tool) {
        func add(_ image: NSImage, _ tip: String, _ change: @escaping (inout ItemStyle) -> Void) -> ChromeButton {
            let b = ChromeButton(image: image, tooltip: tip, size: 26) { [unowned self] in self.handler(.options(change)) }
            stack.addArrangedSubview(b)
            return b
        }
        if tool == .arrow {
            stack.addArrangedSubview(separator(height: 16))
            for (head, tip) in [(ArrowHead.tapered, "实心箭头"), (.open, "线条箭头"), (.double, "双向箭头")] {
                headButtons[head] = add(OptionIcon.arrow(head), tip) { $0.arrowHead = head }
            }
        }
        if [.rectangle, .arrow, .pen].contains(tool) {
            stack.addArrangedSubview(separator(height: 16))
            for (dash, tip) in [(DashStyle.solid, "实线"), (.dashed, "虚线"), (.dotted, "点线")] {
                dashButtons[dash] = add(OptionIcon.dash(dash), tip) { $0.dash = dash }
            }
        }
        if tool == .rectangle {
            roundedButton = add(OptionIcon.rounded(true), "圆角矩形") { $0.rounded.toggle() }
        }
        if tool == .text {
            stack.addArrangedSubview(separator(height: 16))
            for (decoration, tip) in [(TextDecoration.plain, "普通文字"), (.background, "文字加底色"), (.outline, "文字描边")] {
                textButtons[decoration] = add(OptionIcon.text(decoration), tip) { $0.text = decoration }
            }
        }
    }

    private func addSizeButtons(_ tool: Tool) {
        for (i, value) in tool.sizePresets.enumerated() {
            let dot = CGFloat([4, 7, 11][i])
            let image = NSImage(size: CGSize(width: 14, height: 14), flipped: false) { _ in
                NSColor.black.setFill()
                NSBezierPath(ovalIn: CGRect(x: (14 - dot) / 2, y: (14 - dot) / 2, width: dot, height: dot)).fill()
                return true
            }
            image.isTemplate = true
            let b = ChromeButton(image: image, tooltip: ["小", "中", "大"][i] + "（滚轮可微调）", size: 26) { [unowned self] in self.handler(.size(value)) }
            sizeButtons.append((value, b))
            stack.addArrangedSubview(b)
        }
        stack.addArrangedSubview(sizeLabel)
    }

    func update(_ state: StyleState) {
        sizeLabel.stringValue = "\(Int(state.size.rounded()))"
        for (value, b) in sizeButtons { b.isActive = abs(value - state.size) < 0.5 }
        var matched = false
        for (color, b) in colorButtons {
            b.isActive = color.isApproximately(state.color)
            matched = matched || b.isActive
        }
        customButton?.isActive = !matched
        for (dash, b) in dashButtons { b.isActive = dash == state.options.dash }
        for (head, b) in headButtons { b.isActive = head == state.options.arrowHead }
        for (decoration, b) in textButtons { b.isActive = decoration == state.options.text }
        roundedButton?.isActive = state.options.rounded
        for (mode, b) in modeButtons { b.isActive = mode == state.mosaicMode }
        for (effect, b) in effectButtons { b.isActive = effect == state.mosaicEffect }
    }

    override func caretDidChange() {
        layoutStack()
    }

    private func layoutStack() {
        let r = contentRect.insetBy(dx: 8, dy: 4)
        // Not sized yet (the caret can be set before the first configure).
        guard r.width > 0, r.height > 0 else { return }
        stack.frame = r
    }

    private func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: CGSize(width: 16, height: 16), flipped: false) { rect in
            color.setFill()
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            path.fill()
            NSColor.gray.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }

    private func rainbowSwatch() -> NSImage {
        NSImage(size: CGSize(width: 16, height: 16), flipped: false) { rect in
            let gradient = NSGradient(colors: [.systemRed, .systemYellow, .systemGreen, .systemBlue, .systemPurple])
            gradient?.draw(in: NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)), angle: 45)
            return true
        }
    }
}

extension NSColor {
    func isApproximately(_ other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
    }
}

/// Blue bar above the selection showing its size in points.
final class TopBarView: PanelView {
    private let sizeLabel = NSTextField(labelWithString: "")

    override init(frame: CGRect) {
        super.init(frame: frame)
        fill = selectionBlue
        radius = 6
        layer?.shadowOpacity = 0
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        sizeLabel.textColor = .white
        addSubview(sizeLabel)
        setSize(.zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    func setSize(_ size: CGSize) {
        sizeLabel.stringValue = "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
        let text = sizeLabel.fittingSize
        setFrameSize(CGSize(width: ceil(text.width) + 18, height: 24))
        sizeLabel.frame = CGRect(x: 9, y: (24 - text.height) / 2, width: ceil(text.width), height: text.height)
    }
}

/// Short status message.
final class ToastView: PanelView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private var hideWork: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        fill = NSColor(white: 0.1, alpha: 0.85)
        radius = 7
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.maximumNumberOfLines = 4
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    /// `duration` nil keeps the message until the next one.
    func show(_ text: String, duration: TimeInterval? = 2.5, maxWidth: CGFloat) {
        hideWork?.cancel()
        label.stringValue = text
        label.preferredMaxLayoutWidth = min(380, max(120, maxWidth - 24))
        let size = label.fittingSize
        label.frame = CGRect(x: 12, y: 7, width: size.width, height: size.height)
        setFrameSize(CGSize(width: size.width + 24, height: size.height + 14))
        isHidden = false
        alphaValue = 1
        if let duration {
            let work = DispatchWorkItem { [weak self] in
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.2
                    self?.animator().alphaValue = 0
                }, completionHandler: { self?.isHidden = true })
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        isHidden = true
    }
}

/// Editable OCR result next to the selection.
final class OCRPanelView: PanelView {
    let textView: NSTextView
    private let scroll = NSScrollView()
    private let title = NSTextField(labelWithString: "识别结果")
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)
    private var closeButton: ChromeButton!
    private var resetWork: DispatchWorkItem?

    init(onClose: @escaping () -> Void) {
        textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        super.init(frame: CGRect(x: 0, y: 0, width: 340, height: 262))
        radius = 12

        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = CGRect(x: 14, y: 11, width: 260, height: 18)
        addSubview(title)

        closeButton = ChromeButton(image: symbolImage("xmark", size: 10, weight: .bold), tooltip: "关闭", size: 22, handler: onClose)
        closeButton.translatesAutoresizingMaskIntoConstraints = true
        closeButton.frame = CGRect(x: 340 - 32, y: 9, width: 22, height: 22)
        addSubview(closeButton)

        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = CGSize(width: 4, height: 6)
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 7
        scroll.frame = CGRect(x: 12, y: 38, width: 316, height: 178)
        addSubview(scroll)

        copyButton.bezelStyle = .push
        copyButton.frame = CGRect(x: 340 - 12 - 90, y: 224, width: 90, height: 28)
        copyButton.target = self
        copyButton.action = #selector(copyText)
        addSubview(copyButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(text: String, lineCount: Int) {
        textView.string = text
        title.stringValue = "识别结果 · \(lineCount) 行"
        resetWork?.cancel()
        copyButton.title = "复制"
    }

    @objc func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
        flashCopied()
    }

    private func flashCopied() {
        copyButton.title = "已复制 ✓"
        resetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.copyButton.title = "复制" }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
