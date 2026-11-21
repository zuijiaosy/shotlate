import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ShotlateCore

/// Deterministic noise for tests.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A strict GIF reader, independent of the encoder: fails on any code read at the wrong width,
/// data left after the end code, or a frame whose pixel count doesn't match its rectangle.
private struct DecodedGIF {
    struct Frame {
        var x, y, width, height: Int
        var delay: Int
        var transparent: Int?
        /// The whole canvas after drawing this frame, 0xRRGGBB.
        var canvas: [UInt32]
    }

    var width = 0, height = 0
    var loopsForever = false
    var frames: [Frame] = []

    struct Malformed: Error { var reason: String }

    init(_ data: Data) throws {
        let d = [UInt8](data)
        var p = 0
        func u8() throws -> Int {
            guard p < d.count else { throw Malformed(reason: "truncated") }
            defer { p += 1 }
            return Int(d[p])
        }
        func u16() throws -> Int { try u8() | (try u8() << 8) }
        func subBlocks() throws -> [UInt8] {
            var out: [UInt8] = []
            while true {
                let n = try u8()
                if n == 0 { return out }
                guard p + n <= d.count else { throw Malformed(reason: "truncated block") }
                out += d[p..<p + n]
                p += n
            }
        }

        guard d.count > 13, String(decoding: d[0..<6], as: UTF8.self) == "GIF89a" else { throw Malformed(reason: "header") }
        p = 6
        width = try u16()
        height = try u16()
        let packed = try u8()
        p += 2
        if packed & 0x80 != 0 { p += 3 << ((packed & 7) + 1) }
        var canvas = [UInt32](repeating: 0, count: width * height)
        var delay = 0
        var transparent: Int?
        while true {
            switch try u8() {
            case 0x21:
                let label = try u8()
                if label == 0xF9 {
                    guard try u8() == 4 else { throw Malformed(reason: "GCE size") }
                    let flags = try u8()
                    delay = try u16()
                    let index = try u8()
                    transparent = flags & 1 != 0 ? index : nil
                    guard flags >> 2 & 7 == 1 else { throw Malformed(reason: "disposal") }
                    guard try u8() == 0 else { throw Malformed(reason: "GCE terminator") }
                } else if label == 0xFF {
                    let body = try subBlocks()
                    if String(decoding: body.prefix(11), as: UTF8.self) == "NETSCAPE2.0", body.count == 14 {
                        loopsForever = body[12] == 0 && body[13] == 0
                    }
                } else {
                    _ = try subBlocks()
                }
            case 0x2C:
                let x = try u16(), y = try u16(), w = try u16(), h = try u16()
                let flags = try u8()
                guard flags & 0x80 != 0 else { throw Malformed(reason: "no local table") }
                guard x + w <= width, y + h <= height else { throw Malformed(reason: "frame outside canvas") }
                let size = 2 << (flags & 7)
                var colors: [UInt32] = []
                for _ in 0..<size {
                    let r = try u8(), g = try u8(), b = try u8()
                    colors.append(UInt32(r << 16 | g << 8 | b))
                }
                let minCodeSize = try u8()
                let indices = try lzwDecode(try subBlocks(), minCodeSize: minCodeSize)
                guard indices.count == w * h else { throw Malformed(reason: "pixel count \(indices.count) ≠ \(w * h)") }
                for row in 0..<h {
                    for col in 0..<w {
                        let index = Int(indices[row * w + col])
                        if index == transparent { continue }
                        guard index < size else { throw Malformed(reason: "index outside table") }
                        canvas[(y + row) * width + x + col] = colors[index]
                    }
                }
                frames.append(Frame(x: x, y: y, width: w, height: h, delay: delay, transparent: transparent, canvas: canvas))
                delay = 0
                transparent = nil
            case 0x3B:
                guard p == d.count else { throw Malformed(reason: "data after trailer") }
                return
            default:
                throw Malformed(reason: "unknown block at \(p - 1)")
            }
        }
    }
}

private func lzwDecode(_ data: [UInt8], minCodeSize: Int) throws -> [UInt8] {
    let clear = 1 << minCodeSize, end = clear + 1
    var codeSize = minCodeSize + 1
    var table: [[UInt8]] = (0..<clear).map { [UInt8($0)] } + [[], []]
    var previous: Int?
    var out: [UInt8] = []
    var bit = 0
    func read() throws -> Int {
        guard bit + codeSize <= data.count * 8 else { throw DecodedGIF.Malformed(reason: "ran out of codes") }
        var code = 0
        for i in 0..<codeSize where data[(bit + i) / 8] >> ((bit + i) % 8) & 1 != 0 { code |= 1 << i }
        bit += codeSize
        return code
    }
    while true {
        let code = try read()
        if code == clear {
            table.removeSubrange((end + 1)...)
            codeSize = minCodeSize + 1
            previous = nil
            continue
        }
        if code == end {
            guard (bit + 7) / 8 == data.count else { throw DecodedGIF.Malformed(reason: "data after end code") }
            return out
        }
        let entry: [UInt8]
        if code < table.count, code != clear, code != end {
            entry = table[code]
        } else if code == table.count, let previous {
            entry = table[previous] + [table[previous][0]]
        } else {
            throw DecodedGIF.Malformed(reason: "invalid code \(code) with \(table.count) entries")
        }
        out += entry
        if let previous, table.count < 4096 {
            table.append(table[previous] + [entry[0]])
            if table.count == 1 << codeSize, codeSize < 12 { codeSize += 1 }
        }
        previous = code
    }
}

