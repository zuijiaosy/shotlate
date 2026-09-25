import AppKit

/// Selection blue, matching iShot's selection frame and top bar.
let selectionBlue = NSColor(srgbRed: 0.16, green: 0.58, blue: 0.93, alpha: 1)

/// Rounded panel drawn to match the system appearance, with an optional caret pointing
/// at the control it belongs to. The caret sits outside `contentRect`.
class PanelView: NSView {
    enum CaretEdge { case top, bottom }

    static let caretHeight: CGFloat = 6
    var fill: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
    var radius: CGFloat = 9
    var caret: (edge: CaretEdge, x: CGFloat)? {
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
            r.size.height -= Self.caretHeight
            if caret.edge == .top { r.origin.y += Self.caretHeight }
        }
        return r
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = contentRect.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        if let caret {
            let x = min(max(caret.x, body.minX + radius + 6), body.maxX - radius - 6)
            let tri = NSBezierPath()
            if caret.edge == .top {
                tri.move(to: CGPoint(x: x - 7, y: body.minY + 1))
                tri.line(to: CGPoint(x: x, y: body.minY - Self.caretHeight + 0.5))
                tri.line(to: CGPoint(x: x + 7, y: body.minY + 1))
            } else {
                tri.move(to: CGPoint(x: x - 7, y: body.maxY - 1))
                tri.line(to: CGPoint(x: x, y: body.maxY + Self.caretHeight - 0.5))
                tri.line(to: CGPoint(x: x + 7, y: body.maxY - 1))
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

    var isActive = false {
        didSet { needsDisplay = true }
    }

    init(image: NSImage, tooltip: String, size: CGFloat = 30, handler: @escaping () -> Void) {
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
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
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

func symbolImage(_ name: String, size: CGFloat = 15, weight: NSFont.Weight = .regular) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
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

private func separator(height: CGFloat = 18) -> NSView {
    let line = NSBox()
    line.boxType = .separator
    line.translatesAutoresizingMaskIntoConstraints = false
    line.widthAnchor.constraint(equalToConstant: 1).isActive = true
    line.heightAnchor.constraint(equalToConstant: height).isActive = true
    return line
}

enum ToolbarAction {
    case tool(Tool), undo, redo, ocr, translate, pin, longCapture, cancel, save, done
}

/// Bottom toolbar: annotation tools | undo, redo | OCR, translate | cancel, save, done.
final class ToolbarView: PanelView {
    private(set) var toolButtons: [Tool: ChromeButton] = [:]
    private(set) var translateButton: ChromeButton!
    private(set) var undoButton: ChromeButton!
    private(set) var redoButton: ChromeButton!
    private let stack = NSStackView()

    init(handler: @escaping (ToolbarAction) -> Void) {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        addSubview(stack)

        for tool in Tool.allCases {
            let button = ChromeButton(image: symbolImage(tool.symbol), tooltip: "\(tool.title)  \(tool.key.uppercased())") {
                handler(.tool(tool))
            }
            toolButtons[tool] = button
            stack.addArrangedSubview(button)
        }
        addSeparator()
        undoButton = ChromeButton(image: symbolImage("arrow.uturn.backward"), tooltip: "撤销  ⌘Z") { handler(.undo) }
        redoButton = ChromeButton(image: symbolImage("arrow.uturn.forward"), tooltip: "重做  ⇧⌘Z") { handler(.redo) }
        stack.addArrangedSubview(undoButton)
        stack.addArrangedSubview(redoButton)
        addSeparator()
        stack.addArrangedSubview(ChromeButton(image: badgeImage("OCR"), tooltip: "识别文字  X") { handler(.ocr) })
        translateButton = ChromeButton(image: symbolImage("translate"), tooltip: "翻译到原位  Y\n再按一次切换原文，按住 ⌥ 临时查看原文") { handler(.translate) }
        stack.addArrangedSubview(translateButton)
        addSeparator()
        stack.addArrangedSubview(ChromeButton(image: symbolImage("pin"), tooltip: "贴到屏幕上  ⌘T") { handler(.pin) })
        stack.addArrangedSubview(ChromeButton(image: symbolImage("arrow.up.and.down.text.horizontal"), tooltip: "长截图  S\n在选区里滚动，自动拼接成长图") { handler(.longCapture) })
        addSeparator()
        stack.addArrangedSubview(ChromeButton(image: symbolImage("xmark"), tooltip: "退出截图  Esc") { handler(.cancel) })
        stack.addArrangedSubview(ChromeButton(image: symbolImage("square.and.arrow.down"), tooltip: "保存  ⌘S\n另存为  ⇧⌘S") { handler(.save) })
        let done = ChromeButton(image: symbolImage("checkmark", weight: .semibold), tooltip: "复制到剪贴板  Return / 双击选区") { handler(.done) }
        done.tint = selectionBlue
        stack.addArrangedSubview(done)
        setFrameSize(stack.fittingSize)
        stack.frame = bounds
    }

    required init?(coder: NSCoder) { fatalError() }

    private func addSeparator() {
        stack.setCustomSpacing(6, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 1])
        let line = separator()
        stack.addArrangedSubview(line)
        stack.setCustomSpacing(6, after: line)
    }

    func setActiveTool(_ tool: Tool?) {
        for (t, button) in toolButtons { button.isActive = t == tool }
    }

    func setHistory(canUndo: Bool, canRedo: Bool) {
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
        undoButton.alphaValue = canUndo ? 1 : 0.35
        redoButton.alphaValue = canRedo ? 1 : 0.35
    }

    /// Center of a tool button, in toolbar coordinates.
    func anchorX(for tool: Tool) -> CGFloat? {
        guard let button = toolButtons[tool] else { return nil }
        return button.frame.midX
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
}

enum StyleAction {
    case size(CGFloat), color(NSColor), customColor, mosaicMode(MosaicMode), mosaicEffect(MosaicEffect)
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
        guard configuredTool != state.tool || (state.tool.usesAreaModes && configuredMode != state.mosaicMode) else {
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

        if state.tool.usesAreaModes {
            for (mode, symbol, tip) in [(MosaicMode.brush, "paintbrush.pointed", "画笔涂抹"), (.rect, "rectangle.dashed", "框选区域")] {
                let b = ChromeButton(image: symbolImage(symbol, size: 13), tooltip: tip, size: 28) { [unowned self] in self.handler(.mosaicMode(mode)) }
                modeButtons[mode] = b
                stack.addArrangedSubview(b)
            }
            if state.tool == .mosaic {
                stack.addArrangedSubview(separator(height: 16))
                for (effect, symbol, tip) in [(MosaicEffect.pixelate, "square.grid.3x3.fill", "格子"), (.blur, "drop.fill", "毛玻璃")] {
                    let b = ChromeButton(image: symbolImage(symbol, size: 13), tooltip: tip, size: 28) { [unowned self] in self.handler(.mosaicEffect(effect)) }
                    effectButtons[effect] = b
                    stack.addArrangedSubview(b)
                }
            }
            if state.mosaicMode == .brush {
                stack.addArrangedSubview(separator(height: 16))
                addSizeButtons(state.tool)
            }
        } else {
            addSizeButtons(state.tool)
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
        setFrameSize(CGSize(width: content.width + 16, height: content.height + 8 + (caret == nil ? 0 : PanelView.caretHeight)))
        layoutStack()
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

/// Blue bar above the selection: size in points, corner radius slider, shadow toggle.
final class TopBarView: PanelView {
    private let sizeLabel = NSTextField(labelWithString: "")
    private let radiusIcon = NSImageView(image: symbolImage("square.dashed", size: 11))
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 30, target: nil, action: nil)
    private let shadowBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let stack = NSStackView()
    private let onRadius: (Double) -> Void
    private let onShadow: (Bool) -> Void

    init(radius: Double, shadow: Bool, onRadius: @escaping (Double) -> Void, onShadow: @escaping (Bool) -> Void) {
        self.onRadius = onRadius
        self.onShadow = onShadow
        super.init(frame: .zero)
        fill = selectionBlue
        self.radius = 6
        layer?.shadowOpacity = 0
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        sizeLabel.textColor = .white
        radiusIcon.contentTintColor = .white
        radiusIcon.toolTip = "圆角"
        slider.controlSize = .mini
        slider.doubleValue = radius
        slider.toolTip = "圆角"
        slider.target = self
        slider.action = #selector(radiusChanged)
        shadowBox.attributedTitle = NSAttributedString(string: "阴影", attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ])
        shadowBox.state = shadow ? .on : .off
        shadowBox.target = self
        shadowBox.action = #selector(shadowChanged)
        shadowBox.controlSize = .small
        shadowBox.toolTip = "导出时加投影（仅 PNG）"

        [sizeLabel, radiusIcon, slider, shadowBox].forEach { stack.addArrangedSubview($0) }
        stack.spacing = 6
        stack.setCustomSpacing(12, after: sizeLabel)
        stack.setCustomSpacing(12, after: slider)
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 9, bottom: 3, right: 9)
        slider.widthAnchor.constraint(equalToConstant: 72).isActive = true
        addSubview(stack)
        setSize(.zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    func setSize(_ size: CGSize) {
        sizeLabel.stringValue = "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
        fit()
    }

    func setControlsVisible(_ visible: Bool) {
        guard slider.isHidden == visible else { return }
        radiusIcon.isHidden = !visible
        slider.isHidden = !visible
        shadowBox.isHidden = !visible
        fit()
    }

    private func fit() {
        let size = stack.fittingSize
        setFrameSize(CGSize(width: size.width, height: 24))
        stack.frame = bounds
    }

    @objc private func radiusChanged() { onRadius(slider.doubleValue) }
    @objc private func shadowChanged() { onShadow(shadowBox.state == .on) }
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
        title.stringValue = "识别结果 · \(lineCount) 行 · 已复制"
        flashCopied()
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
