import CoreGraphics
import Foundation

public struct RGBA: Equatable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Relative luminance in 0...1 (sRGB coefficients, no gamma correction; good enough to pick black or white).
    public var luminance: Double {
        (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255
    }

    func distance(to other: RGBA) -> Int {
        abs(Int(r) - Int(other.r)) + abs(Int(g) - Int(other.g)) + abs(Int(b) - Int(other.b))
    }

    public static let black = RGBA(r: 0, g: 0, b: 0)
    public static let white = RGBA(r: 255, g: 255, b: 255)
}

/// Opaque RGBA8 pixels with a top-left origin.
public struct PixelBuffer: Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let data: [UInt8]

    public init(width: Int, height: Int, bytesPerRow: Int, data: [UInt8]) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.data = data
    }

    /// Renders `image` into an sRGB RGBA8 buffer so pixels can be read directly.
    public init?(image: CGImage) {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, bytesPerRow: bytesPerRow, data: data)
    }

    public func pixel(x: Int, y: Int) -> RGBA {
        let i = y * bytesPerRow + x * 4
        return RGBA(r: data[i], g: data[i + 1], b: data[i + 2])
    }
}

public struct SampledColors: Equatable, Sendable {
    public var background: RGBA
    public var foreground: RGBA
    /// Share of pixels inside the rect that belong to the text strokes.
    public var inkCoverage: Double
    /// Average horizontal stroke thickness in pixels; relative to the line height it indicates weight.
    public var strokeWidth: Double = 0
    /// Horizontal space between the rect and the edge of its background container, in pixels,
    /// or nil when the background runs to the image edge on that side.
    public var leftMargin: Int?
    public var rightMargin: Int?

    /// Text that sits in the middle of its container (a button, a centered title) should stay centered.
    public var isCentered: Bool {
        guard let l = leftMargin, let r = rightMargin else { return false }
        return abs(l - r) <= max(6, (l + r) / 5)
    }
}

public enum ColorSampler {
    /// Samples the text and background colors of the text inside `rect` (pixel coordinates, top-left origin).
    ///
    /// The background is the per-channel median of a ring of pixels just outside the rect,
    /// which is less affected by anti-aliased glyph edges than an average.
    /// The foreground is the average of the pixels inside the rect that differ most from it.
    public static func sample(_ buffer: PixelBuffer, rect: CGRect, ring: Int = 2) -> SampledColors {
        let inner = clamp(rect.integral, buffer)
        let outer = clamp(rect.integral.insetBy(dx: -CGFloat(ring), dy: -CGFloat(ring)), buffer)
        guard inner.width > 0, inner.height > 0 else {
            return SampledColors(background: .white, foreground: .black, inkCoverage: 0)
        }

        var ringPixels: [RGBA] = []
        for y in Int(outer.minY)..<Int(outer.maxY) {
            for x in Int(outer.minX)..<Int(outer.maxX) where !inner.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                ringPixels.append(buffer.pixel(x: x, y: y))
            }
        }
        if ringPixels.isEmpty {
            // The rect touches every edge of the image: fall back to its own border pixels.
            for x in Int(inner.minX)..<Int(inner.maxX) {
                ringPixels.append(buffer.pixel(x: x, y: Int(inner.minY)))
                ringPixels.append(buffer.pixel(x: x, y: Int(inner.maxY) - 1))
            }
        }
        let background = median(ringPixels)

        var inside: [(RGBA, Int)] = []
        inside.reserveCapacity(Int(inner.width * inner.height))
        for y in Int(inner.minY)..<Int(inner.maxY) {
            for x in Int(inner.minX)..<Int(inner.maxX) {
                let p = buffer.pixel(x: x, y: y)
                inside.append((p, p.distance(to: background)))
            }
        }
        let strokeWidth = averageInkRun(buffer, inner, background)
        let (leftMargin, rightMargin) = margins(buffer, inner, background)

        inside.sort { $0.1 > $1.1 }
        let inkCount = inside.filter { $0.1 > 90 }.count
        let top = inside.prefix(max(1, inside.count * 15 / 100))
        var foreground = average(top.map(\.0))

        // Low contrast (e.g. blurry or empty rect): use black or white, whichever reads on the background.
        if abs(foreground.luminance - background.luminance) < 0.3 {
            foreground = background.luminance > 0.5 ? .black : .white
        }
        return SampledColors(background: background, foreground: foreground,
                             inkCoverage: Double(inkCount) / Double(inside.count), strokeWidth: strokeWidth,
                             leftMargin: leftMargin, rightMargin: rightMargin)
    }

    /// Mean length of horizontal runs of "ink" pixels, i.e. the typical stem thickness.
    static func averageInkRun(_ buffer: PixelBuffer, _ rect: CGRect, _ background: RGBA) -> Double {
        var runs = 0
        var total = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            var run = 0
            for x in Int(rect.minX)..<Int(rect.maxX) {
                if buffer.pixel(x: x, y: y).distance(to: background) > 150 {
                    run += 1
                } else if run > 0 {
                    runs += 1
                    total += run
                    run = 0
                }
            }
            if run > 0 {
                runs += 1
                total += run
            }
        }
        return runs == 0 ? 0 : Double(total) / Double(runs)
    }

    /// Scans left and right from the rect along its middle row until the background color ends.
    static func margins(_ buffer: PixelBuffer, _ rect: CGRect, _ background: RGBA) -> (Int?, Int?) {
        let y = Int(rect.midY)
        func scan(from start: Int, step: Int) -> Int? {
            var x = start
            var distance = 0
            while x >= 0, x < buffer.width {
                if buffer.pixel(x: x, y: y).distance(to: background) > 60 { return distance }
                x += step
                distance += 1
            }
            return nil
        }
        return (scan(from: Int(rect.minX) - 1, step: -1), scan(from: Int(rect.maxX), step: 1))
    }

    static func clamp(_ rect: CGRect, _ buffer: PixelBuffer) -> CGRect {
        rect.intersection(CGRect(x: 0, y: 0, width: buffer.width, height: buffer.height))
    }

    static func median(_ pixels: [RGBA]) -> RGBA {
        guard !pixels.isEmpty else { return .white }
        func mid(_ values: [UInt8]) -> UInt8 { values.sorted()[values.count / 2] }
        return RGBA(r: mid(pixels.map(\.r)), g: mid(pixels.map(\.g)), b: mid(pixels.map(\.b)))
    }

    static func average(_ pixels: [RGBA]) -> RGBA {
        guard !pixels.isEmpty else { return .black }
        let n = pixels.count
        return RGBA(r: UInt8(pixels.reduce(0) { $0 + Int($1.r) } / n),
                    g: UInt8(pixels.reduce(0) { $0 + Int($1.g) } / n),
                    b: UInt8(pixels.reduce(0) { $0 + Int($1.b) } / n))
    }
}
