import CoreGraphics
import Foundation

/// Builds a long screenshot from successive frames of a region that is being scrolled.
///
/// Each row is reduced to a signature: the average brightness of 48 column bands, leaving out a few
/// columns at both sides where overlay scroll bars fade in and out. Rows that stay put at the top and
/// bottom (sticky headers, toolbars, an input box with a blinking caret) are treated as fixed. In the
/// band between them, the scroll offset is found by comparing the detailed rows of the previous frame
/// (text, edges) against the new frame at every candidate offset, weighted by how much detail each
/// row has, Comparing by difference instead of
/// exact equality keeps working when browsers scroll by fractions of a pixel and re-render text.
///
/// The first frame is only committed once the content moves, so its footer is known and never ends
/// up in the middle of the long image. After that, rows are committed only up to a safety margin
/// above the bottom of the moving band; the rest of the newest frame (the last content rows plus
/// any footer) is kept as a replaceable tail.
public final class ScrollStitcher {
    public enum Result: Equatable {
        case started
        case appended(Int)
        case unchanged
        case scrolledBack
        case noOverlap
        case limitReached
        /// The frame size changed mid-session (display resolution or scaling); the frame was dropped
        /// and everything stitched so far is kept.
        case sizeChanged
    }

    public let maxHeight: Int
    /// Columns at each side left out of matching; overlay scroll bars change there on every frame.
    public let ignoredSideColumns: Int
    public private(set) var width = 0
    /// How the last frame compared with the one before it; for logs.
    public private(set) var lastDiagnostics = ""
    /// Bumped whenever new frames start being compared against a different frame, so a scroll
    /// accumulator can restart from that frame and not from a rejected one.
    public private(set) var referenceVersion = 0

    /// Committed row-major RGBA bytes in blocks of a few megabytes.
    private var chunks: [[UInt8]] = []
    private var committedHeight = 0
    /// Rows `edge..<frameHeight` of the newest frame, shown after the committed rows.
    private var tail: [UInt8] = []
    /// Row of the newest frame where the committed image ends; meaningless until `first` is flushed.
    private var edge = 0
    /// The first frame, kept whole until the content first moves and its footer is known.
    private var first: PixelBuffer?
    private var previous: Signatures?
    /// Pixels of the frame `previous` was computed from; a byte-identical frame skips signatures entirely.
    private var previousData: [UInt8] = []
    private var frameHeight = 0

    public var height: Int { width == 0 ? 0 : committedHeight + tail.count / (width * 4) }

    static let bands = 48
    static let tolerance = 4
    /// Weighted mean difference per band (0...255) above which an offset is not a match.
    static let maxScore = 2.5
    static let chunkBytes = 8 << 20

    public init(maxHeight: Int = 60_000, ignoredSideColumns: Int = 0) {
        self.maxHeight = maxHeight
        self.ignoredSideColumns = ignoredSideColumns
    }

    /// Rows kept out of the committed image at the bottom of the moving band, so floating buttons and
    /// rounded corners that aren't detected as fixed stay in the replaceable tail.
    static func safetyMargin(_ frameHeight: Int) -> Int { min(120, frameHeight / 8) }