private func encode(width: Int, height: Int, frames: [([UInt32], Double)], end: Double) throws -> (Data, GIFEncoder) {
    var data = Data()
    let encoder = try GIFEncoder(width: width, height: height) { data.append($0) }
    for (pixels, time) in frames { try encoder.add(pixels, time: time) }
    try encoder.finish(endTime: end)
    return (data, encoder)
}

/// 0xFFRRGGBB, as BGRA bytes read little-endian.
private func bgra(_ r: Int, _ g: Int, _ b: Int) -> UInt32 { 0xFF00_0000 | UInt32(r << 16 | g << 8 | b) }

private func image(_ width: Int, _ height: Int, _ color: (Int, Int) -> UInt32) -> [UInt32] {
    var pixels = [UInt32](repeating: 0, count: width * height)
    for y in 0..<height { for x in 0..<width { pixels[y * width + x] = color(x, y) } }
    return pixels
}

/// Canvas pixels of every frame as ImageIO composes them, 0xRRGGBB.
private func imageIOFrames(_ data: Data) throws -> [[UInt32]] {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return try (0..<CGImageSourceGetCount(source)).map { i in
        let cg = try #require(CGImageSourceCreateImageAtIndex(source, i, nil))
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = try #require(CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return (0..<cg.width * cg.height).map { (i: Int) -> UInt32 in
            let r = UInt32(bytes[i * 4]), g = UInt32(bytes[i * 4 + 1]), b = UInt32(bytes[i * 4 + 2])
            return r << 16 | g << 8 | b
        }
    }
}

@Suite struct GIFEncoderTests {
    @Test func lzwRoundTripsAtEveryCodeWidth() throws {
        var rng = SplitMix(state: 1)
        var encoder = LZWEncoder()
        // Lengths near every point where the code width changes or the table resets, for each palette size.
        for minCodeSize in [2, 3, 5, 8] {
            let alphabet = 1 << minCodeSize
            for length in Array(1...600) + [2_000, 5_000, 40_000, 120_000] {
                // Mostly runs, as on screen, with noise so the table fills.
                var indices: [UInt8] = []
                indices.reserveCapacity(length)
                while indices.count < length {
                    let value = UInt8(Int.random(in: 0..<alphabet, using: &rng))
                    let run = Bool.random(using: &rng) ? 1 : Int.random(in: 1...12, using: &rng)
                    indices += repeatElement(value, count: min(run, length - indices.count))
                }
                var data = Data()
                indices.withUnsafeBufferPointer { encoder.encode($0, minCodeSize: minCodeSize, into: &data) }
                let bytes = [UInt8](data)
                #expect(Int(bytes[0]) == minCodeSize)
                var payload: [UInt8] = [], p = 1
                while bytes[p] != 0 {
                    payload += bytes[p + 1..<p + 1 + Int(bytes[p])]
                    p += 1 + Int(bytes[p])
                }
                #expect(p == bytes.count - 1, "nothing after the block terminator")
                let decoded = try lzwDecode(payload, minCodeSize: minCodeSize)
                #expect(decoded == indices, "min code size \(minCodeSize), \(length) pixels")
                if decoded != indices { return }
            }
        }
    }

    @Test func fewColorsAreExact() throws {
        let w = 40, h = 30
        // 64 colors: within one frame's palette, so nothing may be approximated.
        let first = image(w, h) { x, y in bgra(x % 8 * 30, y % 4 * 60, (x + y) % 2 * 255) }
        var second = first
        for y in 10..<15 { for x in 20..<28 { second[y * w + x] = bgra(255, 0, 0) } }
        let third = image(w, h) { x, _ in x < 20 ? bgra(0, 0, 0) : bgra(255, 255, 255) }
        let (data, encoder) = try encode(width: w, height: h, frames: [(first, 0), (second, 0.1), (third, 0.25)], end: 1)
        #expect(encoder.frameCount == 3)

        let gif = try DecodedGIF(data)
        #expect(gif.width == w && gif.height == h && gif.loopsForever)
        #expect(gif.frames.count == 3)
        let expected = [first, second, third].map { $0.map { $0 & 0xFFFFFF } }
        #expect(gif.frames.map(\.canvas) == expected)
        #expect(gif.frames.map(\.delay) == [10, 15, 75])
        // The second frame stores only the changed block.
        let f = gif.frames[1]
        #expect((f.x, f.y, f.width, f.height) == (20, 10, 8, 5))
        #expect(gif.frames[0].transparent == nil && f.transparent != nil)

        // The system decoder agrees.
        #expect(try imageIOFrames(data) == expected)
    }

