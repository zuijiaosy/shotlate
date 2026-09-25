import AppKit
import CoreImage
import SnapCore

/// Style choices remembered across captures. Color and size are kept per tool, and saved across launches.
enum StyleMemory {
    private static let defaults = UserDefaults.standard

    /// Red for most tools; the highlighter starts yellow.
    static func defaultColor(for tool: Tool) -> NSColor {
        tool == .highlighter ? StyleState.palette[2] : StyleState.palette[0]
    }

    static func color(for tool: Tool) -> NSColor {
        guard let rgba = (defaults.dictionary(forKey: "style.colors") as? [String: [Double]])?[tool.rawValue], rgba.count == 4 else {
            return defaultColor(for: tool)
        }
        return NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
    }

    static func setColor(_ color: NSColor, for tool: Tool) {
        let c = color.usingColorSpace(.sRGB) ?? color
        var all = defaults.dictionary(forKey: "style.colors") as? [String: [Double]] ?? [:]
        all[tool.rawValue] = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map(Double.init)
        defaults.set(all, forKey: "style.colors")
    }

    static func style(for tool: Tool) -> ItemStyle {
        guard let data = defaults.data(forKey: "style.options"),
              let all = try? JSONDecoder().decode([String: ItemStyle].self, from: data) else { return ItemStyle() }
        return all[tool.rawValue] ?? ItemStyle()
    }

    static func setStyle(_ style: ItemStyle, for tool: Tool) {
        var all = (defaults.data(forKey: "style.options")).flatMap { try? JSONDecoder().decode([String: ItemStyle].self, from: $0) } ?? [:]
        all[tool.rawValue] = style
        defaults.set(try? JSONEncoder().encode(all), forKey: "style.options")
    }

    static var sizes: [Tool: CGFloat] {
        get {
            let raw = defaults.dictionary(forKey: "style.sizes") as? [String: Double] ?? [:]
            return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in Tool(rawValue: key).map { ($0, CGFloat(value)) } })
        }
        set { defaults.set(Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, Double($0.value)) }), forKey: "style.sizes") }
    }
    static var mosaicMode: MosaicMode = .brush
    static var eraserMode: MosaicMode = .brush
    static var mosaicEffect: MosaicEffect = .pixelate
    static var hexColor = true
    static var lastSelection: [CGDirectDisplayID: CGRect] = [:]
    /// Locked selection shape, remembered across launches like Snipaste does.
    static var aspectRatio: AspectRatio? {
        get { AspectRatio(UserDefaults.standard.string(forKey: "capture.aspectRatio") ?? "") }
        set { UserDefaults.standard.set(newValue?.label, forKey: "capture.aspectRatio") }
    }

    static func size(for tool: Tool) -> CGFloat { sizes[tool] ?? tool.defaultSize }
    static func areaMode(for tool: Tool) -> MosaicMode { tool == .eraser ? eraserMode : mosaicMode }
    static func areaEffect(for tool: Tool) -> MosaicEffect { tool == .eraser ? .original : mosaicEffect }
}

private enum Drag {
    case none
    case selecting(CGPoint)
    case moving(CGPoint, CGRect)
    case resizing(ResizeHandle, CGRect, CGPoint)
    case drawing(CGPoint)
    case movingItem(CGPoint, AnnotationItem)
    case resizingItem(ItemHandle, AnnotationItem, CGPoint)
}

private enum TranslationState {
    case none
    case loading
    case shown([TranslatedBlock], CGRect)
    case hidden([TranslatedBlock], CGRect)
}

enum OutputAction {
    case copy, save, saveAs
    /// Finish editing a pin: bake the annotations into it (in a normal capture this is the same as copy).
    case apply
}

/// A normal screenshot, a whiteboard (drawing on a solid canvas), or a transparent board over the live screen.
enum CaptureMode: Equatable {
    case screenshot
    case whiteboard
    case transparentBoard
    /// Annotating a pin: the pin's image is the canvas, everything else stays live and untouched.
    case pinEdit

    var isBoard: Bool { self != .screenshot }
}

/// Transparent overlay for one display: dimming, selection, annotations, magnifier and toolbar.
/// The frozen screenshot itself is a layer underneath (see `CaptureRootView`), so this view never redraws it.
final class CaptureView: NSView {
    weak var session: CaptureSession?
    let displayID: CGDirectDisplayID

    private let snapshot: CGImage
    private let baseImage: NSImage
    private let windowRects: [CGRect]
    private var effectImages: [MosaicEffect: NSImage] = [:]
    private var renderer: ContentRenderer {
        ContentRenderer(base: baseImage, bounds: bounds, effect: { [unowned self] in self.effectImage($0) },
                        cursor: showsCursor ? capturedCursor : nil)
    }

    /// Pixels per point of the frozen image.
    private var scale: CGFloat { CGFloat(snapshot.width) / bounds.width }

    // Selection
    private(set) var hasSelection = false
    private var selection = CGRect.zero
    private var hoverRect: CGRect?
    private var drag = Drag.none
    private var mouseDownPoint = CGPoint.zero
    private var didDrag = false
    private var shiftDown = false

    // Annotations
    private var items: [AnnotationItem] = []
    private var selectedID: UUID?
    private var hoveredID: UUID?
    private var draft: AnnotationItem?
    private var undoStack: [[AnnotationItem]] = []
    private var redoStack: [[AnnotationItem]] = []
    private var changeStart: [AnnotationItem]?
    private var coalesceWork: DispatchWorkItem?
    private var scrollAccumulator: CGFloat = 0
    private var tool: Tool?
    /// Corners placed so far while clicking out a polyline with the line or arrow tool.
    private var polyPoints: [CGPoint]?
    private var textEditor: TextEditorView?
    private var editingID: UUID?
    private var editingColor = StyleMemory.color(for: .text)
    private var editingSize = StyleMemory.size(for: .text)
    private var editingStyle = StyleMemory.style(for: .text)

    private var cornerRadius = CGFloat(Settings.shared.cornerRadius)
    private var shadowEnabled = Settings.shared.shadowEnabled

    // OCR and translation
    private var recognition: (rect: CGRect, result: RecognitionResult)?
    private var translationState = TranslationState.none
    private var recognitionTask: Task<Void, Never>?
    private var pendingBlockRects: [CGRect] = []
    private var shimmerTimer: Timer?
    private var shimmerStart = Date()
    private var peekingOriginal = false
    private var ocrBoxesVisible = false

    // Chrome
    private lazy var toolbar = ToolbarView { [unowned self] in self.handle($0) }
    private lazy var styleBar = StyleBarView { [unowned self] in self.applyStyle($0) }
    private lazy var topBar = TopBarView(
        radius: Double(cornerRadius), shadow: shadowEnabled, ratio: StyleMemory.aspectRatio,
        onRadius: { [unowned self] in
            self.cornerRadius = CGFloat($0)
            Settings.shared.cornerRadius = $0
            self.needsDisplay = true
        },
        onShadow: { [unowned self] in
            self.shadowEnabled = $0
            Settings.shared.shadowEnabled = $0
        })
    private let toast = ToastView()
    private lazy var ocrPanel: OCRPanelView = OCRPanelView { [unowned self] in self.closeOCRPanel() }
    private lazy var magnifier = MagnifierView(snapshot: snapshot, viewSize: bounds.size)

    /// The pointer captured with this screen, and whether it is currently part of the picture (toggled with `).
    private let capturedCursor: CapturedCursor?
    private var showsCursor = Settings.shared.captureCursor

    let mode: CaptureMode
    /// In a board, Esc has to be pressed twice in a row to leave, so a stray Esc doesn't wipe the drawing.
    private var escapeArmed = false