    /// `expectedOffset` is how far the content probably moved, in rows (from scroll events); it only
    /// breaks near-ties between candidate offsets, so a wrong hint never stitches frames that don't match.
    public func add(_ frame: PixelBuffer, expectedOffset: Int? = nil) -> Result {
        let h = frame.height
        if previous != nil, width != frame.width || frameHeight != h {
            // Starting over would silently throw away the long image; keep it and let the caller say so.
            lastDiagnostics = "size \(frame.width)x\(h) differs from \(width)x\(frameHeight), frame dropped"
            return .sizeChanged
        }
        // Idle frames while the user isn't scrolling are usually byte-identical: a memcmp is far cheaper
        // than computing signatures.
        if previous != nil, Self.sameBytes(frame.data, previousData) {
            lastDiagnostics = "identical"
            return .unchanged
        }
        let signatures = self.signatures(frame)
        guard let previous else {
            width = frame.width
            frameHeight = h
            chunks = []
            committedHeight = 0
            first = frame
            tail = rows(frame, 0..<h)
            self.previous = signatures
            previousData = frame.data
            referenceVersion += 1
            lastDiagnostics = "start \(frame.width)x\(h)"
            return .started
        }

        let same = (0..<h).filter { Self.rowsMatch(previous, $0, signatures, $0) }.count
        if same >= h - max(1, h / 100) {
            lastDiagnostics = "same rows \(same)/\(h)"
            return .unchanged
        }

        let (top, bottom) = Self.fixedRows(previous, signatures)
        let band = top..<(h - bottom)
        guard band.count >= 16 else {
            lastDiagnostics = "fixed top \(top) bottom \(bottom), no moving band"
            return .unchanged
        }

        let match = Self.offset(previous: previous, new: signatures, band: band, hint: expectedOffset)
        lastDiagnostics = "fixed top \(top) bottom \(bottom) band \(band.count) " + match.description
        guard let d = match.offset else { return .noOverlap }
        if d == 0 { return .unchanged }
        if d < 0 {
            // While the stitched edge is still in view, follow the content back so the tail shows what is on
            // screen: after a rubber-band bounce at the end of a page, or a small scroll back before stopping.
            if first == nil, edge - d <= band.upperBound {
                edge -= d
                tail = rows(frame, edge..<h)
                self.previous = signatures
                previousData = frame.data
                referenceVersion += 1
            }
            return .scrolledBack
        }

        let margin = Self.safetyMargin(h)
        // The first frame is committed down to where its footer (and the safety margin) starts.
        let flushEnd = max(band.lowerBound, band.upperBound - margin)
        let committedBefore = first == nil ? committedHeight : flushEnd
        let edgeBefore = first == nil ? edge : flushEnd
        // Where the committed image ends, in the new frame's rows; everything from there is new.
        let start = edgeBefore - d
        guard start >= band.lowerBound else {
            lastDiagnostics += ", jumped past the stitched edge"
            return .noOverlap
        }
        let end = max(start, band.upperBound - margin)
        guard committedBefore + (end - start) + (h - end) <= maxHeight else { return .limitReached }

        if let first {
            append(rows(first, 0..<flushEnd))
            self.first = nil
        }
        if end > start { append(rows(frame, start..<end)) }
        edge = end
        tail = rows(frame, end..<h)
        self.previous = signatures
        previousData = frame.data
        referenceVersion += 1
        return .appended(d)
    }

    /// Explains how two frames compare; for debugging stitching failures.
    public func diagnose(_ a: PixelBuffer, _ b: PixelBuffer) -> String {
        let sa = signatures(a), sb = signatures(b)
        let (top, bottom) = Self.fixedRows(sa, sb)
        let band = top..<(a.height - bottom)
        guard band.count >= 16 else { return "size \(a.width)x\(a.height) fixed top \(top) bottom \(bottom), no moving band" }
        return "size \(a.width)x\(a.height) fixed top \(top) bottom \(bottom) band \(band.count) "
            + Self.offset(previous: sa, new: sb, band: band).description
    }

    private static func sameBytes(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        a.count == b.count && a.withUnsafeBytes { x in b.withUnsafeBytes { y in memcmp(x.baseAddress!, y.baseAddress!, a.count) == 0 } }
    }

    private func append(_ bytes: [UInt8]) {
        committedHeight += bytes.count / (width * 4)
        if let last = chunks.indices.last, chunks[last].count + bytes.count <= Self.chunkBytes {
            chunks[last] += bytes
        } else {
            chunks.append(bytes)
        }
    }

    // MARK: Signatures

    struct Signatures {
        let rows: Int
        /// `rows * bands` band averages.
        var values: [UInt8]
        /// Per row, the summed difference between neighbouring bands: how much detail the row has.
        var energy: [Int]
    }