    @Test func identicalFramesMergeIntoOneDelay() throws {
        let a = image(8, 8) { _, _ in bgra(10, 20, 30) }
        let b = image(8, 8) { x, _ in x == 3 ? bgra(200, 0, 0) : bgra(10, 20, 30) }
        // Alpha differences don't count as changes.
        let aAlpha = a.map { $0 & 0x00FF_FFFF }
        var data = Data()
        let encoder = try GIFEncoder(width: 8, height: 8) { data.append($0) }
        #expect(try encoder.add(a, time: 5))
        #expect(try !encoder.add(aAlpha, time: 5.1))
        #expect(try !encoder.add(a, time: 5.2))
        #expect(try encoder.add(b, time: 5.3))
        try encoder.finish(endTime: 6)
        #expect(encoder.frameCount == 2)
        let gif = try DecodedGIF(data)
        #expect(gif.frames.map(\.delay) == [30, 70])
        #expect(encoder.byteCount == data.count)
    }

    @Test func delaysStayInRealTimeAndAboveTheMinimum() throws {
        let frames = (0..<6).map { i in (image(4, 4) { _, _ in bgra(i * 40, 0, 0) }, [0, 0.004, 0.009, 0.5, 0.517, 0.6][i]) }
        let (data, _) = try encode(width: 4, height: 4, frames: frames, end: 1.234)
        let delays = try DecodedGIF(data).frames.map(\.delay)
        #expect(delays.allSatisfy { $0 >= 2 })
        #expect(delays.reduce(0, +) == 123)
    }

    @Test func manyColorsAreReducedClosely() throws {
        let w = 256, h = 96
        // A smooth gradient with far more than 256 colors, plus black text-like strokes.
        let pixels = image(w, h) { x, y in
            y % 16 < 2 && x % 9 < 6 ? bgra(0, 0, 0) : bgra(x, (y * 255) / (h - 1), 255 - x / 2)
        }
        let (data, _) = try encode(width: w, height: h, frames: [(pixels, 0)], end: 1)
        let canvas = try #require(try DecodedGIF(data).frames.first?.canvas)
        var worst = 0, total = 0
        for (i, c) in canvas.enumerated() {
            let s = pixels[i]
            let e = [UInt32(16), 8, 0].map { (shift: UInt32) -> Int in
                let a = Int(c >> shift & 0xFF), b = Int(s >> shift & 0xFF)
                return abs(a - b)
            }.max()!
            worst = max(worst, e)
            total += e
        }
        #expect(worst <= 24, "worst channel error \(worst)")
        #expect(Double(total) / Double(canvas.count) < 6, "mean error \(Double(total) / Double(canvas.count))")
        for i in canvas.indices where pixels[i] & 0xFFFFFF == 0 { #expect(canvas[i] == 0); if canvas[i] != 0 { break } }
        #expect(try imageIOFrames(data).first == canvas)
    }

    @Test func noisyLargeFramesSurviveTableResets() throws {
        var rng = SplitMix(state: 7)
        let w = 320, h = 200
        let palette = (0..<200).map { _ in bgra(Int.random(in: 0...255, using: &rng), Int.random(in: 0...255, using: &rng), Int.random(in: 0...255, using: &rng)) }
        let frames = (0..<3).map { i in (image(w, h) { _, _ in palette.randomElement(using: &rng)! }, Double(i) * 0.1) }
        let (data, _) = try encode(width: w, height: h, frames: frames, end: 0.4)
        let gif = try DecodedGIF(data)
        #expect(gif.frames.map(\.canvas) == frames.map { $0.0.map { $0 & 0xFFFFFF } })
    }

    @Test func rejectsBadInput() throws {
        #expect(throws: GIFEncoder.Failure.invalidSize) { try GIFEncoder(width: 0, height: 10) { _ in } }
        #expect(throws: GIFEncoder.Failure.invalidSize) { try GIFEncoder(width: 70_000, height: 10) { _ in } }
        let empty = try GIFEncoder(width: 4, height: 4) { _ in }
        #expect(throws: GIFEncoder.Failure.noFrames) { try empty.finish(endTime: 1) }
    }

    @Test func sinkErrorsReachTheCaller() throws {
        struct DiskFull: Error {}
        let encoder = try GIFEncoder(width: 4, height: 4) { _ in throw DiskFull() }
        try encoder.add(image(4, 4) { _, _ in bgra(1, 2, 3) }, time: 0)
        #expect(throws: DiskFull.self) { try encoder.finish(endTime: 1) }
    }
}
