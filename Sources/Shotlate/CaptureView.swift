import AppKit
import CoreImage
import ShotlateCore

/// Style choices remembered across captures. Color and size are kept per tool, and saved across launches.
enum StyleMemory {
    private static let defaults = UserDefaults.standard

    static func color(for tool: Tool) -> NSColor {
        guard let rgba = (defaults.dictionary(forKey: "style.colors") as? [String: [Double]])?[tool.rawValue], rgba.count == 4 else {
            return StyleState.palette[0]
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
    static var mosaicEffect: MosaicEffect = .pixelate
    static var hexColor = true
    static var lastSelection: [CGDirectDisplayID: CGRect] = [:]

    static func size(for tool: Tool) -> CGFloat { sizes[tool] ?? tool.defaultSize }
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

/// A normal screenshot, or annotating a pin.
enum CaptureMode: Equatable {
    case screenshot
    /// Annotating a pin: the pin's image is the canvas, everything else stays live and untouched.
    case pinEdit
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
        ContentRenderer(base: baseImage, bounds: bounds, effect: { [unowned self] in self.effectImage($0) })
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
    private var textEditor: TextEditorView?
    private var editingID: UUID?
    /// The number badge whose caption is being typed, reselected if the caption is left empty.
    private var captionedNumberID: UUID?
    private var editingColor = StyleMemory.color(for: .text)
    private var editingSize = StyleMemory.size(for: .text)
    private var editingStyle = StyleMemory.style(for: .text)

    // Translation
    private var recognition: (rect: CGRect, result: RecognitionResult)?
    private var translationState = TranslationState.none
    private var recognitionTask: Task<Void, Never>?
    private var pendingBlockRects: [CGRect] = []
    private var shimmerTimer: Timer?
    private var shimmerStart = Date()
    private var ocrBoxesVisible = false

    // Chrome
    private lazy var toolbar = ToolbarView { [unowned self] in self.handle($0) }
    private lazy var styleBar = StyleBarView { [unowned self] in self.applyStyle($0) }
    private let topBar = TopBarView()
    private let toast = ToastView()
    private lazy var ocrPanel = OCRPanelView { [unowned self] in self.closeOCRPanel() }
    private lazy var magnifier = MagnifierView(snapshot: snapshot, viewSize: bounds.size)

    let mode: CaptureMode

    init(frame: CGRect, snapshot: CGImage, windowRects: [CGRect], displayID: CGDirectDisplayID, mode: CaptureMode = .screenshot) {
        self.mode = mode
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
        updateHistoryButtons()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var snapshotImage: CGImage { snapshot }
    var testing_selection: CGRect? { hasSelection ? selection : nil }

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

    var testing_hoverRect: CGRect? { hoverRect }

    /// What to highlight at `p` before anything is selected: the window under it.
    private func hoverTarget(at p: CGPoint) -> CGRect? {
        windowRects.first { $0.contains(p) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if mode == .pinEdit {
            // No dimming or handles: the pin is the canvas.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: selection).addClip()
            renderer.drawOverlays(items: items, draft: draft, hiddenID: editingID, translation: visibleTranslation)
            if case .loading = translationState { drawShimmer() }
            NSGraphicsContext.restoreGraphicsState()
            selectionBlue.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: -0.75, dy: -0.75))
            border.lineWidth = 1.5
            border.stroke()
            drawItemDecorations()
            return
        }
        let focus = focusRect
        let dim = NSBezierPath(rect: bounds)
        if let focus {
            dim.append(NSBezierPath(rect: focus))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.4).setFill()
        dim.fill()
        guard let focus else { return }

        if hasSelection {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: focus).addClip()
            renderer.drawOverlays(items: items, draft: draft, hiddenID: editingID, translation: visibleTranslation)
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
        let border = NSBezierPath(rect: focus.insetBy(dx: -0.75, dy: -0.75))
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

    private func drawItemDecorations() {
        if let editor = textEditor {
            dashedRect(editor.frame.insetBy(dx: -5, dy: -3))
        }
        if let hovered = item(hoveredID), hovered.id != selectedID, editingID != hovered.id {
            dashedRect(hovered.bounds.insetBy(dx: -3, dy: -3), alpha: 0.5)
        }
        guard let item = item(selectedID), editingID != item.id else { return }
        if item.handles.isEmpty || item.tool == .mosaic {
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
        toolbar.setCanUndo(!undoStack.isEmpty || isTranslationShown)
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

    var testing_magnifierVisible: Bool { !magnifier.isHidden }
    var testing_magnifier: MagnifierView { magnifier }

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
            let wasCaption = captionedNumberID != nil
            commitText()
            // With the number tool, the click that ends a caption also places the next number.
            guard wasCaption, tool == .number else { return }
            select(nil)
        }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }

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
        if hit == nil, mode == .screenshot, let handle = selectionHandle(at: p) {
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
        } else if selection.contains(p), mode == .screenshot {
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
            if shift {
                let side = max(abs(p.x - start.x), abs(p.y - start.y))
                end = clampToBounds(CGPoint(x: start.x + (p.x >= start.x ? side : -side), y: start.y + (p.y >= start.y ? side : -side)))
            }
            selection = CGRect(corners: start, end)
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
            selection = handle.resize(original, by: CGPoint(x: p.x - start.x, y: p.y - start.y)).intersection(bounds)
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
        case .drawing:
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
        if textEditor != nil {
            commitText()
        } else if !hasSelection {
            session?.cancel()
        } else if selectedID != nil {
            select(nil)
        } else if mode == .pinEdit {
            return
        } else if tool != nil {
            setTool(nil)
        } else if items.isEmpty, case .none = translationState {
            resetSelection()
            primeCursor()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard hasSelection, let tool = textEditor != nil ? .text : selectedTool ?? tool else { return }
        if tool == .mosaic {
            let brush = item(selectedID).map { $0.shape.isMosaicBrush } ?? (StyleMemory.mosaicMode == .brush)
            guard brush else { return }
        }
        scrollAccumulator += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 6 : event.scrollingDeltaY
        guard abs(scrollAccumulator) >= 1 else { return }
        let steps = scrollAccumulator.rounded(.towardZero)
        scrollAccumulator -= steps
        let unit: CGFloat = tool == .mosaic || tool == .text || tool == .number ? 2 : 1
        let current = currentStyle?.size ?? tool.defaultSize
        applyStyle(.size(current + steps * unit), coalesce: true)
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
            invalidate(item.bounds, margin: 16)
            // A number is usually followed by its explanation, so start typing right beside it.
            beginTextEditing(at: CGPoint(x: p.x + size / 2 + 6, y: p.y))
            captionedNumberID = item.id
        case .pen:
            draft = AnnotationItem(shape: .pen([p]), color: color, size: size, style: style)
            drag = .drawing(p)
        case .magnifier:
            draft = AnnotationItem(shape: .magnifier(source: p, target: p, radius: 0), color: color, size: size)
            drag = .drawing(p)
        case .mosaic:
            let effect = StyleMemory.mosaicEffect
            if StyleMemory.mosaicMode == .brush {
                let item = AnnotationItem(shape: .mosaicBrush([p]), color: color, size: size, effect: effect)
                draft = item
                invalidate(item.bounds)
            } else {
                draft = AnnotationItem(shape: .mosaicRect(CGRect(origin: p, size: .zero)), color: color, size: size, effect: effect)
            }
            drag = .drawing(p)
        case .rectangle:
            draft = AnnotationItem(shape: .rectangle(CGRect(origin: p, size: .zero)), color: color, size: size, style: style)
            drag = .drawing(p)
        case .arrow:
            draft = AnnotationItem(shape: .arrow(p, p), color: color, size: size, style: style)
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
        case var .mosaicBrush(points):
            if let last = points.last, hypot(p.x - last.x, p.y - last.y) >= 1 { points.append(p) }
            item.shape = .mosaicBrush(points)
        case .rectangle, .mosaicRect:
            var end = p
            if shift {
                let side = max(abs(p.x - start.x), abs(p.y - start.y))
                end = CGPoint(x: start.x + (p.x >= start.x ? side : -side), y: start.y + (p.y >= start.y ? side : -side))
            }
            let r = CGRect(corners: start, end)
            if case .rectangle = item.shape { item.shape = .rectangle(r) } else { item.shape = .mosaicRect(r) }
        case .arrow:
            var end = p
            if shift {
                // Snap to 45° steps.
                let angle = (atan2(p.y - start.y, p.x - start.x) / (.pi / 4)).rounded() * (.pi / 4)
                let length = hypot(p.x - start.x, p.y - start.y)
                end = CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
            }
            item.shape = .arrow(start, end)
        case .magnifier:
            let radius = hypot(p.x - start.x, p.y - start.y)
            item.shape = .magnifier(source: start, target: AnnotationItem.lensCenter(source: start, radius: radius, in: selection), radius: radius)
        case .text, .number:
            break
        }
        draft = item
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
        if let id = captionedNumberID, text.isEmpty, items.contains(where: { $0.id == id }) {
            selectedID = id
        }
        captionedNumberID = nil
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
                          mosaicMode: StyleMemory.mosaicMode, mosaicEffect: StyleMemory.mosaicEffect,
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
        var clampedSize: CGFloat?
        if case let .size(value) = action {
            let range = styleTool.sizeRange
            clampedSize = min(max(value, range.lowerBound), range.upperBound)
        }

        // Remember the choice for the next annotation of this kind.
        switch action {
        case .size: StyleMemory.sizes[styleTool] = clampedSize
        case let .color(c): StyleMemory.setColor(c, for: styleTool)
        case let .mosaicMode(m): StyleMemory.mosaicMode = m
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

        guard hasSelection else {
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
            finish(.apply)
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
        if let action = ToolbarAction.action(forKey: key) {
            handle(action)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        handleEscape()
    }

    /// Esc steps back one level at a time; it only closes the capture when there is nothing left to back out of.
    private func handleEscape() {
        if textEditor != nil {
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
        }
        shiftDown = shift
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
            topBar.setSize(sizeRect.size)
            var top = CGPoint(x: sizeRect.minX, y: sizeRect.minY - topBar.frame.height - 6)
            if top.y < 4 { top.y = sizeRect.minY + 6 }
            top.x = min(max(4, top.x), bounds.maxX - topBar.frame.width - 4)
            topBar.setFrameOrigin(top)
        }

        if mode == .pinEdit { topBar.isHidden = true }
        toolbar.isHidden = !hasSelection || isAdjustingSelection
        if !hasSelection { ocrPanel.isHidden = true }
        let style = currentStyle
        styleBar.isHidden = toolbar.isHidden || style == nil
        guard hasSelection else {
            positionToast()
            return
        }

        // Under the selection; without room there, a column beside it (right, then left); failing both,
        // a row above it, then a column inside its right edge, then a row inside its bottom edge.
        let flat = toolbar.horizontalSize, column = toolbar.verticalSize
        var bar = CGPoint(x: selection.maxX - flat.width, y: selection.maxY + 8)
        var below = true
        var side: PanelView.CaretEdge? = nil
        var inside = false
        if bar.y + flat.height > bounds.maxY - 4 {
            let aboveTop = topBar.frame.minY < selection.minY ? topBar.frame.minY : selection.minY
            if column.height <= bounds.height - 8 {
                if selection.maxX + 8 + column.width <= bounds.maxX - 4 {
                    side = .right
                } else if selection.minX - 8 - column.width >= 4 {
                    side = .left
                } else if aboveTop - flat.height - 8 < 4, selection.width > column.width * 3 {
                    side = .right
                    inside = true
                }
            }
            if let side {
                bar.x = inside ? selection.maxX - 8 - column.width
                    : side == .right ? selection.maxX + 8 : selection.minX - 8 - column.width
                // Bottom-aligned with the selection, like the horizontal bar hangs off its bottom-right corner.
                bar.y = min(max(4, selection.maxY - column.height), bounds.maxY - column.height - 4)
            } else {
                bar.y = aboveTop - flat.height - 8
                below = false
                if bar.y < 4 {
                    bar.y = selection.maxY - flat.height - 8
                    below = true
                }
            }
        }
        if toolbar.isVertical != (side != nil) { toolbar.setVertical(side != nil) }
        let size = toolbar.frame.size
        if side == nil { bar.x = min(max(4, bar.x), bounds.maxX - size.width - 4) }
        toolbar.setFrameOrigin(bar)

        if let style, !styleBar.isHidden {
            let icon = toolbar.anchor(for: style.tool) ?? CGPoint(x: size.width / 2, y: size.height / 2)
            if let side {
                // Beside the column, on the selection side, with the caret pointing at the tool.
                styleBar.caret = (side == .right ? .right : .left, 0)
                styleBar.configure(style)
                let styleSize = styleBar.frame.size
                let x = side == .right ? bar.x - styleSize.width - 4 : bar.x + size.width + 4
                let anchor = bar.y + icon.y
                let y = min(max(4, anchor - styleSize.height / 2), bounds.maxY - styleSize.height - 4)
                styleBar.setFrameOrigin(CGPoint(x: min(max(4, x), bounds.maxX - styleSize.width - 4), y: y))
                styleBar.caret = (side == .right ? .right : .left, anchor - y)
            } else {
                // Put the style bar next to the toolbar with a caret pointing at the tool it configures.
                var styleBelow = below
                let expectedHeight: CGFloat = 42
                if styleBelow, bar.y + size.height + 4 + expectedHeight > bounds.maxY - 4 { styleBelow = false }
                if !styleBelow, bar.y - 4 - expectedHeight < 4 { styleBelow = true }
                styleBar.caret = (styleBelow ? .top : .bottom, 0)
                styleBar.configure(style)
                let anchor = bar.x + icon.x
                let styleSize = styleBar.frame.size
                let x = min(max(4, anchor - 26), bounds.maxX - styleSize.width - 4)
                let y = styleBelow ? bar.y + size.height + 4 : bar.y - styleSize.height - 4
                styleBar.setFrameOrigin(CGPoint(x: x, y: y))
                styleBar.caret = (styleBelow ? .top : .bottom, anchor - x)
            }
        }

        // The OCR panel goes beside the selection, clear of a toolbar column there.
        let panel = ocrPanel.frame.size
        let right = side == .right && !inside ? toolbar.frame.maxX : selection.maxX
        let left = side == .left ? toolbar.frame.minX : selection.minX
        var panelOrigin = CGPoint(x: right + 10, y: selection.minY)
        if panelOrigin.x + panel.width > bounds.maxX - 4 { panelOrigin.x = left - panel.width - 10 }
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

    /// Recognizes the selection's text and shows it in an editable panel beside the selection; its button copies it.
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
                ocrPanel.show(text: text, lineCount: result.lines.count)
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

    var testing_ocrText: String? { ocrPanel.isHidden ? nil : ocrPanel.textView.string }

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
            showToast("还没有填写 API Key。请按 Esc 退出截图，在菜单栏 Shotlate → 设置 中填写。", duration: 5)
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
                showToast(missing > 0 ? "已翻译 \(laidOut.count) 段，\(missing) 段没有返回译文" : "已翻译 \(laidOut.count) 段 · Y 切换原文",
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
    func exportImage() -> NSBitmapImageRep? {
        Exporter.render(renderer: renderer, selection: selection, scale: scale, items: items, translation: visibleTranslation)
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
        guard hasSelection, let frame = selectionOnScreen, let rep = exportImage() else { return }
        StyleMemory.lastSelection[displayID] = selection
        session?.finish()
        PinManager.shared.pin(rep, frame: frame)
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
        guard let rep = exportImage() else {
            showToast("导出图片失败")
            return
        }
        switch output {
        case .copy:
            Exporter.copy(rep)
        case .save, .saveAs:
            let settings = Settings.shared
            _ = try? Exporter.save(rep, format: settings.imageFormat, directory: settings.saveDirectory)
        case .apply:
            break
        }
        session?.applyPinEdit(rep)
    }

    private func finish(_ output: OutputAction) {
        commitText()
        endChange()
        guard hasSelection, selection.width >= 1, selection.height >= 1 else { return }
        if mode == .pinEdit {
            finishPinEdit(output)
            return
        }
        StyleMemory.lastSelection[displayID] = selection
        let output: OutputAction = output == .apply ? .copy : output
        let settings = Settings.shared
        let format: ImageFormat = output == .copy ? .png : settings.imageFormat
        guard let rep = exportImage() else {
            showToast("导出图片失败")
            return
        }
        let screen = window?.screen
        switch output {
        case .copy:
            Exporter.copy(rep)
            session?.finish()
            HUD.show("已复制到剪贴板", on: screen)
        case .save:
            do {
                let url = try Exporter.save(rep, format: format, directory: settings.saveDirectory)
                session?.finish()
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