    init(frame: CGRect, snapshot: CGImage, windowRects: [CGRect], displayID: CGDirectDisplayID, cursor: CapturedCursor? = nil,
         mode: CaptureMode = .screenshot) {
        self.mode = mode
        self.capturedCursor = cursor
        self.snapshot = snapshot
        self.baseImage = NSImage(cgImage: snapshot, size: frame.size)
        self.windowRects = windowRects
        self.displayID = displayID
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for view in [topBar, toolbar, styleBar, ocrPanel, magnifier, toast] as [NSView] {
            view.isHidden = true
            addSubview(view)
        }
        magnifier.showHex = StyleMemory.hexColor
        topBar.onSize = { [unowned self] in self.applyTypedSize($0) }
        topBar.onRatio = { [unowned self] in self.applyRatio($0) }
        topBar.onEndEditing = { [unowned self] in self.window?.makeFirstResponder(self) }
        updateHistoryButtons()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var snapshotImage: CGImage { snapshot }
    var testing_selection: CGRect? { hasSelection ? selection : nil }
    /// The history entry this view was restored from, so re-outputting it unchanged doesn't store a duplicate.
    private var replayedEntry: HistoryEntry?

    func historyEntry() -> HistoryEntry? {
        guard hasSelection, selection.width >= 1, selection.height >= 1 else { return nil }
        commitText()
        if let replayedEntry, replayedEntry.selection == selection, replayedEntry.items == items { return nil }
        return HistoryEntry(displayID: displayID, screenSize: bounds.size, selection: selection, items: items)
    }

    /// Shows a past capture: its selection and editable annotations.
    /// `asReplay` false is for a refreshed screenshot, which should be recorded again when output.
    func restore(_ entry: HistoryEntry, asReplay: Bool = true) {
        replayedEntry = asReplay ? entry : nil
        selection = entry.selection.intersection(bounds)
        items = entry.items
        undoStack = []
        redoStack = []
        commitSelection()
        updateHistoryButtons()
    }

    private func toggleCursor() {
        guard let capturedCursor else {
            showToast("这块屏幕上没有鼠标指针")
            return
        }
        showsCursor.toggle()
        invalidate(capturedCursor.rect, margin: 2)
        showToast(showsCursor ? "截图包含鼠标指针 · ` 切换" : "截图不含鼠标指针 · ` 切换", duration: 1.2)
    }

    var testing_showsCursor: Bool { showsCursor }

    /// Selection and annotations as they are now, to carry over to a refreshed screenshot.
    func currentState() -> HistoryEntry? {
        guard hasSelection else { return nil }
        commitText()
        return HistoryEntry(displayID: displayID, screenSize: bounds.size, selection: selection, items: items)
    }

    func showMessage(_ text: String, duration: TimeInterval = 2.5) {
        showToast(text, duration: duration)
    }

    func tearDown() {
        recognitionTask?.cancel()
        stopShimmer()
        coalesceWork?.cancel()
    }

    // MARK: - Drawing

    private var isSelecting: Bool {
        if case .selecting = drag, didDrag { return true }
        return false
    }

    private var isAdjustingSelection: Bool {
        switch drag {
        case .moving, .resizing: return true
        default: return false
        }
    }

    private var focusRect: CGRect? {
        if hasSelection || isSelecting { return selection.width > 0 ? selection : nil }
        return hoverRect
    }

    private var visibleTranslation: [TranslatedBlock] {
        if case let .shown(blocks, _) = translationState { return blocks }
        return []
    }

    /// Pin editing: the pin's rect is the canvas.
    func startPinEdit(rect: CGRect) {
        selection = rect.intersection(bounds)
        commitSelection()
        showToast("在贴图上标注 · ✓ 或回车完成 · Esc 放弃", duration: 2.5)
    }

    /// Boards start with the whole screen selected and the pen in hand.
    func startBoard() {
        guard mode == .whiteboard || mode == .transparentBoard else { return }
        selection = bounds
        commitSelection()
        setTool(.pen)
        showToast(mode == .whiteboard ? "白板：直接画 · 空格显示/隐藏工具栏 · 连按两次 Esc 退出"
                                      : "透明白板：在屏幕上直接画 · 空格显示/隐藏工具栏 · 连按两次 Esc 退出", duration: 3)
    }

    private var toolbarHiddenByUser = false

    // UI element detection: the chain of elements under the pointer (innermost first) and how far out the wheel has gone.
    private var hierarchy: ElementHierarchy?
    private var detectElements = Settings.shared.detectElements
    private var elementChain: [CGRect] = []
    private var elementLevel = 0

    func setElements(_ nodes: [UIElementNode]) {
        hierarchy = ElementHierarchy(nodes: nodes)
        primeCursor()
    }

    var testing_hoverRect: CGRect? { hoverRect }

    /// What to highlight at `p` before anything is selected: an element (and the wheel's chosen ancestor) or the window.
    private func hoverTarget(at p: CGPoint) -> CGRect? {
        let window = windowRects.first { $0.contains(p) }
        guard detectElements, let hierarchy else { return window }
        let chain = hierarchy.chain(at: p, within: window)
        if chain.first != elementChain.first { elementLevel = 0 }
        elementChain = chain
        guard !chain.isEmpty else { return window }
        return chain[min(elementLevel, chain.count - 1)]
    }

    override func draw(_ dirtyRect: NSRect) {
        if mode.isBoard {
            // No dimming, border or handles: the whole screen is the canvas.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: selection).addClip()
            renderer.drawOverlays(items: items, draft: draft, hiddenID: editingID, translation: peekingOriginal ? [] : visibleTranslation)
            if case .loading = translationState { drawShimmer() }
            NSGraphicsContext.restoreGraphicsState()
            if mode == .pinEdit {
                selectionBlue.setStroke()
                let border = NSBezierPath(rect: selection.insetBy(dx: -0.75, dy: -0.75))
                border.lineWidth = 1.5
                border.stroke()
            }
            drawItemDecorations()
            return
        }
        let focus = focusRect
        let dim = NSBezierPath(rect: bounds)
        if let focus {
            dim.append(focusPath(focus))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.4).setFill()
        dim.fill()
        guard let focus else { return }

        if hasSelection {
            NSGraphicsContext.saveGraphicsState()
            focusPath(focus).addClip()
            renderer.drawOverlays(items: items, draft: draft, hiddenID: editingID,
                                  translation: peekingOriginal ? [] : visibleTranslation)
            if ocrBoxesVisible, let recognition {
                for line in recognition.result.lines {
                    let box = NSBezierPath(roundedRect: line.rect.insetBy(dx: -2, dy: -1), xRadius: 3, yRadius: 3)
                    selectionBlue.withAlphaComponent(0.14).setFill()
                    box.fill()
                    selectionBlue.withAlphaComponent(0.55).setStroke()
                    box.lineWidth = 1
                    box.stroke()
                }
            }
            if case .loading = translationState { drawShimmer() }
            NSGraphicsContext.restoreGraphicsState()
            drawItemDecorations()
        }

        selectionBlue.setStroke()
        let border = focusPath(focus.insetBy(dx: -0.75, dy: -0.75))
        border.lineWidth = hasSelection || isSelecting ? 1.5 : 2.5
        border.stroke()

        if hasSelection {
            for handle in ResizeHandle.allCases {
                let p = handle.point(in: focus)
                let square = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
                selectionBlue.setFill()
                square.fill()
                NSColor.white.setStroke()
                let outline = NSBezierPath(rect: square.insetBy(dx: 0.5, dy: 0.5))
                outline.lineWidth = 1
                outline.stroke()
            }
        }
    }

    private func focusPath(_ rect: CGRect) -> NSBezierPath {
        let radius = hasSelection ? min(cornerRadius, min(rect.width, rect.height) / 2) : 0
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    private func drawItemDecorations() {
        if let editor = textEditor {
            dashedRect(editor.frame.insetBy(dx: -5, dy: -3))
        }
        if let hovered = item(hoveredID), hovered.id != selectedID, editingID != hovered.id {
            dashedRect(hovered.bounds.insetBy(dx: -3, dy: -3), alpha: 0.5)
        }
        guard let item = item(selectedID), editingID != item.id else { return }
        if item.handles.isEmpty || item.tool.usesAreaModes {
            dashedRect(item.bounds.insetBy(dx: -3, dy: -3))
        }
        for (_, p) in item.handles {
            let dot = NSBezierPath(ovalIn: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9))
            NSColor.white.setFill()
            dot.fill()
            selectionBlue.setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }
    }

    private func dashedRect(_ rect: CGRect, alpha: CGFloat = 1) {
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        NSColor.white.withAlphaComponent(0.8 * alpha).setStroke()
        path.stroke()
        path.setLineDash([4, 3], count: 2, phase: 0)
        selectionBlue.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    private func drawShimmer() {
        let t = Date().timeIntervalSince(shimmerStart)
        for (i, rect) in pendingBlockRects.enumerated() {
            let wave = 0.5 + 0.5 * sin(t * 5 - Double(i) * 0.6)
            selectionBlue.withAlphaComponent(0.10 + 0.16 * wave).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -1.5), xRadius: 3, yRadius: 3).fill()
        }
    }

