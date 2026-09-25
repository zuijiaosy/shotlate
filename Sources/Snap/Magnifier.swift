import AppKit

/// Zoomed pixel view that follows the cursor while choosing or adjusting a selection.
/// Shows the cursor position, the selection size and the color of the pixel under the cursor.
final class MagnifierView: NSView {
    static let cells = 15
    static let cellSize: CGFloat = 8
    static let zoomSide = CGFloat(cells) * cellSize
    static let infoHeight: CGFloat = 50

    private let snapshot: CGImage
    private let pointsPerPixel: CGFloat
    private(set) var pixel = (x: 0, y: 0)
    private(set) var color = (r: 0, g: 0, b: 0)
    var showHex = true { didSet { needsDisplay = true } }
    var sizeText: String? { didSet { needsDisplay = true } }
    private var position = CGPoint.zero

    init(snapshot: CGImage, viewSize: CGSize) {
        self.snapshot = snapshot
        pointsPerPixel = viewSize.width / CGFloat(snapshot.width)
        super.init(frame: CGRect(x: 0, y: 0, width: Self.zoomSide, height: Self.zoomSide + Self.infoHeight))
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var colorString: String {
        showHex ? String(format: "#%02X%02X%02X", color.r, color.g, color.b) : "\(color.r), \(color.g), \(color.b)"
    }

    /// Moves to the cursor at `p` (view points) and samples the pixel under it.
    func update(cursor p: CGPoint, in bounds: CGRect) {
        position = p
        let px = min(max(Int(p.x / pointsPerPixel), 0), snapshot.width - 1)
        let py = min(max(Int(p.y / pointsPerPixel), 0), snapshot.height - 1)
        pixel = (px, py)
        color = samplePixel(x: px, y: py)

        let offset: CGFloat = 20
        var origin = CGPoint(x: p.x + offset, y: p.y + offset)
        if origin.x + frame.width > bounds.maxX - 4 { origin.x = p.x - offset - frame.width }
        if origin.y + frame.height > bounds.maxY - 4 { origin.y = p.y - offset - frame.height }
        setFrameOrigin(origin)
        needsDisplay = true
    }

    private func samplePixel(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        guard let crop = snapshot.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return (0, 0, 0) }
        var data = [UInt8](repeating: 0, count: 4)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return ok ? (Int(data[0]), Int(data[1]), Int(data[2])) : (0, 0, 0)
    }

    override func draw(_ dirtyRect: NSRect) {
        let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor(white: 0.12, alpha: 0.95).setFill()
        outer.fill()

        NSGraphicsContext.saveGraphicsState()
        outer.addClip()
        drawZoom()
        drawZoomOverlay()
        NSGraphicsContext.restoreGraphicsState()
        drawInfo()

        NSColor.white.withAlphaComponent(0.25).setStroke()
        outer.lineWidth = 1
        outer.stroke()
    }

    private func drawZoom() {
        let half = Self.cells / 2
        let wanted = CGRect(x: pixel.x - half, y: pixel.y - half, width: Self.cells, height: Self.cells)
        let available = wanted.intersection(CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height))
        NSColor.black.setFill()
        CGRect(x: 0, y: 0, width: Self.zoomSide, height: Self.zoomSide).fill()
        guard !available.isEmpty, let crop = snapshot.cropping(to: available) else { return }
        let dest = CGRect(x: (available.minX - wanted.minX) * Self.cellSize, y: (available.minY - wanted.minY) * Self.cellSize,
                          width: available.width * Self.cellSize, height: available.height * Self.cellSize)
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: crop, size: available.size).draw(in: dest, from: .zero, operation: .copy, fraction: 1,
                                                          respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
    }

    private func drawZoomOverlay() {
        let side = Self.zoomSide
        let cell = Self.cellSize
        let center = CGFloat(Self.cells / 2) * cell

        // Crosshair through the center row and column.
        selectionBlue.withAlphaComponent(0.28).setFill()
        CGRect(x: 0, y: center, width: side, height: cell).fill()
        CGRect(x: center, y: 0, width: cell, height: side).fill()

        // Faint pixel grid.
        NSColor.white.withAlphaComponent(0.07).setFill()
        for i in 1..<Self.cells {
            CGRect(x: CGFloat(i) * cell, y: 0, width: 0.5, height: side).fill()
            CGRect(x: 0, y: CGFloat(i) * cell, width: side, height: 0.5).fill()
        }

        // Center pixel: dark outer ring and light inner ring so it reads on any color.
        let box = CGRect(x: center, y: center, width: cell, height: cell)
        NSColor.black.setStroke()
        let dark = NSBezierPath(rect: box.insetBy(dx: -1, dy: -1))
        dark.lineWidth = 1.5
        dark.stroke()
        NSColor.white.setStroke()
        let light = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
        light.lineWidth = 1
        light.stroke()

        NSColor.white.withAlphaComponent(0.15).setFill()
        CGRect(x: 0, y: side, width: side, height: 0.5).fill()
    }

    private func drawInfo() {
        let side = Self.zoomSide
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        let secondary: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5), .foregroundColor: NSColor.white.withAlphaComponent(0.55)]
        let primary: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: NSColor.white]

        let position = sizeText ?? "\(Int(self.position.x.rounded())), \(Int(self.position.y.rounded()))"
        NSAttributedString(string: position, attributes: primary).draw(at: CGPoint(x: 8, y: side + 5))

        let swatch = CGRect(x: 8, y: side + 22, width: 11, height: 11)
        NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2).fill()
        NSColor.white.withAlphaComponent(0.5).setStroke()
        NSBezierPath(roundedRect: swatch.insetBy(dx: 0.25, dy: 0.25), xRadius: 2, yRadius: 2).stroke()
        NSAttributedString(string: colorString, attributes: primary).draw(at: CGPoint(x: 24, y: side + 20))

        NSAttributedString(string: "C 复制  ⇧ 切换格式", attributes: secondary).draw(at: CGPoint(x: 8, y: side + 35))
    }
}

/// Multi-line text editor placed directly on the screenshot. Its text origin matches where the
/// finished text annotation is drawn, so committing does not shift the text.
final class TextEditorView: NSTextView {
    var onCommit: () -> Void = {}
    var onResize: () -> Void = {}
    private(set) var wrapWidth: CGFloat

    init(origin: CGPoint, wrapWidth: CGFloat, color: NSColor, size: CGFloat) {
        self.wrapWidth = max(wrapWidth, 40)
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: self.wrapWidth, height: 100_000))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: CGRect(origin: origin, size: CGSize(width: 40, height: size * 1.3)), textContainer: container)
        isRichText = false
        drawsBackground = false
        textContainerInset = .zero
        isHorizontallyResizable = true
        isVerticallyResizable = true
        maxSize = CGSize(width: self.wrapWidth, height: 100_000)
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        focusRingType = .none
        apply(color: color, size: size)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(color: NSColor, size: CGFloat) {
        let attributes = AnnotationItem.textAttributes(color: color, size: size)
        typingAttributes = attributes
        textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: textStorage?.length ?? 0))
        insertionPointColor = color
        fit()
    }

    override func didChangeText() {
        super.didChangeText()
        fit()
    }

    func fit() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let font = (typingAttributes[.font] as? NSFont) ?? .systemFont(ofSize: 20)
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        setFrameSize(CGSize(width: min(wrapWidth, max(used.width + 2, 24)), height: max(used.height, lineHeight)))
        onResize()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 || ((event.keyCode == 36 || event.keyCode == 76) && flags == .command) {
            onCommit()
            return
        }
        super.keyDown(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
