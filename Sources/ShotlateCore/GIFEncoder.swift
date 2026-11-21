import Foundation

/// Writes an animated GIF frame by frame, holding only the previous frame in memory, so a recording's
/// memory use doesn't grow with its length.
///
/// Built for screen recordings: a frame identical to the previous one is merged into its delay, and each
/// frame stores only the rectangle that changed, with unchanged pixels in it left transparent. Frames
/// with at most 255 distinct colors (most UI) are stored exactly; others are reduced with median cut and
/// no dithering, so that still areas don't shimmer from frame to frame.
public final class GIFEncoder {
    public enum Failure: Error {
        case invalidSize
        case noFrames
    }

    public let width: Int
    public let height: Int
    /// Distinct frames so far; merged duplicates don't count.
    public private(set) var frameCount = 0
    /// Bytes produced so far, including what is still buffered.
    public var byteCount: Int { flushed + out.count + (pending?.data.count ?? 0) }

    private let sink: (Data) throws -> Void
    private var out = Data()
    private var flushed = 0
    private var previous: [UInt32] = []
    /// The newest frame, written once the next frame's time gives its delay.
    private var pending: EncodedFrame?
    private var startTime = 0.0
    /// Total delay of the frames written so far, i.e. where the pending frame starts, in centiseconds.
    private var writtenCentiseconds = 0
    private var isFinished = false
    private var lzw = LZWEncoder()

    struct EncodedFrame {
        var transparentIndex: UInt8?
        var data: Data
    }

    struct Rect: Equatable {
        var x, y, width, height: Int
    }