    private func effectImage(_ effect: MosaicEffect) -> NSImage {
        if effect == .original { return baseImage }
        if let cached = effectImages[effect] { return cached }
        let input = CIImage(cgImage: snapshot)
        let output: CIImage?
        switch effect {
        case .pixelate:
            let filter = CIFilter(name: "CIPixellate")!
            filter.setValue(input, forKey: kCIInputImageKey)
            filter.setValue(max(8, 9 * scale), forKey: kCIInputScaleKey)
            filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
            output = filter.outputImage
        case .blur:
            let filter = CIFilter(name: "CIGaussianBlur")!
            filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
            filter.setValue(9 * scale, forKey: kCIInputRadiusKey)
            output = filter.outputImage
        case .original:
            output = input
        }
        guard let output, let cg = CIContext().createCGImage(output.cropped(to: input.extent), from: input.extent)
        else { return baseImage }
        let image = NSImage(cgImage: cg, size: bounds.size)
        effectImages[effect] = image
        return image
    }

    /// Marks the area around `rects` for redraw; used on hot paths instead of redrawing the whole screen.
    private func invalidate(_ rects: CGRect..., margin: CGFloat = 12) {
        let union = rects.filter { !$0.isNull }.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull else { return }
        setNeedsDisplay(union.insetBy(dx: -margin, dy: -margin))
    }

    // MARK: - Items

