import CoreGraphics
import Foundation

/// Builds a long screenshot from successive frames of a region that is being scrolled.
///
/// Each row is reduced to a signature: the average brightness of 48 column bands. Screen captures
/// jitter by a level or two between frames, so rows are compared with a tolerance instead of
/// exact hashes. Rows that stay put at the top and bottom (sticky headers, toolbars) are treated as
/// fixed; in the band between them every candidate offset is scored by how many detailed rows
/// (text, edges) line up.
///
/// Rows are committed only up to a safety margin above the bottom of the moving band; the rest of
/// the newest frame (the last content rows plus any footer) is kept as a replaceable tail. Rounded
/// window corners, shadows or floating buttons at the bottom edge therefore never end up in the
/// middle of the long image, even when the detected footer size changes from frame to frame.
public final class ScrollStitcher {
    public enum Result: Equatable {
        case started
        case appended(Int)
        case unchanged
        case scrolledBack
        case noOverlap
        case limitReached
    }

    public let maxHeight: Int
    /// Columns at the right edge left out of matching; overlay scroll bars change there on every frame.
    public let ignoredRightColumns: Int
    public private(set) var width = 0
    /// Committed row-major RGBA bytes, one chunk per appended slice. Keeping slices separate lets
    /// previews be drawn without copying the whole image.
    private var chunks: [[UInt8]] = []
    private var committedHeight = 0
    /// Rows `edge..<frameHeight` of the newest frame, shown after the committed rows.
    private var tail: [UInt8] = []
    /// Row of the newest frame where the committed image ends.
    private var edge = 0
    private var previous: [UInt8] = []

    public var height: Int { width == 0 ? 0 : committedHeight + tail.count / (width * 4) }

    static let bands = 48
    static let tolerance = 4
    private var frameHeight = 0

    public init(maxHeight: Int = 60_000, ignoredRightColumns: Int = 0) {
        self.maxHeight = maxHeight
        self.ignoredRightColumns = ignoredRightColumns
    }

    /// Rows kept out of the committed image at the bottom of the moving band.
    static func safetyMargin(_ frameHeight: Int) -> Int { min(24, frameHeight / 10) }

    public func add(_ frame: PixelBuffer) -> Result {
        let signatures = rowSignatures(frame)
        let h = frame.height
        let margin = Self.safetyMargin(h)
        guard width == frame.width, frameHeight == h, !previous.isEmpty else {
            width = frame.width
            frameHeight = h
            edge = h - margin
            chunks = [rows(frame, 0..<edge)]
            committedHeight = edge
            tail = rows(frame, edge..<h)
            previous = signatures
            return .started
        }

        let same = (0..<h).filter { Self.rowsMatch(previous, $0, signatures, $0) }.count
        if same >= h - max(1, h / 100) { return .unchanged }

        // Fixed rows at the top and bottom, capped so blank content is not mistaken for a toolbar.
        let cap = h * 35 / 100
        var top = 0
        while top < cap, Self.rowsMatch(previous, top, signatures, top) { top += 1 }
        var bottom = 0
        while bottom < cap, Self.rowsMatch(previous, h - 1 - bottom, signatures, h - 1 - bottom) { bottom += 1 }
        let band = top..<(h - bottom)
        guard band.count >= 16 else { return .unchanged }

        guard let d = Self.offset(previous: previous, new: signatures, band: band) else { return .noOverlap }
        if d == 0 { return .unchanged }
        if d < 0 { return .scrolledBack }

        // Where the committed image ends, in the new frame's rows; everything from there is new.
        let start = edge - d
        guard start >= band.lowerBound else { return .noOverlap }
        let end = max(start, band.upperBound - margin)
        guard committedHeight + (end - start) + (h - end) <= maxHeight else { return .limitReached }

        if end > start {
            chunks.append(rows(frame, start..<end))
            committedHeight += end - start
        }
        edge = end
        tail = rows(frame, end..<h)
        previous = signatures
        return .appended(d)
    }

    /// Explains how two frames compare; for debugging stitching failures.
    public func diagnose(_ a: PixelBuffer, _ b: PixelBuffer) -> String {
        let sa = rowSignatures(a), sb = rowSignatures(b)
        let h = a.height, cap = h * 35 / 100
        var top = 0
        while top < cap, Self.rowsMatch(sa, top, sb, top) { top += 1 }
        var bottom = 0
        while bottom < cap, Self.rowsMatch(sa, h - 1 - bottom, sb, h - 1 - bottom) { bottom += 1 }
        let band = top..<(h - bottom)
        let detailed = Self.detailedRows(sb, band: band)
        let offset = Self.offset(previous: sa, new: sb, band: band)
        return "size \(a.width)x\(a.height) fixed top \(top) bottom \(bottom) band \(band.count) detailed \(detailed.count) offset \(offset.map(String.init) ?? "none")"
    }