    /// Per row, the average brightness of `bands` equal column bands, leaving out the ignored side columns.
    func signatures(_ frame: PixelBuffer) -> Signatures {
        let bands = Self.bands
        let side = frame.width - 2 * ignoredSideColumns >= bands ? ignoredSideColumns : 0
        let columns = frame.width - 2 * side
        var values = [UInt8](repeating: 0, count: frame.height * bands)
        var energy = [Int](repeating: 0, count: frame.height)
        frame.data.withUnsafeBufferPointer { bytes in
            for y in 0..<frame.height {
                let start = y * frame.bytesPerRow + side * 4
                var previous = -1
                for k in 0..<bands {
                    let x0 = k * columns / bands, x1 = max(x0 + 1, (k + 1) * columns / bands)
                    var sum = 0
                    for x in x0..<x1 {
                        let i = start + x * 4
                        sum += Int(bytes[i]) * 2 + Int(bytes[i + 1]) * 5 + Int(bytes[i + 2])
                    }
                    let v = sum / ((x1 - x0) * 8)
                    values[y * bands + k] = UInt8(v)
                    if previous >= 0 { energy[y] += abs(v - previous) }
                    previous = v
                }
            }
        }
        return Signatures(rows: frame.height, values: values, energy: energy)
    }

    static func rowsMatch(_ a: Signatures, _ i: Int, _ b: Signatures, _ j: Int) -> Bool {
        let ai = i * bands, bj = j * bands
        for k in 0..<bands where abs(Int(a.values[ai + k]) - Int(b.values[bj + k])) > tolerance { return false }
        return true
    }

    /// Fixed rows at the top and bottom: rows that are the same in both frames, allowing a couple of
    /// changed bands for a blinking caret or a hover highlight. Capped so blank content is not mistaken
    /// for a toolbar; overestimating only narrows the band that is searched, never corrupts the image.
    static func fixedRows(_ a: Signatures, _ b: Signatures) -> (top: Int, bottom: Int) {
        func fixed(_ row: Int) -> Bool {
            var changed = 0
            let base = row * bands
            for k in 0..<bands where abs(Int(a.values[base + k]) - Int(b.values[base + k])) > tolerance {
                changed += 1
                if changed > 2 { return false }
            }
            return true
        }
        let h = a.rows, cap = h / 3
        var top = 0
        while top < cap, fixed(top) { top += 1 }
        var bottom = 0
        while bottom < cap, fixed(h - 1 - bottom) { bottom += 1 }
        return (top, bottom)
    }

    // MARK: Offset

    struct Match: CustomStringConvertible {
        var offset: Int?
        var score = Double.infinity
        var candidates = 0
        var templates = 0
        var reason = ""

        var description: String {
            let s = score.isFinite ? String(format: "%.2f", score) : "-"
            return "templates \(templates) offset \(offset.map(String.init) ?? "none") score \(s) candidates \(candidates)" + (reason.isEmpty ? "" : " (\(reason))")
        }
    }

    /// Rows of `sig` in `band` with enough detail to locate, at most `limit` of them spread evenly.
    static func templateRows(_ sig: Signatures, band: Range<Int>, limit: Int) -> [Int] {
        let detailed = band.filter { row in
            let slice = sig.values[(row * bands)..<((row + 1) * bands)]
            return Int(slice.max()!) - Int(slice.min()!) >= 6
        }
        guard detailed.count > limit else { return detailed }
        return (0..<limit).map { detailed[$0 * detailed.count / limit] }
    }