    /// `sink` receives the file in order, in chunks; an error it throws is passed on to the caller.
    public init(width: Int, height: Int, sink: @escaping (Data) throws -> Void) throws {
        guard width > 0, height > 0, width <= 0xFFFF, height <= 0xFFFF else { throw Failure.invalidSize }
        self.width = width
        self.height = height
        self.sink = sink
        out.append(contentsOf: Array("GIF89a".utf8))
        appendUInt16(width)
        appendUInt16(height)
        out.append(contentsOf: [0, 0, 0] as [UInt8]) // no global color table; every frame has its own
        // Loop forever.
        out.append(contentsOf: [0x21, 0xFF, 0x0B] as [UInt8])
        out.append(contentsOf: Array("NETSCAPE2.0".utf8))
        out.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00] as [UInt8])
    }

    /// Adds a frame shown from `time` (seconds, on any clock that doesn't go back) until the next one.
    /// `pixels` holds `width * height` pixels row by row as 32-bit BGRA (`kCVPixelFormatType_32BGRA`, so
    /// each value reads 0xAARRGGBB); alpha is ignored. Returns false when the frame matched the previous one.
    @discardableResult
    public func add(_ pixels: [UInt32], time: Double) throws -> Bool {
        precondition(pixels.count == width * height, "frame size")
        guard !isFinished else { return false }
        let rect: Rect
        if previous.isEmpty {
            startTime = time
            rect = Rect(x: 0, y: 0, width: width, height: height)
        } else {
            guard let changed = changedRect(pixels) else { return false }
            rect = changed
        }
        let frame = encodeFrame(pixels, rect: rect, transparentUnchanged: !previous.isEmpty)
        if let pending { try write(pending, until: time) }
        pending = frame
        previous = pixels
        frameCount += 1
        return true
    }

    /// Writes the last frame, shown until `endTime`, and the trailer. Throws `noFrames` if nothing was added.
    public func finish(endTime: Double) throws {
        guard !isFinished else { return }
        isFinished = true
        guard let pending else { throw Failure.noFrames }
        try write(pending, until: endTime)
        self.pending = nil
        out.append(0x3B)
        try flush(force: true)
    }

    // MARK: Frames

    private func write(_ frame: EncodedFrame, until time: Double) throws {
        let end = Int(((time - startTime) * 100).rounded())
        // Most viewers show delays under 2 cs as 10 cs, so never go below 2; the next delay makes up for it.
        let delay = min(0xFFFF, max(2, end - writtenCentiseconds))
        writtenCentiseconds += delay
        // Graphic control extension: disposal "leave in place", so the next frame draws over this one.
        let flags: UInt8 = 1 << 2 | (frame.transparentIndex == nil ? 0 : 1)
        out.append(contentsOf: [0x21, 0xF9, 0x04, flags, UInt8(delay & 0xFF), UInt8(delay >> 8),
                                frame.transparentIndex ?? 0, 0x00] as [UInt8])
        out.append(frame.data)
        try flush(force: false)
    }

    private func flush(force: Bool) throws {
        guard force || out.count >= 1 << 18, !out.isEmpty else { return }
        try sink(out)
        flushed += out.count
        out.removeAll(keepingCapacity: true)
    }

    /// The smallest rectangle holding every pixel that differs from the previous frame; nil if none does.
    func changedRect(_ pixels: [UInt32]) -> Rect? {
        let width = self.width
        var minX = width, maxX = -1, minY = -1, maxY = -1
        pixels.withUnsafeBufferPointer { cur in
            previous.withUnsafeBufferPointer { prev in
                for y in 0..<height {
                    let row = y * width
                    var x = 0
                    while x < width, (cur[row + x] ^ prev[row + x]) & 0xFFFFFF == 0 { x += 1 }
                    guard x < width else { continue }
                    if minY < 0 { minY = y }
                    maxY = y
                    minX = min(minX, x)
                    var last = width - 1
                    while (cur[row + last] ^ prev[row + last]) & 0xFFFFFF == 0 { last -= 1 }
                    maxX = max(maxX, last)
                }
            }
        }
        guard maxY >= 0 else { return nil }
        return Rect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Image descriptor, local color table and LZW data for `rect` of `pixels`.
    func encodeFrame(_ pixels: [UInt32], rect: Rect, transparentUnchanged: Bool) -> EncodedFrame {
        // With transparency, index 0 is reserved for "unchanged", even if every pixel changed.
        let base = transparentUnchanged ? 1 : 0
        var indices = [UInt8](repeating: 0, count: rect.width * rect.height)
        let palette = exactPalette(pixels, rect: rect, base: base, transparentUnchanged: transparentUnchanged, indices: &indices)
            ?? quantizedPalette(pixels, rect: rect, base: base, transparentUnchanged: transparentUnchanged, indices: &indices)

        let colors = base + palette.count
        var bits = 1
        while 1 << bits < colors { bits += 1 }
        var data = Data()
        data.reserveCapacity(rect.width * rect.height / 2 + 1024)
        data.append(0x2C)
        appendUInt16(rect.x, to: &data)
        appendUInt16(rect.y, to: &data)
        appendUInt16(rect.width, to: &data)
        appendUInt16(rect.height, to: &data)
        data.append(0x80 | UInt8(bits - 1)) // local color table, not interlaced
        var table = [UInt8](repeating: 0, count: 3 << bits)
        for (i, color) in palette.enumerated() {
            let j = (base + i) * 3
            table[j] = UInt8(color >> 16 & 0xFF)
            table[j + 1] = UInt8(color >> 8 & 0xFF)
            table[j + 2] = UInt8(color & 0xFF)
        }
        data.append(contentsOf: table)
        indices.withUnsafeBufferPointer { lzw.encode($0, minCodeSize: max(2, bits), into: &data) }
        return EncodedFrame(transparentIndex: transparentUnchanged ? 0 : nil, data: data)
    }

    /// Fills `indices` with exact colors and returns them (0xRRGGBB), or nil if the rectangle has too many.
    private func exactPalette(_ pixels: [UInt32], rect: Rect, base: Int, transparentUnchanged: Bool,
                              indices: inout [UInt8]) -> [UInt32]? {
        let limit = 256 - base
        let slots = 1024 // open addressing, at most a quarter full
        var keys = [UInt32](repeating: .max, count: slots)
        var values = [UInt8](repeating: 0, count: slots)
        var palette: [UInt32] = []
        palette.reserveCapacity(limit)
        let width = self.width
        let ok = pixels.withUnsafeBufferPointer { cur in
            previous.withUnsafeBufferPointer { prev in
                indices.withUnsafeMutableBufferPointer { out -> Bool in
                    var k = 0
                    for y in rect.y..<rect.y + rect.height {
                        var i = y * width + rect.x
                        for _ in 0..<rect.width {
                            let color = cur[i] & 0xFFFFFF
                            if transparentUnchanged, color == prev[i] & 0xFFFFFF {
                                out[k] = 0
                            } else {
                                var slot = Int((color &* 0x9E37_79B1) >> 22)
                                while keys[slot] != color, keys[slot] != .max { slot = (slot + 1) & (slots - 1) }
                                if keys[slot] == .max {
                                    guard palette.count < limit else { return false }
                                    keys[slot] = color
                                    values[slot] = UInt8(base + palette.count)
                                    palette.append(color)
                                }
                                out[k] = values[slot]
                            }
                            i += 1
                            k += 1
                        }
                    }
                    return true
                }
            }
        }
        return ok ? palette : nil
    }

    /// Median cut over a 5-bit-per-channel histogram of the changed pixels; fills `indices` and returns the palette.
    private func quantizedPalette(_ pixels: [UInt32], rect: Rect, base: Int, transparentUnchanged: Bool,
                                  indices: inout [UInt8]) -> [UInt32] {
        @inline(__always) func bucket(_ c: UInt32) -> Int {
            let r: UInt32 = c >> 9 & 0x7C00, g: UInt32 = c >> 6 & 0x03E0, b: UInt32 = c >> 3 & 0x001F
            return Int(r | g | b)
        }
        let width = self.width
        var counts = [Int](repeating: 0, count: 1 << 15)
        var sums = [Int](repeating: 0, count: 3 << 15)
        pixels.withUnsafeBufferPointer { cur in
            previous.withUnsafeBufferPointer { prev in
                for y in rect.y..<rect.y + rect.height {
                    var i = y * width + rect.x
                    for _ in 0..<rect.width {
                        let color = cur[i] & 0xFFFFFF
                        if !(transparentUnchanged && color == prev[i] & 0xFFFFFF) {
                            let b = bucket(color)
                            counts[b] += 1
                            sums[b * 3] += Int(color >> 16 & 0xFF)
                            sums[b * 3 + 1] += Int(color >> 8 & 0xFF)
                            sums[b * 3 + 2] += Int(color & 0xFF)
                        }
                        i += 1
                    }
                }
            }
        }

        var used = (0..<(1 << 15)).filter { counts[$0] > 0 }
        // Boxes are ranges of `used`; each split sorts a box along its widest channel and cuts it at the median pixel.
        var boxes: [Range<Int>] = [0..<used.count]
        func channel(_ b: Int, _ axis: Int) -> Int { b >> (10 - axis * 5) & 0x1F }
        func spread(_ box: Range<Int>) -> (axis: Int, range: Int) {
            var best = (axis: 0, range: -1)
            for axis in 0..<3 {
                var lo = 31, hi = 0
                for j in box {
                    let v = channel(used[j], axis)
                    lo = min(lo, v)
                    hi = max(hi, v)
                }
                if hi - lo > best.range { best = (axis, hi - lo) }
            }
            return best
        }
        var spreads = [spread(boxes[0])]
        var weights = [used.reduce(0) { $0 + counts[$1] }]
        let limit = 256 - base
        while boxes.count < limit {
            // Split the box that holds the most pixels times its widest spread.
            var pick = -1, score = 0
            for (n, box) in boxes.enumerated() where box.count > 1 {
                let s = weights[n] * (spreads[n].range + 1)
                if s > score { pick = n; score = s }
            }
            guard pick >= 0 else { break }
            let box = boxes[pick], axis = spreads[pick].axis, total = weights[pick]
            used[box].sort { channel($0, axis) < channel($1, axis) }
            var half = 0, cut = box.lowerBound
            while cut < box.upperBound - 1, half + counts[used[cut]] <= total / 2 {
                half += counts[used[cut]]
                cut += 1
            }
            if cut == box.lowerBound { half += counts[used[cut]]; cut += 1 }
            let left = box.lowerBound..<cut, right = cut..<box.upperBound
            boxes[pick] = left
            spreads[pick] = spread(left)
            weights[pick] = half
            boxes.append(right)
            spreads.append(spread(right))
            weights.append(total - half)
        }

        var lookup = [UInt8](repeating: 0, count: 1 << 15)
        var palette: [UInt32] = []
        for (n, box) in boxes.enumerated() {
            var r = 0, g = 0, b = 0, total = 0
            for j in box {
                let k = used[j]
                r += sums[k * 3]; g += sums[k * 3 + 1]; b += sums[k * 3 + 2]
                total += counts[k]
                lookup[k] = UInt8(base + n)
            }
            let t = max(total, 1)
            let red = UInt32((r + t / 2) / t), green = UInt32((g + t / 2) / t), blue = UInt32((b + t / 2) / t)
            palette.append(red << 16 | green << 8 | blue)
        }

        pixels.withUnsafeBufferPointer { cur in
            previous.withUnsafeBufferPointer { prev in
                indices.withUnsafeMutableBufferPointer { out in
                    var k = 0
                    for y in rect.y..<rect.y + rect.height {
                        var i = y * width + rect.x
                        for _ in 0..<rect.width {
                            let color = cur[i] & 0xFFFFFF
                            out[k] = transparentUnchanged && color == prev[i] & 0xFFFFFF ? 0 : lookup[bucket(color)]
                            i += 1
                            k += 1
                        }
                    }
                }
            }
        }
        return palette
    }

    private func appendUInt16(_ value: Int) { appendUInt16(value, to: &out) }

    private func appendUInt16(_ value: Int, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8 & 0xFF))
    }
}