    static func rowsMatch(_ a: [UInt8], _ i: Int, _ b: [UInt8], _ j: Int) -> Bool {
        let ai = i * bands, bj = j * bands
        for k in 0..<bands where abs(Int(a[ai + k]) - Int(b[bj + k])) > tolerance { return false }
        return true
    }

    /// Rows with visible detail (text, icons, edges). Flat rows of background say nothing about where the content moved.
    static func detailedRows(_ signatures: [UInt8], band: Range<Int>) -> [Int] {
        band.filter { row in
            let slice = signatures[(row * bands)..<((row + 1) * bands)]
            return Int(slice.max()!) - Int(slice.min()!) >= 6
        }
    }

    /// Scroll offset in rows (positive when the content moved up), or nil when the frames don't overlap enough.
    ///
    /// Every candidate offset is scored by how many detailed rows of the new frame reappear in the
    /// previous one at that offset. Scoring all offsets (instead of trusting the most common row match)
    /// keeps lists of near-identical rows, such as chat logs or tables, from locking onto a false period.
    static func offset(previous: [UInt8], new: [UInt8], band: Range<Int>) -> Int? {
        let detailed = detailedRows(new, band: band)
        guard detailed.count >= 4 else { return nil }
        let minimumCompared = max(4, detailed.count / 5)
        let limit = band.count - 8
        guard limit > 0 else { return nil }

        var best: (d: Int, score: Double)?
        for d in -limit...limit {
            var compared = 0
            var matched = 0
            for i in detailed {
                let j = i + d
                guard j >= band.lowerBound, j < band.upperBound else { continue }
                compared += 1
                if rowsMatch(previous, j, new, i) { matched += 1 }
            }
            guard compared >= minimumCompared else { continue }
            let score = Double(matched) / Double(compared)
            // Near-ties go to the smaller movement: frames are captured often, so real scrolls are short.
            if best == nil || score > best!.score + 0.02 || (abs(score - best!.score) <= 0.02 && abs(d) < abs(best!.d)) {
                best = (d, score)
            }
        }
        guard let best, best.score >= 0.85 else { return nil }
        return best.d
    }

    /// Per row, the average brightness of `bands` equal column bands, leaving out the ignored right edge.
    func rowSignatures(_ frame: PixelBuffer) -> [UInt8] {
        let bands = Self.bands
        let columns = max(bands, frame.width - ignoredRightColumns)
        var out = [UInt8](repeating: 0, count: frame.height * bands)
        frame.data.withUnsafeBufferPointer { bytes in
            for y in 0..<frame.height {
                let start = y * frame.bytesPerRow
                for k in 0..<bands {
                    let x0 = k * columns / bands, x1 = max(x0 + 1, (k + 1) * columns / bands)
                    var sum = 0
                    for x in x0..<x1 {
                        let i = start + x * 4
                        sum += Int(bytes[i]) * 2 + Int(bytes[i + 1]) * 5 + Int(bytes[i + 2])
                    }
                    out[y * bands + k] = UInt8(sum / ((x1 - x0) * 8))
                }
            }
        }
        return out
    }

    private func rows(_ frame: PixelBuffer, _ range: Range<Int>) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(range.count * frame.width * 4)
        for y in range {
            let start = y * frame.bytesPerRow
            out += frame.data[start..<(start + frame.width * 4)]
        }
        return out
    }

    /// The stitched image so far.
    public func makeImage() -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        var data = Data(capacity: height * width * 4)
        for chunk in chunks + [tail] { data.append(contentsOf: chunk) }
        return Self.image(data, width: width, height: height)
    }

    /// A scaled-down copy of the stitched image, `targetWidth` pixels wide.
    public func makePreview(targetWidth: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, CGFloat(targetWidth) / CGFloat(width))
        let pw = max(1, Int(CGFloat(width) * scale)), ph = max(1, Int(CGFloat(height) * scale))
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        var y = 0
        for chunk in chunks + [tail] {
            let rows = chunk.count / (width * 4)
            guard rows > 0, let image = Self.image(Data(chunk), width: width, height: rows) else { continue }
            // CG's origin is bottom-left: chunk k sits below everything drawn before it.
            let top = CGFloat(y) * scale
            let h = CGFloat(rows) * scale
            ctx.draw(image, in: CGRect(x: 0, y: CGFloat(ph) - top - h, width: CGFloat(pw), height: h))
            y += rows
        }
        return ctx.makeImage()
    }

    private static func image(_ data: Data, width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Row `y` of the stitched image as raw RGBA bytes (for tests).
    public func row(_ y: Int) -> [UInt8] {
        var y = y
        for chunk in chunks + [tail] {
            let rows = chunk.count / (width * 4)
            if y < rows { return Array(chunk[(y * width * 4)..<((y + 1) * width * 4)]) }
            y -= rows
        }
        return []
    }
}