    /// Weighted mean band difference between template rows `t` of `a` and rows `t - d` of `b` inside `band`,
    /// or nil when too little of the template overlaps at that offset.
    static func score(_ a: Signatures, _ b: Signatures, templates: [Int], totalWeight: Int, d: Int, band: Range<Int>) -> Double? {
        var weighted = 0, weight = 0, count = 0
        a.values.withUnsafeBufferPointer { av in
            b.values.withUnsafeBufferPointer { bv in
                for t in templates {
                    let j = t - d
                    guard j >= band.lowerBound, j < band.upperBound else { continue }
                    var diff = 0
                    let ai = t * bands, bj = j * bands
                    for k in 0..<bands { diff += abs(Int(av[ai + k]) - Int(bv[bj + k])) }
                    let w = a.energy[t] + 16
                    weighted += w * diff
                    weight += w
                    count += 1
                }
            }
        }
        guard count >= 4, weight * 5 >= totalWeight else { return nil }
        return Double(weighted) / Double(weight * bands)
    }

    /// Scroll offset in rows (positive when the content moved up), or nil when the frames don't overlap well enough.
    ///
    /// Every offset is scored with a sparse set of template rows; the most promising local minima are
    /// then rescored with all of them. Scoring all offsets (instead of trusting the most common row
    /// match) keeps lists of near-identical rows, such as chat logs or tables, from locking onto a false period.
    static func offset(previous: Signatures, new: Signatures, band: Range<Int>, hint: Int? = nil) -> Match {
        var match = Match()
        let templates = templateRows(previous, band: band, limit: 192)
        match.templates = templates.count
        let limit = band.count - 8
        guard templates.count >= 4, limit > 0 else {
            match.reason = "too little detail"
            return match
        }
        func weight(_ rows: [Int]) -> Int { rows.reduce(0) { $0 + previous.energy[$1] + 16 } }

        let sparse = templates.count > 48 ? (0..<48).map { templates[$0 * templates.count / 48] } : templates
        let sparseWeight = weight(sparse)
        var scores = [Double](repeating: .infinity, count: 2 * limit + 1)
        for d in -limit...limit {
            scores[d + limit] = score(previous, new, templates: sparse, totalWeight: sparseWeight, d: d, band: band) ?? .infinity
        }
        let seeds = scores.indices.filter { i in
            scores[i] <= maxScore * 1.5 && (i == 0 || scores[i - 1] >= scores[i]) && (i == scores.count - 1 || scores[i + 1] >= scores[i])
        }.sorted { scores[$0] < scores[$1] }

        // Rescore the best candidates with every template; a plateau of equal seeds counts once.
        let fullWeight = weight(templates)
        // With repeating rows many seeds tie, so take plenty: cutting off at a handful dropped the real offset.
        var pool: [Int] = []
        for i in seeds where pool.count < 32 {
            let d = i - limit
            guard !pool.contains(where: { abs($0 - d) <= 3 }) else { continue }
            pool.append(d)
        }
        // The hint is only a tie-breaker for scoring, but it must be in the pool: with repeating
        // content the true offset can sit a hair away from the hint and lose the deduplication above.
        if let hint {
            let d = min(max(hint, -limit), limit)
            if !pool.contains(where: { abs($0 - d) <= 3 }) { pool.append(d) }
        }
        var minima: [(d: Int, s: Double)] = []
        for d in pool {
            guard let s = score(previous, new, templates: templates, totalWeight: fullWeight, d: d, band: band) else { continue }
            minima.append((d, s))
        }
        minima.sort { $0.s < $1.s }
        match.score = minima.first?.s ?? scores.min() ?? .infinity
        minima.removeAll { $0.s > maxScore }
        guard let best = minima.first else {
            match.reason = "no offset below \(maxScore)"
            return match
        }
        // Near-ties (repeating rows in lists and chats) go to the offset closest to the scroll hint, or
        // else to the smaller movement: frames are captured often, so real scrolls are short.
        let ties = minima.filter { $0.s <= best.s * 1.5 + 1.5 }
        let target = hint ?? 0
        let chosen = ties.min { abs($0.d - target) != abs($1.d - target) ? abs($0.d - target) < abs($1.d - target) : $0.s < $1.s }!
        match.offset = chosen.d
        match.score = chosen.s
        match.candidates = ties.count
        return match
    }