    private func item(_ id: UUID?) -> AnnotationItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    private var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return items.firstIndex { $0.id == selectedID }
    }

    private func hitItem(at p: CGPoint) -> AnnotationItem? {
        guard selection.insetBy(dx: -6, dy: -6).contains(p) else { return nil }
        // A freehand tool always paints, so strokes can be layered without selecting what is underneath.
        if let tool, tool.isFreehand { return nil }
        return items.reversed().first { $0.id != editingID && $0.contains(p) }
    }

    private func itemHandle(at p: CGPoint) -> ItemHandle? {
        guard let item = item(selectedID) else { return nil }
        return item.handles.first { abs($0.1.x - p.x) <= 7 && abs($0.1.y - p.y) <= 7 }?.0
    }

    private func select(_ id: UUID?) {
        guard selectedID != id else { return }
        let old = item(selectedID)?.bounds ?? .null
        selectedID = id
        invalidate(old, item(id)?.bounds ?? .null, margin: 14)
        layoutChrome()
    }

    private func replaceItem(_ item: AnnotationItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        let old = items[i].bounds
        items[i] = item
        invalidate(old, item.bounds, margin: max(14, item.size))
    }

    // MARK: - Undo

    private func beginChange() {
        if changeStart == nil { changeStart = items }
    }

    private func endChange() {
        coalesceWork?.cancel()
        coalesceWork = nil
        guard let start = changeStart else { return }
        changeStart = nil
        if start != items {
            undoStack.append(start)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        updateHistoryButtons()
    }

    /// Groups rapid changes (scrolling, arrow nudges, color panel drags) into one undo step.
    private func coalescedChange(_ body: () -> Void) {
        beginChange()
        body()
        coalesceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endChange() }
        coalesceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func mutate(_ body: () -> Void) {
        beginChange()
        body()
        endChange()
    }

    private func updateHistoryButtons() {
        toolbar.setHistory(canUndo: !undoStack.isEmpty || isTranslationShown, canRedo: !redoStack.isEmpty)
    }

    private var isTranslationShown: Bool {
        if case .shown = translationState { return true }
        return false
    }

    @objc func undo(_ sender: Any?) {
        commitText()
        endChange()
        if let previous = undoStack.popLast() {
            redoStack.append(items)
            items = previous
            if item(selectedID) == nil { selectedID = nil }
        } else if case let .shown(blocks, rect) = translationState {
            translationState = .hidden(blocks, rect)
            toolbar.translateButton.isActive = false
        }
        updateHistoryButtons()
        layoutChrome()
        needsDisplay = true
    }

    @objc func redo(_ sender: Any?) {
        commitText()
        endChange()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(items)
        items = next
        if item(selectedID) == nil { selectedID = nil }
        updateHistoryButtons()
        layoutChrome()
        needsDisplay = true
    }

    @objc func copy(_ sender: Any?) {
        if hasSelection { finish(.copy) }
    }

    // MARK: - Mouse

    private func point(_ event: NSEvent) -> CGPoint {
        clampToBounds(convert(event.locationInWindow, from: nil))
    }

    private func clampToBounds(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX - 0.01), y: min(max(p.y, bounds.minY), bounds.maxY - 0.01))
    }

    /// Positions the magnifier and hover state for the current mouse location; called when the overlay appears.
    func primeCursor() {
        guard let window else { return }
        handleMouseMoved(at: clampToBounds(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    override func mouseMoved(with event: NSEvent) {
        handleMouseMoved(at: point(event))
    }

    private func handleMouseMoved(at p: CGPoint) {
        guard session?.canInteract(self) ?? true else {
            magnifier.isHidden = true
            return
        }
        if !hasSelection {
            let hover = hoverTarget(at: p)
            if hover != hoverRect {
                let old = hoverRect ?? .null
                hoverRect = hover
                invalidate(old, hover ?? .null, margin: 4)
                layoutChrome()
            }
            showMagnifier(at: p, sizeText: nil)
            NSCursor.crosshair.set()
            return
        }

        if let polyPoints {
            updatePolylineDraft(polyPoints, cursor: p)
            NSCursor.crosshair.set()
            return
        }

        let hovered = textEditor == nil ? hitItem(at: p)?.id : nil
        if hovered != hoveredID {
            let old = item(hoveredID)?.bounds ?? .null
            hoveredID = hovered
            invalidate(old, item(hovered)?.bounds ?? .null)
        }

        if let handle = itemHandle(at: p) {
            if case let .rect(h) = handle { h.cursor.set() } else { NSCursor.crosshair.set() }
        } else if hovered != nil {
            NSCursor.openHand.set()
        } else if let handle = selectionHandle(at: p) {
            handle.cursor.set()
        } else if selection.contains(p) {
            if let tool {
                (tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
            } else {
                NSCursor.openHand.set()
            }
        } else {
            NSCursor.arrow.set()
        }
    }

    private func showMagnifier(at p: CGPoint, sizeText: String?) {
        magnifier.sizeText = sizeText
        magnifier.update(cursor: p, in: bounds)
        magnifier.isHidden = false
    }

    private func sizeText(_ r: CGRect) -> String {
        "\(Int(r.width.rounded())) × \(Int(r.height.rounded()))"
    }

    override func mouseDown(with event: NSEvent) {
        guard session?.canInteract(self) ?? true else { return }
        window?.makeKey()
        let p = point(event)
        mouseDownPoint = p
        didDrag = false
        if textEditor != nil {
            commitText()
            return
        }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        if polyPoints != nil {
            addPolylinePoint(p, finish: event.clickCount >= 2, shift: event.modifierFlags.contains(.shift))
            return
        }

        guard hasSelection else {
            drag = .selecting(p)
            return
        }

        let hit = hitItem(at: p)
        if event.clickCount == 2 {
            if let hit, case .text = hit.shape {
                beginTextEditing(existing: hit)
                return
            }
            if hit == nil, tool == nil, selection.contains(p) {
                finish(.copy)
                return
            }
        }
        if let item = item(selectedID), let handle = itemHandle(at: p) {
            beginChange()
            drag = .resizingItem(handle, item, p)
            return
        }
        if hit == nil, !mode.isBoard, let handle = selectionHandle(at: p) {
            drag = .resizing(handle, selection, p)
            return
        }
        if let hit {
            select(hit.id)
            beginChange()
            drag = .movingItem(p, hit)
            NSCursor.closedHand.set()
            return
        }
        select(nil)
        if let tool, selection.contains(p) {
            beginAnnotation(tool, at: p)
        } else if selection.contains(p), !mode.isBoard {
            drag = .moving(p, selection)
            NSCursor.closedHand.set()
        } else if items.isEmpty, case .none = translationState {
            // Dragging outside an untouched selection starts a new one.
            resetSelection()
            drag = .selecting(p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        if !didDrag, hypot(p.x - mouseDownPoint.x, p.y - mouseDownPoint.y) > 2 { didDrag = true }
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .none:
            return
        case let .selecting(start):
            guard didDrag else { return }
            let old = selection
            var end = p
            if let ratio = StyleMemory.aspectRatio {
                selection = SelectionGeometry.clamp(SelectionGeometry.fit(anchor: start, toward: p, ratio: ratio.value), anchor: start, in: bounds)
                end = CGPoint(x: selection.minX == start.x ? selection.maxX : selection.minX, y: selection.minY == start.y ? selection.maxY : selection.minY)
            } else {
                if shift {
                    let side = max(abs(p.x - start.x), abs(p.y - start.y))
                    end = clampToBounds(CGPoint(x: start.x + (p.x >= start.x ? side : -side), y: start.y + (p.y >= start.y ? side : -side)))
                }
                selection = CGRect(corners: start, end)
            }
            if hoverRect != nil {
                hoverRect = nil
                needsDisplay = true
            }
            invalidate(old, selection)
            showMagnifier(at: end, sizeText: sizeText(selection))
            layoutChrome()
        case let .moving(start, original):
            let old = selection
            var r = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = min(max(r.minX, 0), bounds.width - r.width)
            r.origin.y = min(max(r.minY, 0), bounds.height - r.height)
            selection = r
            invalidate(old, selection)
            layoutChrome()
        case let .resizing(handle, original, start):
            let old = selection
            let delta = CGPoint(x: p.x - start.x, y: p.y - start.y)
            if let ratio = StyleMemory.aspectRatio {
                selection = resize(original, handle: handle, by: delta, ratio: ratio.value)
            } else {
                selection = handle.resize(original, by: delta).intersection(bounds)
            }
            invalidate(old, selection)
            showMagnifier(at: p, sizeText: sizeText(selection))
            layoutChrome()
        case let .drawing(start):
            let old = draft?.bounds ?? .null
            updateDraft(from: start, to: clampToSelection(p), shift: shift)
            invalidate(old, draft?.bounds ?? .null, margin: 4 + (draft?.size ?? 0))
        case let .movingItem(start, original):
            replaceItem(original.moved(by: CGPoint(x: p.x - start.x, y: p.y - start.y)))
        case let .resizingItem(handle, original, start):
            replaceItem(original.resized(handle, by: CGPoint(x: p.x - start.x, y: p.y - start.y)))
        }
    }

    override func mouseUp(with event: NSEvent) {
        let finished = drag
        drag = .none
        switch finished {
        case .none:
            return
        case .selecting:
            if didDrag {
                guard selection.width >= 4, selection.height >= 4 else {
                    selection = .zero
                    layoutChrome()
                    needsDisplay = true
                    return
                }
            } else {
                // A click picks the window under the cursor, or the whole screen.
                selection = hoverRect?.intersection(bounds) ?? bounds
            }
            commitSelection()
        case .moving, .resizing:
            if selection.width < 4 || selection.height < 4 {
                selection = CGRect(x: selection.minX, y: selection.minY, width: max(4, selection.width), height: max(4, selection.height))
            }
            magnifier.isHidden = true
            layoutChrome()
            needsDisplay = true
        case let .drawing(start):
            if !didDrag, tool == .line || tool == .arrow {
                // A click instead of a drag starts a polyline; each further click adds a corner.
                polyPoints = [clampToSelection(start)]
                updatePolylineDraft(polyPoints!, cursor: start)
                return
            }
            if let draft, draft.isMeaningful {
                mutate { items.append(draft) }
                selectedID = draft.id
            }
            let bounds = draft?.bounds ?? .null
            draft = nil
            invalidate(bounds, margin: 16)
            layoutChrome()
        case .movingItem, .resizingItem:
            endChange()
            handleMouseMoved(at: point(event))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if polyPoints != nil {
            finishPolyline()
        } else if textEditor != nil {
            commitText()
        } else if !hasSelection {
            session?.cancel()
        } else if selectedID != nil {
            select(nil)
        } else if mode.isBoard {
            return
        } else if tool != nil {
            setTool(nil)
        } else if items.isEmpty, case .none = translationState {
            resetSelection()
            primeCursor()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if !hasSelection, !elementChain.isEmpty {
            // Wheel up walks out to the containing element, wheel down back in.
            scrollAccumulator += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 6 : event.scrollingDeltaY
            guard abs(scrollAccumulator) >= 1 else { return }
            let steps = Int(scrollAccumulator.rounded(.towardZero))
            scrollAccumulator = 0
            elementLevel = min(max(0, elementLevel + steps), elementChain.count - 1)
            let old = hoverRect ?? .null
            hoverRect = elementChain[elementLevel]
            invalidate(old, hoverRect ?? .null, margin: 4)
            layoutChrome()
            return
        }
        guard hasSelection, let tool = textEditor != nil ? .text : selectedTool ?? tool else { return }
        if tool.usesAreaModes {
            let brush = item(selectedID).map { $0.shape.isMosaicBrush } ?? (StyleMemory.areaMode(for: tool) == .brush)
            guard brush else { return }
        }
        scrollAccumulator += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 6 : event.scrollingDeltaY
        guard abs(scrollAccumulator) >= 1 else { return }
        let steps = scrollAccumulator.rounded(.towardZero)
        scrollAccumulator -= steps
        if event.modifierFlags.contains(.option) {
            adjustOpacity(by: steps * 0.1, tool: tool)
            return
        }
        let unit: CGFloat = tool.usesAreaModes || tool == .highlighter || tool == .text || tool == .number ? 2 : 1
        let current = currentStyle?.size ?? tool.defaultSize
        applyStyle(.size(current + steps * unit), coalesce: true)
    }

    /// ⌥ + wheel: opacity of the color, like Snipaste's scroll on the color button.
    private func adjustOpacity(by delta: CGFloat, tool: Tool) {
        guard !tool.usesAreaModes, let color = currentStyle?.color else { return }
        let alpha = min(1, max(0.1, ((color.alphaComponent + delta) * 10).rounded() / 10))
        applyStyle(.color(color.withAlphaComponent(alpha)), coalesce: true)
        showToast("不透明度 \(Int((alpha * 100).rounded()))%", duration: 0.8)
    }

    /// Resizing with a locked ratio: corners keep the opposite corner fixed, edges keep the top-left fixed.
    private func resize(_ original: CGRect, handle: ResizeHandle, by d: CGPoint, ratio: CGFloat) -> CGRect {
        let corners: [ResizeHandle: ResizeHandle] = [.topLeft: .bottomRight, .topRight: .bottomLeft, .bottomLeft: .topRight, .bottomRight: .topLeft]
        if let opposite = corners[handle] {
            let anchor = opposite.point(in: original)
            let dragged = handle.point(in: original)
            let p = CGPoint(x: dragged.x + d.x, y: dragged.y + d.y)
            return SelectionGeometry.clamp(SelectionGeometry.fit(anchor: anchor, toward: p, ratio: ratio), anchor: anchor, in: bounds)
        }
        let r = handle.resize(original, by: d)
        return SelectionGeometry.fitEdge(r, ratio: ratio, horizontalEdge: handle == .left || handle == .right, in: bounds)
    }

    /// A size typed into the top bar: keeps the top-left where possible, moving the selection back inside the screen.
    private func applyTypedSize(_ size: CGSize) {
        guard hasSelection else { return }
        let w = min(size.width, bounds.width), h = min(size.height, bounds.height)
        var r = CGRect(x: selection.minX, y: selection.minY, width: w, height: h)
        r.origin.x = min(r.minX, bounds.maxX - w)
        r.origin.y = min(r.minY, bounds.maxY - h)
        let old = selection
        selection = r
        if let ratio = StyleMemory.aspectRatio, abs(w / h - ratio.value) > 0.01 {
            // A typed size that breaks the lock turns the lock off rather than silently changing the size.
            StyleMemory.aspectRatio = nil
            topBar.setRatio(nil)
        }
        invalidate(old, selection)
        layoutChrome()
        needsDisplay = true
    }

    private func applyRatio(_ ratio: AspectRatio?) {
        StyleMemory.aspectRatio = ratio
        guard let ratio, hasSelection else {
            if let ratio { showToast("已锁定 \(ratio.label)", duration: 1) }
            return
        }
        let old = selection
        selection = SelectionGeometry.fitEdge(selection, ratio: ratio.value, horizontalEdge: true, in: bounds)
        invalidate(old, selection)
        layoutChrome()
        showToast("已锁定 \(ratio.label)", duration: 1)
    }

    func testing_typeSize(_ size: CGSize) { applyTypedSize(size) }
    func testing_setRatio(_ ratio: AspectRatio?) {
        topBar.setRatio(ratio)
        applyRatio(ratio)
    }

    private func selectionHandle(at p: CGPoint) -> ResizeHandle? {
        ResizeHandle.allCases.first {
            let h = $0.point(in: selection)
            return abs(h.x - p.x) <= 8 && abs(h.y - p.y) <= 8
        }
    }

    private func clampToSelection(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, selection.minX), selection.maxX), y: min(max(p.y, selection.minY), selection.maxY))
    }

    private func commitSelection() {
        if mode == .screenshot, let session, !session.autoOutputs.isEmpty {
            hasSelection = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let session = self.session, !session.isFinished else { return }
                session.performAutoOutputs(from: self)
            }
        }
        hasSelection = true
        hoverRect = nil
        magnifier.isHidden = true
        session?.didSelect(self)
        layoutChrome()
        needsDisplay = true
    }

    private func resetSelection() {
        commitText()
        recognitionTask?.cancel()
        recognitionTask = nil
        stopShimmer()
        hasSelection = false
        selection = .zero
        tool = nil
        toolbar.setActiveTool(nil)
        items = []
        undoStack = []
        redoStack = []
        selectedID = nil
        hoveredID = nil
        recognition = nil
        translationState = .none
        toolbar.translateButton.isActive = false
        closeOCRPanel()
        toast.hide()
        session?.didClearSelection(self)
        updateHistoryButtons()
        layoutChrome()
        needsDisplay = true
    }

    // MARK: - Drawing annotations

    private func setTool(_ newTool: Tool?) {
        finishPolyline()
        commitText()
        tool = newTool
        select(nil)
        toolbar.setActiveTool(tool)
        layoutChrome()
    }

    private func beginAnnotation(_ tool: Tool, at p: CGPoint) {
        let color = StyleMemory.color(for: tool)
        let size = StyleMemory.size(for: tool)
        let style = StyleMemory.style(for: tool)
        switch tool {
        case .text:
            beginTextEditing(at: p)
        case .number:
            let item = AnnotationItem(shape: .number(p), color: color, size: size, style: style)
            mutate { items.append(item) }
            selectedID = item.id
            invalidate(item.bounds, margin: 16)
            layoutChrome()
        case .pen:
            draft = AnnotationItem(shape: .pen([p]), color: color, size: size, style: style)
            drag = .drawing(p)
        case .highlighter:
            draft = AnnotationItem(shape: .highlighter([p]), color: color, size: size)
            drag = .drawing(p)
        case .mosaic, .eraser:
            let effect = StyleMemory.areaEffect(for: tool)
            if StyleMemory.areaMode(for: tool) == .brush {
                let item = AnnotationItem(shape: .mosaicBrush([p]), color: color, size: size, effect: effect)
                draft = item
                invalidate(item.bounds)
            } else {
                draft = AnnotationItem(shape: .mosaicRect(CGRect(origin: p, size: .zero)), color: color, size: size, effect: effect)
            }
            drag = .drawing(p)
        case .rectangle, .ellipse, .line, .arrow:
            let shape: Shape
            switch tool {
            case .rectangle: shape = .rectangle(CGRect(origin: p, size: .zero))
            case .ellipse: shape = .ellipse(CGRect(origin: p, size: .zero))
            case .line: shape = .line(p, p)
            default: shape = .arrow(p, p)
            }
            draft = AnnotationItem(shape: shape, color: color, size: size, style: style)
            drag = .drawing(p)
        }
    }

    private func updateDraft(from start: CGPoint, to p: CGPoint, shift: Bool) {
        guard var item = draft else { return }
        switch item.shape {
        case var .pen(points):
            if shift, let first = points.first {
                points = [first, p]
            } else if let last = points.last, hypot(p.x - last.x, p.y - last.y) >= 1 {
                points.append(p)
            }
            item.shape = .pen(points)
        case var .highlighter(points):
            if shift, let first = points.first {
                // Like a ruler: horizontal, vertical or 45°.
                let angle = (atan2(p.y - first.y, p.x - first.x) / (.pi / 4)).rounded() * (.pi / 4)
                let length = hypot(p.x - first.x, p.y - first.y)
                points = [first, CGPoint(x: first.x + cos(angle) * length, y: first.y + sin(angle) * length)]
            } else if let last = points.last, hypot(p.x - last.x, p.y - last.y) >= 1 {
                points.append(p)
            }
            item.shape = .highlighter(points)
        case var .mosaicBrush(points):
            if let last = points.last, hypot(p.x - last.x, p.y - last.y) >= 1 { points.append(p) }
            item.shape = .mosaicBrush(points)
        case .rectangle, .ellipse, .mosaicRect:
            var end = p
            if shift {
                let side = max(abs(p.x - start.x), abs(p.y - start.y))
                end = CGPoint(x: start.x + (p.x >= start.x ? side : -side), y: start.y + (p.y >= start.y ? side : -side))
            }
            let r = CGRect(corners: start, end)
            switch item.shape {
            case .rectangle: item.shape = .rectangle(r)
            case .ellipse: item.shape = .ellipse(r)
            default: item.shape = .mosaicRect(r)
            }
        case .line, .arrow:
            var end = p
            if shift {
                // Snap to 45° steps.
                let angle = (atan2(p.y - start.y, p.x - start.x) / (.pi / 4)).rounded() * (.pi / 4)
                let length = hypot(p.x - start.x, p.y - start.y)
                end = CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
            }
            if case .line = item.shape { item.shape = .line(start, end) } else { item.shape = .arrow(start, end) }
        case .text, .number, .polyline:
            break
        }
        draft = item
    }

    // MARK: - Polyline

    private func polylineEnd(from last: CGPoint?, to p: CGPoint, shift: Bool) -> CGPoint {
        let p = clampToSelection(p)
        guard shift, let last else { return p }
        let angle = (atan2(p.y - last.y, p.x - last.x) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(p.x - last.x, p.y - last.y)
        return clampToSelection(CGPoint(x: last.x + cos(angle) * length, y: last.y + sin(angle) * length))
    }

    private func updatePolylineDraft(_ points: [CGPoint], cursor: CGPoint) {
        let old = draft?.bounds ?? .null
        let end = polylineEnd(from: points.last, to: cursor, shift: NSEvent.modifierFlags.contains(.shift))
        draft = AnnotationItem(shape: .polyline(points + [end], arrow: tool == .arrow),
                               color: StyleMemory.color(for: tool ?? .line), size: StyleMemory.size(for: tool ?? .line),
                               style: StyleMemory.style(for: tool ?? .line))
        invalidate(old, draft?.bounds ?? .null, margin: 4 + (draft?.size ?? 0))
    }

    private func addPolylinePoint(_ p: CGPoint, finish: Bool, shift: Bool) {
        guard var points = polyPoints else { return }
        if finish {
            finishPolyline()
            return
        }
        points.append(polylineEnd(from: points.last, to: p, shift: shift))
        polyPoints = points
        updatePolylineDraft(points, cursor: p)
    }

    /// Commits the clicked-out corners (double-click, right-click, Return or Esc).
    private func finishPolyline() {
        guard var points = polyPoints else { return }
        polyPoints = nil
        // The double-click that ends a polyline also placed a corner on its first click; drop such repeats.
        points = points.reduce(into: []) { result, p in
            if let last = result.last, hypot(last.x - p.x, last.y - p.y) < 2 { return }
            result.append(p)
        }
        let old = draft?.bounds ?? .null
        draft = nil
        let item = AnnotationItem(shape: .polyline(points, arrow: tool == .arrow), color: StyleMemory.color(for: tool ?? .line),
                                  size: StyleMemory.size(for: tool ?? .line), style: StyleMemory.style(for: tool ?? .line))
        if item.isMeaningful {
            mutate { items.append(item) }
            selectedID = item.id
        }
        invalidate(old, item.bounds, margin: 16)
        layoutChrome()
    }

    private func deleteSelectedItem() {
        guard let id = selectedID else { return }
        mutate { items.removeAll { $0.id == id } }
        selectedID = nil
        hoveredID = nil
        // Numbers after the deleted one shift down, so redraw everything.
        needsDisplay = true
        layoutChrome()
    }

    // MARK: - Text

    private func beginTextEditing(at p: CGPoint? = nil, existing: AnnotationItem? = nil) {
        commitText()
        beginChange()
        var origin = p ?? .zero
        var text = ""
        if let existing, case let .text(t, o, _) = existing.shape {
            origin = o
            text = t
            editingColor = existing.color
            editingSize = existing.size
            editingStyle = existing.style
            editingID = existing.id
            selectedID = nil
        } else {
            editingColor = StyleMemory.color(for: .text)
            editingSize = StyleMemory.size(for: .text)
            editingStyle = StyleMemory.style(for: .text)
            origin.y -= editingSize * 0.6
        }
        let wrap = max(60, selection.maxX - origin.x - 6)
        let editor = TextEditorView(origin: origin, wrapWidth: wrap, color: editingColor, size: editingSize)
        editor.string = text
        editor.apply(color: editingColor, size: editingSize)
        editor.onCommit = { [unowned self] in self.commitText() }
        editor.onResize = { [unowned self] in self.needsDisplay = true }
        addSubview(editor, positioned: .below, relativeTo: topBar)
        textEditor = editor
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        layoutChrome()
        needsDisplay = true
    }

    private func commitText() {
        guard let editor = textEditor else { return }
        textEditor = nil
        let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let shape = Shape.text(text, editor.frame.origin, width: editor.wrapWidth)
        if let id = editingID, let i = items.firstIndex(where: { $0.id == id }) {
            if text.isEmpty {
                items.remove(at: i)
            } else {
                items[i].shape = shape
                items[i].color = editingColor
                items[i].size = editingSize
                items[i].style = editingStyle
                selectedID = id
            }
        } else if !text.isEmpty {
            let item = AnnotationItem(shape: shape, color: editingColor, size: editingSize, style: editingStyle)
            items.append(item)
            selectedID = item.id
        }
        editingID = nil
        editor.removeFromSuperview()
        endChange()
        window?.makeFirstResponder(self)
        layoutChrome()
        needsDisplay = true
    }

    // MARK: - Style

    private var selectedTool: Tool? { item(selectedID)?.tool }

    private var currentStyle: StyleState? {
        if textEditor != nil {
            return StyleState(tool: .text, color: editingColor, size: editingSize,
                              mosaicMode: StyleMemory.mosaicMode, mosaicEffect: StyleMemory.mosaicEffect, options: editingStyle)
        }
        if let item = item(selectedID) {
            return StyleState(tool: item.tool, color: item.color, size: item.size,
                              mosaicMode: item.shape.isMosaicBrush ? .brush : .rect, mosaicEffect: item.effect, options: item.style)
        }
        guard let tool else { return nil }
        return StyleState(tool: tool, color: StyleMemory.color(for: tool), size: StyleMemory.size(for: tool),
                          mosaicMode: StyleMemory.areaMode(for: tool), mosaicEffect: StyleMemory.areaEffect(for: tool),
                          options: StyleMemory.style(for: tool))
    }

    private func applyStyle(_ action: StyleAction) {
        applyStyle(action, coalesce: false)
    }

    var testing_items: [AnnotationItem] { items }

    /// Lets the offscreen UI demo press style-bar buttons.
    func testing_applyStyle(_ action: StyleAction) {
        applyStyle(action)
    }

    private func applyStyle(_ action: StyleAction, coalesce: Bool) {
        if case .customColor = action {
            openColorPanel()
            return
        }
        guard let styleTool = textEditor != nil ? .text : selectedTool ?? tool else { return }
        var action = action
        if case let .color(c) = action, !coalesce, let current = currentStyle?.color, c.alphaComponent == 1 {
            // Picking a swatch keeps the opacity set with ⌥ + wheel.
            action = .color(c.withAlphaComponent(current.alphaComponent))
        }
        var clampedSize: CGFloat?
        if case let .size(value) = action {
            let range = styleTool.sizeRange
            clampedSize = min(max(value, range.lowerBound), range.upperBound)
        }

        // Remember the choice for the next annotation of this kind.
        switch action {
        case .size: StyleMemory.sizes[styleTool] = clampedSize
        case let .color(c): StyleMemory.setColor(c, for: styleTool)
        case let .mosaicMode(m):
            if styleTool == .eraser { StyleMemory.eraserMode = m } else { StyleMemory.mosaicMode = m }
        case let .mosaicEffect(e): StyleMemory.mosaicEffect = e
        case .options: break
        case .customColor: break
        }
        var newOptions: ItemStyle?
        if case let .options(change) = action, var options = currentStyle?.options {
            change(&options)
            newOptions = options
            StyleMemory.setStyle(options, for: styleTool)
        }

        if let editor = textEditor {
            if let clampedSize { editingSize = clampedSize }
            if case let .color(c) = action { editingColor = c }
            if let newOptions { editingStyle = newOptions }
            editor.apply(color: editingColor, size: editingSize)
        } else if let index = selectedIndex {
            let change = {
                var item = self.items[index]
                if let clampedSize { item.size = clampedSize }
                if case let .color(c) = action { item.color = c }
                if case let .mosaicEffect(e) = action { item.effect = e }
                if let newOptions { item.style = newOptions }
                self.replaceItem(item)
            }
            if coalesce { coalescedChange(change) } else { mutate(change) }
            if case .mosaicEffect = action { needsDisplay = true }
        }
        layoutChrome()
    }

    private func openColorPanel() {
        let panel = NSColorPanel.shared
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.color = currentStyle?.color ?? StyleMemory.color(for: tool ?? .rectangle)
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        applyStyle(.color(sender.color), coalesce: true)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = Int(event.keyCode)
        let arrows: [Int: CGPoint] = [123: CGPoint(x: -1, y: 0), 124: CGPoint(x: 1, y: 0), 125: CGPoint(x: 0, y: 1), 126: CGPoint(x: 0, y: -1)]

        if code == 53 {
            handleEscape()
            return
        }

        if code == 96 || (flags == .command && key == "r") {
            finishPolyline()
            commitText()
            session?.refresh(from: self)
            return
        }
        if mode.isBoard, flags.isEmpty, key == " " {
            toolbarHiddenByUser.toggle()
            layoutChrome()
            return
        }
        if flags.isEmpty, key == "`" {
            toggleCursor()
            return
        }
        if flags.isEmpty, key == "," || key == "." {
            finishPolyline()
            commitText()
            session?.stepHistory(key == "," ? 1 : -1, from: self)
            return
        }

        guard hasSelection else {
            if code == 48, flags.isEmpty {
                // Tab: elements or whole windows.
                detectElements.toggle()
                elementChain = []
                elementLevel = 0
                primeCursor()
                showToast(detectElements ? (hierarchy == nil ? "识别界面元素（需要辅助功能权限）" : "识别界面元素 · 滚轮切换父/子元素") : "只识别窗口", duration: 1.5)
                return
            }
            if let d = arrows[code] {
                let step: CGFloat = flags.contains(.shift) ? 10 : 1
                warpCursor(by: CGPoint(x: d.x * step, y: d.y * step))
            } else if code == 36 || code == 76 {
                selection = hoverRect?.intersection(bounds) ?? bounds
                commitSelection()
            } else if flags.isEmpty, key == "r" {
                restoreLastSelection()
            } else if flags.isEmpty, key == "c" {
                copyPixelColor()
            }
            return
        }

        if code == 36 || code == 76 {
            if polyPoints != nil { finishPolyline() } else { finish(.apply) }
            return
        }
        if code == 51 || code == 117 {
            deleteSelectedItem()
            return
        }
        if let d = arrows[code] {
            handleArrow(d, flags: flags)
            return
        }
        if flags == .command {
            switch key {
            case "z": undo(nil)
            case "c": finish(.copy)
            case "s": finish(.save)
            case "t": handle(.pin)
            default: super.keyDown(with: event)
            }
            return
        }
        if flags == [.command, .shift] {
            switch key {
            case "z": redo(nil)
            case "s": finish(.saveAs)
            default: super.keyDown(with: event)
            }
            return
        }
        guard flags.isEmpty else { return }
        if let t = Tool.allCases.first(where: { $0.key == key }) {
            handle(.tool(t))
        } else if key == "x" {
            handle(.ocr)
        } else if key == "y" {
            handle(.translate)
        } else if key == "s" {
            handle(.longCapture)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        handleEscape()
    }

    /// Esc steps back one level at a time; it only closes the capture when there is nothing left to back out of.
    private func handleEscape() {
        if mode.isBoard, mode != .pinEdit, polyPoints == nil, textEditor == nil, selectedID == nil {
            if escapeArmed {
                session?.cancel()
            } else {
                escapeArmed = true
                showToast("再按一次 Esc 退出白板", duration: 1.5)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.escapeArmed = false }
            }
            return
        }
        if polyPoints != nil {
            finishPolyline()
        } else if textEditor != nil {
            commitText()
        } else if !ocrPanel.isHidden {
            closeOCRPanel()
        } else if selectedID != nil {
            select(nil)
        } else if tool != nil {
            setTool(nil)
        } else {
            session?.cancel()
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        if shift, !shiftDown, !magnifier.isHidden, case .none = drag {
            StyleMemory.hexColor.toggle()
            magnifier.showHex = StyleMemory.hexColor
        topBar.onSize = { [unowned self] in self.applyTypedSize($0) }
        topBar.onRatio = { [unowned self] in self.applyRatio($0) }
        topBar.onEndEditing = { [unowned self] in self.window?.makeFirstResponder(self) }
        }
        shiftDown = shift

        let shouldPeek = event.modifierFlags.contains(.option) && isTranslationShown
        if shouldPeek != peekingOriginal {
            peekingOriginal = shouldPeek
            invalidate(selection)
        }
    }

    /// Arrow keys: nudge the selected annotation, or move / expand (⌘) / shrink (⇧) the selection by 1pt.
    private func handleArrow(_ d: CGPoint, flags: NSEvent.ModifierFlags) {
        if let index = selectedIndex {
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            coalescedChange { replaceItem(items[index].moved(by: CGPoint(x: d.x * step, y: d.y * step))) }
            return
        }
        let old = selection
        if flags.isEmpty {
            var r = selection.offsetBy(dx: d.x, dy: d.y)
            r.origin.x = min(max(r.minX, 0), bounds.width - r.width)
            r.origin.y = min(max(r.minY, 0), bounds.height - r.height)
            selection = r
        } else if flags == .command || flags == .shift {
            // ⌘ pushes the edge in the arrow's direction outward; ⇧ pulls that same edge inward.
            let outward: CGFloat = flags == .command ? 1 : -1
            var minX = selection.minX, maxX = selection.maxX, minY = selection.minY, maxY = selection.maxY
            if d.x < 0 { minX -= outward }
            if d.x > 0 { maxX += outward }
            if d.y < 0 { minY -= outward }
            if d.y > 0 { maxY += outward }
            let r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(bounds)
            guard r.width >= 4, r.height >= 4 else { return }
            selection = r
        } else {
            return
        }
        invalidate(old, selection)
        layoutChrome()
    }

    private func warpCursor(by d: CGPoint) {
        guard let window, let primary = NSScreen.screens.first else { return }
        let current = clampToBounds(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        let target = clampToBounds(CGPoint(x: current.x + d.x, y: current.y + d.y))
        let onScreen = window.convertPoint(toScreen: convert(target, to: nil))
        CGWarpMouseCursorPosition(CGPoint(x: onScreen.x, y: primary.frame.maxY - onScreen.y))
        CGAssociateMouseAndMouseCursorPosition(1)
        handleMouseMoved(at: target)
    }

    private func restoreLastSelection() {
        guard let last = StyleMemory.lastSelection[displayID]?.intersection(bounds), last.width >= 4, last.height >= 4 else {
            showToast("还没有上一次的选区")
            return
        }
        selection = last
        commitSelection()
    }

    private func copyPixelColor() {
        let value = magnifier.colorString
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        showToast("已复制颜色 \(value)", duration: 1.5)
    }

    // MARK: - Chrome

    private func layoutChrome() {
        let sizeRect: CGRect? = hasSelection || isSelecting ? (selection.width > 0 ? selection : nil) : hoverRect
        topBar.isHidden = sizeRect == nil
        if let sizeRect {
            topBar.setControlsVisible(hasSelection)
            topBar.setSize(sizeRect.size)
            var top = CGPoint(x: sizeRect.minX, y: sizeRect.minY - topBar.frame.height - 6)
            if top.y < 4 { top.y = sizeRect.minY + 6 }
            top.x = min(max(4, top.x), bounds.maxX - topBar.frame.width - 4)
            topBar.setFrameOrigin(top)
        }

        if mode.isBoard { topBar.isHidden = true }
        toolbar.isHidden = !hasSelection || isAdjustingSelection || toolbarHiddenByUser
        if !hasSelection { ocrPanel.isHidden = true }
        let style = currentStyle
        styleBar.isHidden = toolbar.isHidden || style == nil
        guard hasSelection else {
            positionToast()
            return
        }

        let size = toolbar.frame.size
        var bar = CGPoint(x: selection.maxX - size.width, y: selection.maxY + 8)
        var below = true
        if bar.y + size.height > bounds.maxY - 4 {
            let aboveTop = topBar.frame.minY < selection.minY ? topBar.frame.minY : selection.minY
            bar.y = aboveTop - size.height - 8
            below = false
            if bar.y < 4 {
                bar.y = selection.maxY - size.height - 8
                below = true
            }
        }
        bar.x = min(max(4, bar.x), bounds.maxX - size.width - 4)
        toolbar.setFrameOrigin(bar)

        if let style, !styleBar.isHidden {
            // Put the style bar next to the toolbar with a caret pointing at the tool it configures.
            var styleBelow = below
            let expectedHeight: CGFloat = 42
            if styleBelow, bar.y + size.height + 4 + expectedHeight > bounds.maxY - 4 { styleBelow = false }
            if !styleBelow, bar.y - 4 - expectedHeight < 4 { styleBelow = true }
            styleBar.caret = (styleBelow ? .top : .bottom, 0)
            styleBar.configure(style)
            let anchor = bar.x + (toolbar.anchorX(for: style.tool) ?? size.width / 2)
            let styleSize = styleBar.frame.size
            let x = min(max(4, anchor - 26), bounds.maxX - styleSize.width - 4)
            let y = styleBelow ? bar.y + size.height + 4 : bar.y - styleSize.height - 4
            styleBar.setFrameOrigin(CGPoint(x: x, y: y))
            styleBar.caret = (styleBelow ? .top : .bottom, anchor - x)
        }

        let panel = ocrPanel.frame.size
        var panelOrigin = CGPoint(x: selection.maxX + 10, y: selection.minY)
        if panelOrigin.x + panel.width > bounds.maxX - 4 { panelOrigin.x = selection.minX - panel.width - 10 }
        if panelOrigin.x < 4 { panelOrigin.x = bounds.maxX - panel.width - 4 }
        panelOrigin.y = min(max(4, panelOrigin.y), bounds.maxY - panel.height - 4)
        ocrPanel.setFrameOrigin(panelOrigin)

        positionToast()
    }

    private func positionToast() {
        let anchor = hasSelection ? selection : CGRect(x: bounds.midX, y: 40, width: 0, height: 0)
        toast.setFrameOrigin(CGPoint(x: min(max(4, anchor.midX - toast.frame.width / 2), bounds.maxX - toast.frame.width - 4),
                                     y: max(4, anchor.minY + 10)))
    }

    private func showToast(_ text: String, duration: TimeInterval? = 2.5) {
        toast.show(text, duration: duration, maxWidth: hasSelection ? max(220, selection.width) : 400)
        positionToast()
    }

    private func handle(_ action: ToolbarAction) {
        commitText()
        switch action {
        case let .tool(t):
            setTool(tool == t ? nil : t)
        case .undo:
            undo(nil)
        case .redo:
            redo(nil)
        case .ocr:
            runOCR()
        case .translate:
            runTranslation()
        case .pin:
            if mode == .pinEdit { finish(.apply) } else { pinSelection() }
        case .longCapture:
            if mode == .screenshot { startLongCapture() } else { showToast("这里不能长截图") }
        case .cancel:
            session?.cancel()
        case .save:
            finish(NSEvent.modifierFlags.contains(.shift) ? .saveAs : .save)
        case .share:
            shareSelection()
        case .done:
            finish(.apply)
        }
    }

    // MARK: - OCR and translation

    private func cropSelection() -> CGImage? {
        let r = CGRect(x: selection.minX * scale, y: selection.minY * scale,
                       width: selection.width * scale, height: selection.height * scale).integral
        return snapshot.cropping(to: r)
    }

    /// Runs Vision once per selection rect; OCR and translation share the result.
    private func recognize() async throws -> RecognitionResult {
        if let recognition, recognition.rect == selection { return recognition.result }
        guard let crop = cropSelection() else { throw CocoaError(.featureUnsupported) }
        let rect = selection
        let result = try await TextRecognizer.recognize(crop, selection: rect)
        recognition = (rect, result)
        return result
    }

    private func closeOCRPanel() {
        ocrPanel.isHidden = true
        if ocrBoxesVisible {
            ocrBoxesVisible = false
            invalidate(selection)
        }
        window?.makeFirstResponder(self)
    }

    private func runOCR() {
        guard recognitionTask == nil else { return }
        showToast("正在识别文字…", duration: nil)
        recognitionTask = Task { @MainActor in
            defer { recognitionTask = nil }
            do {
                let result = try await recognize()
                let text = result.plainText
                guard !text.isEmpty else {
                    showToast("没有识别到文字")
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                ocrPanel.show(text: text, lineCount: result.lines.count + result.codes.count)
                ocrPanel.isHidden = false
                ocrBoxesVisible = true
                invalidate(selection)
                layoutChrome()
                toast.hide()
            } catch {
                showToast("文字识别失败：\(error.localizedDescription)")
            }
        }
    }

    private func runTranslation() {
        switch translationState {
        case .loading:
            return
        case let .shown(blocks, rect) where rect == selection:
            translationState = .hidden(blocks, rect)
            toolbar.translateButton.isActive = false
            showToast("显示原文", duration: 1)
            updateHistoryButtons()
            invalidate(selection)
            return
        case let .hidden(blocks, rect) where rect == selection:
            translationState = .shown(blocks, rect)
            toolbar.translateButton.isActive = true
            showToast("显示译文", duration: 1)
            updateHistoryButtons()
            invalidate(selection)
            return
        default:
            break
        }

        let config = Settings.shared.translationConfig
        guard !config.apiKey.isEmpty else {
            showToast("还没有填写 API Key。请按 Esc 退出截图，在菜单栏 Snap → 设置 中填写。", duration: 5)
            return
        }
        guard recognitionTask == nil else { return }
        let previous = translationState
        translationState = .loading
        toolbar.translateButton.isActive = true
        showToast("正在识别文字…", duration: nil)
        let rect = selection

        recognitionTask = Task { @MainActor in
            defer {
                recognitionTask = nil
                stopShimmer()
            }
            do {
                let result = try await recognize()
                let blocks = TextBlockBuilder.group(result.lines).filter { TextBlockBuilder.shouldTranslate($0.text) }
                guard !blocks.isEmpty else {
                    translationState = previous
                    toolbar.translateButton.isActive = false
                    showToast("没有找到需要翻译的外文")
                    return
                }
                pendingBlockRects = blocks.map(\.rect)
                startShimmer()
                showToast("正在翻译 \(blocks.count) 段…", duration: nil)
                let items = blocks.map { ChatTranslator.Item(id: $0.id, text: $0.text) }
                let translations = try await TranslationService.cache.translate(items, config: config) {
                    try await ChatTranslator.translate($0, config: config)
                }
                guard let crop = cropSelection(), rect == selection else {
                    translationState = previous
                    toolbar.translateButton.isActive = false
                    showToast("选区已改变，请重新翻译")
                    return
                }
                let laidOut = TranslationLayout.layout(blocks: blocks, translations: translations, crop: crop, selection: rect)
                translationState = .shown(laidOut, rect)
                let missing = blocks.count - laidOut.count
                showToast(missing > 0 ? "已翻译 \(laidOut.count) 段，\(missing) 段没有返回译文" : "已翻译 \(laidOut.count) 段 · Y 切换原文 · 按住 ⌥ 临时查看原文",
                          duration: missing > 0 ? 3 : 2)
                updateHistoryButtons()
                invalidate(selection)
            } catch is CancellationError {
                translationState = previous
            } catch {
                translationState = previous
                toolbar.translateButton.isActive = isTranslationShown
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                showToast("翻译失败：\(message)\n再按一次翻译按钮可以重试。", duration: 6)
                invalidate(selection)
            }
        }
    }

    private func startShimmer() {
        shimmerStart = Date()
        shimmerTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.invalidate(self.pendingBlockRects.reduce(CGRect.null) { $0.union($1) }, margin: 4)
        }
        RunLoop.main.add(timer, forMode: .common)
        shimmerTimer = timer
    }

    private func stopShimmer() {
        shimmerTimer?.invalidate()
        shimmerTimer = nil
        if !pendingBlockRects.isEmpty {
            invalidate(pendingBlockRects.reduce(CGRect.null) { $0.union($1) }, margin: 4)
            pendingBlockRects = []
        }
    }

    // MARK: - Output

    /// The image that copy/save would produce right now.
    /// `base` replaces the frozen screen, for a transparent board exported over what is on screen now.
    func exportImage(format: ImageFormat, shadow: Bool? = nil, base: CGImage? = nil) -> NSBitmapImageRep? {
        // Boards are full-screen pictures: no rounded corners or drop shadow.
        let options = ExportOptions(cornerRadius: mode.isBoard ? 0 : cornerRadius, shadow: mode.isBoard ? false : shadow ?? shadowEnabled,
                                    format: format)
        var renderer = self.renderer
        if let base {
            renderer = ContentRenderer(base: NSImage(cgImage: base, size: bounds.size), bounds: bounds, effect: { _ in NSImage(cgImage: base, size: self.bounds.size) })
        }
        return Exporter.render(renderer: renderer, selection: selection, scale: scale,
                               items: items, translation: visibleTranslation, options: options)
    }

    /// The selection in global screen coordinates.
    var selectionOnScreen: CGRect? {
        guard let window else { return nil }
        return CGRect(x: window.frame.minX + selection.minX, y: window.frame.maxY - selection.maxY,
                      width: selection.width, height: selection.height)
    }

    /// Floats the current selection (with annotations and translation) above other windows, where it was captured.
    private func pinSelection() {
        commitText()
        endChange()
        guard hasSelection, let frame = selectionOnScreen, let rep = exportImage(format: .png, shadow: false) else { return }
        StyleMemory.lastSelection[displayID] = selection
        let saved = autoSaveIfEnabled()
        session?.record(self)
        session?.finish()
        Sound.playCapture()
        PinManager.shared.pin(rep, frame: frame)
        if let saved { HUD.show("已贴图，并自动保存到 \(saved)", on: window?.screen) }
    }

    /// Closes the overlay (it sits above menus) and opens the share menu where the selection was.
    private func shareSelection() {
        commitText()
        endChange()
        guard hasSelection, let rect = selectionOnScreen, let rep = exportImage(format: .png) else { return }
        StyleMemory.lastSelection[displayID] = selection
        session?.record(self)
        session?.finish()
        ShareController.share(rep, at: rect)
    }

    /// Hands the selected region to the long-screenshot controller. Annotations are not carried over.
    private func startLongCapture() {
        guard hasSelection, let rect = selectionOnScreen, let screen = window?.screen else { return }
        guard selection.height >= 60 else {
            showToast("选区太矮了，长截图需要至少 60pt 高的滚动区域")
            return
        }
        StyleMemory.lastSelection[displayID] = selection
        session?.finish()
        ScrollCaptureController.start(rect: rect, screen: screen)
    }

    /// Bakes the annotations into the pin; ⌘C and ⌘S also copy or save the result.
    private func finishPinEdit(_ output: OutputAction) {
        guard let rep = exportImage(format: .png) else {
            showToast("导出图片失败")
            return
        }
        switch output {
        case .copy:
            Exporter.copy(rep)
        case .save, .saveAs:
            let settings = Settings.shared
            if let saved = exportImage(format: settings.imageFormat) {
                _ = try? Exporter.save(saved, format: settings.imageFormat, directory: settings.saveDirectory)
            }
        case .apply:
            break
        }
        session?.applyPinEdit(rep)
    }

    /// With auto-save on, copying or pinning also writes the file. Returns the short path, or nil when off or failed.
    private func autoSaveIfEnabled(base: CGImage? = nil) -> String? {
        let settings = Settings.shared
        guard settings.autoSave, let rep = exportImage(format: settings.imageFormat, base: base),
              let url = try? Exporter.save(rep, format: settings.imageFormat, directory: settings.saveDirectory)
        else { return nil }
        return url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func finish(_ output: OutputAction, base: CGImage? = nil) {
        commitText()
        endChange()
        guard hasSelection, selection.width >= 1, selection.height >= 1 else { return }
        if mode == .transparentBoard, base == nil {
            // The drawing goes onto what is on screen right now; Snap's own windows are left out of that capture.
            guard let session else { return }
            Task { @MainActor in
                if let live = try? await session.liveCapture()[displayID] {
                    finish(output, base: live)
                } else {
                    showToast("截取屏幕失败")
                }
            }
            return
        }
        if !mode.isBoard { StyleMemory.lastSelection[displayID] = selection }
        if mode == .pinEdit {
            finishPinEdit(output)
            return
        }
        let output: OutputAction = output == .apply ? .copy : output
        let settings = Settings.shared
        let format: ImageFormat = output == .copy ? .png : settings.imageFormat
        guard let rep = exportImage(format: format, base: base) else {
            showToast("导出图片失败")
            return
        }
        let screen = window?.screen
        switch output {
        case .copy:
            Exporter.copy(rep)
            let saved = autoSaveIfEnabled(base: base)
            session?.record(self)
            session?.finish()
            Sound.playCapture()
            HUD.show(saved.map { "已复制，并自动保存到 \($0)" } ?? "已复制到剪贴板", on: screen)
        case .save:
            do {
                let url = try Exporter.save(rep, format: format, directory: settings.saveDirectory)
                session?.record(self)
                session?.finish()
                Sound.playCapture()
                HUD.show("已保存到 \(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))", on: screen)
            } catch {
                showToast("保存失败：\(error.localizedDescription)", duration: 5)
            }
        case .saveAs:
            session?.presentSavePanel(rep: rep, format: format)
        case .apply:
            break // mapped to .copy above
        }
    }
}

extension Shape {
    var isMosaicBrush: Bool {
        if case .mosaicBrush = self { return true }
        return false
    }
}

enum TranslationService {
    static let cache = TranslationCache()
}