/// GIF's variable-length LZW, codes up to 12 bits, packed LSB first into 255-byte sub-blocks.
struct LZWEncoder {
    /// `table[prefix << 8 | byte]` is the code for prefix + byte, 0 if there is none (real codes start above 257).
    private var table = [UInt16](repeating: 0, count: 4096 << 8)
    private var usedKeys: [Int] = []

    mutating func encode(_ indices: UnsafeBufferPointer<UInt8>, minCodeSize: Int, into data: inout Data) {
        let clear = 1 << minCodeSize, end = clear + 1
        var codeSize = minCodeSize + 1
        var lastCode = end
        var bytes: [UInt8] = []
        bytes.reserveCapacity(indices.count / 2 + 16)
        var bitBuffer: UInt64 = 0, bitCount = 0

        func emit(_ code: Int) {
            bitBuffer |= UInt64(code) << UInt64(bitCount)
            bitCount += codeSize
            while bitCount >= 8 {
                bytes.append(UInt8(truncatingIfNeeded: bitBuffer))
                bitBuffer >>= 8
                bitCount -= 8
            }
        }
        func reset() {
            for key in usedKeys { table[key] = 0 }
            usedKeys.removeAll(keepingCapacity: true)
            codeSize = minCodeSize + 1
            lastCode = end
        }

        reset()
        emit(clear)
        if !indices.isEmpty {
            var current = Int(indices[0])
            for i in 1..<indices.count {
                let next = Int(indices[i])
                let key = current << 8 | next
                let code = table[key]
                if code != 0 {
                    current = Int(code)
                    continue
                }
                emit(current)
                lastCode += 1
                table[key] = UInt16(lastCode)
                usedKeys.append(key)
                // The decoder widens its codes once its next free code reaches 2^codeSize.
                if lastCode >= 1 << codeSize, codeSize < 12 { codeSize += 1 }
                if lastCode == 4095 {
                    emit(clear)
                    reset()
                }
                current = next
            }
            emit(current)
            // Reading that code makes the decoder add one more entry, which may widen the end code.
            if lastCode + 1 >= 1 << codeSize, codeSize < 12 { codeSize += 1 }
        }
        emit(end)
        if bitCount > 0 { bytes.append(UInt8(truncatingIfNeeded: bitBuffer)) }

        data.append(UInt8(minCodeSize))
        var start = 0
        while start < bytes.count {
            let length = min(255, bytes.count - start)
            data.append(UInt8(length))
            data.append(contentsOf: bytes[start..<start + length])
            start += length
        }
        data.append(0)
    }
}