    // MARK: Output

    private func rows(_ frame: PixelBuffer, _ range: Range<Int>) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(range.count * frame.width * 4)
        for y in range {
            let start = y * frame.bytesPerRow
            out += frame.data[start..<(start + frame.width * 4)]
        }
        return out
    }

    /// The stitched image so far. The image reads straight from the stitched chunks instead of a joined
    /// copy, which for a long, wide capture would double the memory at the moment it is needed most.
    /// The chunks are captured by value, so stitching more frames afterwards doesn't change the image.
    public func makeImage() -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let source = ChunkedBytes(chunks.filter { !$0.isEmpty } + (tail.isEmpty ? [] : [tail]))
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0,
            getBytePointer: nil,
            releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, position, count in
                Unmanaged<ChunkedBytes>.fromOpaque(info!).takeUnretainedValue().copy(into: buffer, from: Int(position), count: count)
            },
            releaseInfo: { info in Unmanaged<ChunkedBytes>.fromOpaque(info!).release() })
        guard let provider = CGDataProvider(directInfo: Unmanaged.passRetained(source).toOpaque(),
                                            size: off_t(source.count), callbacks: &callbacks) else { return nil }
        return Self.image(provider, width: width, height: height)
    }

    /// The bottom of the stitched image scaled to `targetWidth` pixels, at most `maxHeight` pixels tall.
    /// Only the rows that fit are drawn, so the cost doesn't grow with the length of the image.
    public func makePreview(targetWidth: Int, maxHeight: Int = .max) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, CGFloat(targetWidth) / CGFloat(width))
        let pw = max(1, Int(CGFloat(width) * scale))
        let ph = max(1, min(maxHeight, Int(CGFloat(height) * scale)))
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        // Walk up from the bottom; CG's origin is bottom-left, so the newest rows are drawn at y = 0.
        let needed = Int((CGFloat(ph) / scale).rounded(.up))
        var drawn = 0
        let rowBytes = width * 4
        for chunk in ([tail] + chunks.reversed()) where drawn < needed {
            let rows = chunk.count / rowBytes
            guard rows > 0 else { continue }
            let take = min(rows, needed - drawn)
            let slice = Data(chunk[((rows - take) * rowBytes)...])
            guard let image = Self.image(slice, width: width, height: take) else { continue }
            ctx.draw(image, in: CGRect(x: 0, y: CGFloat(drawn) * scale, width: CGFloat(pw), height: CGFloat(take) * scale))
            drawn += take
        }
        return ctx.makeImage()
    }

    private static func image(_ data: Data, width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return image(provider, width: width, height: height)
    }

    private static func image(_ provider: CGDataProvider, width: Int, height: Int) -> CGImage? {
        CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
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

/// Byte chunks read as one contiguous range, for a direct-access data provider.
private final class ChunkedBytes {
    let chunks: [[UInt8]]
    let starts: [Int]
    let count: Int

    init(_ chunks: [[UInt8]]) {
        self.chunks = chunks
        var starts = [Int](), total = 0
        for chunk in chunks {
            starts.append(total)
            total += chunk.count
        }
        self.starts = starts
        count = total
    }

    func copy(into buffer: UnsafeMutableRawPointer, from position: Int, count wanted: Int) -> Int {
        guard position < count else { return 0 }
        // Last chunk starting at or before `position`.
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= position { lo = mid } else { hi = mid - 1 }
        }
        var copied = 0, index = lo, offset = position - starts[lo]
        let total = min(wanted, count - position)
        while copied < total {
            let chunk = chunks[index]
            let n = min(chunk.count - offset, total - copied)
            chunk.withUnsafeBytes { (buffer + copied).copyMemory(from: $0.baseAddress! + offset, byteCount: n) }
            copied += n
            index += 1
            offset = 0
        }
        return copied
    }
}
