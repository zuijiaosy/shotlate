import CoreGraphics
import Foundation
import Testing
@testable import ShotlateCore

@Suite struct GeometryTests {
    @Test func visionBoxFlipsToTopLeftOrigin() {
        // A box in the top-left quarter of the image in Vision space (origin bottom-left).
        let box = CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        let selection = CGRect(x: 100, y: 200, width: 400, height: 200)
        #expect(VisionGeometry.rect(fromNormalized: box, in: selection) == CGRect(x: 100, y: 200, width: 200, height: 100))
    }

    @Test func visionBoxAtBottom() {
        let box = CGRect(x: 0.25, y: 0, width: 0.5, height: 0.1)
        let r = VisionGeometry.rect(fromNormalized: box, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(abs(r.minY - 90) < 0.0001)
        #expect(abs(r.minX - 25) < 0.0001)
    }
}

@Suite struct BlockTests {
    func line(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 200, h: CGFloat = 14) -> OCRLine {
        OCRLine(text: text, rect: CGRect(x: x, y: y, width: w, height: h))
    }

    @Test func mergesWrappedParagraph() {
        let blocks = TextBlockBuilder.group([
            line("Settings", x: 10, y: 10, w: 60, h: 18),
            line("Automatically check for updates", x: 10, y: 50),
            line("and download them in the background.", x: 10, y: 68),
            line("Save to: ~/Pictures/Shotlate", x: 10, y: 120),
        ])
        #expect(blocks.count == 3)
        #expect(blocks[1].text == "Automatically check for updates and download them in the background.")
        #expect(blocks[1].rect == CGRect(x: 10, y: 50, width: 200, height: 32))
    }

    @Test func keepsSideBySideColumnsApart() {
        let blocks = TextBlockBuilder.group([
            line("Name", x: 10, y: 10, w: 40),
            line("Value", x: 300, y: 10, w: 40),
            line("Other", x: 10, y: 28, w: 40),
        ])
        #expect(blocks.count == 2)
        #expect(blocks.map(\.text).contains("Name Other"))
        #expect(blocks.map(\.text).contains("Value"))
    }

    @Test func doesNotMergeHeadingIntoBody() {
        let blocks = TextBlockBuilder.group([
            line("Big Title", x: 10, y: 10, h: 30),
            line("body text", x: 10, y: 44, h: 14),
        ])
        #expect(blocks.count == 2)
    }

    @Test func joinsHyphenatedWords() {
        let block = TextBlock(id: 0, lines: [line("inter-", x: 0, y: 0), line("national trade", x: 0, y: 16)])
        #expect(block.text == "international trade")
    }

    @Test func translationFilter() {
        #expect(TextBlockBuilder.shouldTranslate("Check for updates"))
        #expect(TextBlockBuilder.shouldTranslate("Version 2.6.8"))
        #expect(!TextBlockBuilder.shouldTranslate("2.6.8"))
        #expect(!TextBlockBuilder.shouldTranslate("https://api.deepseek.com/v1"))
        #expect(!TextBlockBuilder.shouldTranslate("~/Pictures/Shotlate"))
        #expect(!TextBlockBuilder.shouldTranslate("自动检查更新 OK"))
        #expect(!TextBlockBuilder.shouldTranslate("42"))
        #expect(!TextBlockBuilder.shouldTranslate("dev@example.com"))
    }
}

@Suite struct ColorTests {
    /// 20×10 white image with a black 10×4 bar in the middle standing in for text.
    func sampleBuffer() -> PixelBuffer {
        let w = 20, h = 10
        var data = [UInt8](repeating: 255, count: w * h * 4)
        for y in 3..<7 {
            for x in 5..<15 {
                let i = (y * w + x) * 4
                data[i] = 0; data[i + 1] = 0; data[i + 2] = 0
            }
        }
        return PixelBuffer(width: w, height: h, bytesPerRow: w * 4, data: data)
    }

    @Test func picksBackgroundAndInk() {
        let colors = ColorSampler.sample(sampleBuffer(), rect: CGRect(x: 4, y: 2, width: 12, height: 6))
        #expect(colors.background == .white)
        #expect(colors.foreground == .black)
        #expect(colors.inkCoverage > 0.4)
    }

    /// 40×10 white image with a blue "button" from x=10 to x=30 and white text inside it.
    func buttonBuffer(textFrom: Int, to: Int) -> PixelBuffer {
        let w = 40, h = 10
        var data = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 10..<30 {
                let i = (y * w + x) * 4
                let isText = x >= textFrom && x < to && y >= 3 && y < 7 && x % 2 == 0
                data[i] = isText ? 255 : 40; data[i + 1] = isText ? 255 : 120; data[i + 2] = isText ? 255 : 240
            }
        }
        return PixelBuffer(width: w, height: h, bytesPerRow: w * 4, data: data)
    }

    @Test func detectsTextCenteredInContainer() {
        let colors = ColorSampler.sample(buttonBuffer(textFrom: 16, to: 24), rect: CGRect(x: 16, y: 3, width: 8, height: 4))
        #expect(colors.leftMargin == 6)
        #expect(colors.rightMargin == 6)
        #expect(colors.isCentered)
    }

    @Test func leftAlignedTextIsNotCentered() {
        let colors = ColorSampler.sample(buttonBuffer(textFrom: 11, to: 17), rect: CGRect(x: 11, y: 3, width: 6, height: 4))
        #expect(!colors.isCentered)
    }

    @Test func backgroundRunningToImageEdgeHasNoMargin() {
        let colors = ColorSampler.sample(sampleBuffer(), rect: CGRect(x: 4, y: 2, width: 12, height: 6))
        #expect(colors.leftMargin == nil)
        #expect(colors.rightMargin == nil)
        #expect(!colors.isCentered)
    }

    @Test func thickerStemsMeasureWider() {
        let thin = ColorSampler.averageInkRun(sampleBuffer(), CGRect(x: 4, y: 2, width: 12, height: 6), .white)
        #expect(thin == 10) // one 10px run per row in the black bar
    }

    @Test func lowContrastFallsBackToBlackOrWhite() {
        let w = 8, h = 8
        let data = [UInt8](repeating: 30, count: w * h * 4)
        let colors = ColorSampler.sample(PixelBuffer(width: w, height: h, bytesPerRow: w * 4, data: data),
                                         rect: CGRect(x: 2, y: 2, width: 4, height: 4))
        #expect(colors.foreground == .white)
    }

    @Test func rendersCGImageIntoBuffer() throws {
        let ctx = try #require(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 1, width: 4, height: 1)) // top row in CG's bottom-left space
        let image = try #require(ctx.makeImage())
        let buffer = try #require(PixelBuffer(image: image))
        #expect(buffer.pixel(x: 0, y: 0).r == 255)
        #expect(buffer.pixel(x: 0, y: 1).r == 0)
    }
}

@Suite struct TranslatorTests {
    let config = TranslationConfig(baseURL: "https://api.deepseek.com/", model: "deepseek-flash",
                                   apiKey: "sk-test", targetLanguage: "简体中文")

    @Test func buildsChatCompletionRequest() throws {
        let request = try ChatTranslator.makeRequest(items: [.init(id: 0, text: "Settings")], config: config)
        #expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let httpBody = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        #expect(body["model"] as? String == "deepseek-flash")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages[1]["content"] == #"{"items":[{"id":0,"text":"Settings"}]}"#)
    }

    @Test func rejectsMissingKey() {
        var c = config
        c.apiKey = " "
        #expect(throws: TranslationError.missingAPIKey) {
            try ChatTranslator.makeRequest(items: [.init(id: 0, text: "x")], config: c)
        }
    }

    @Test func parsesResponseWithFenceAndStringIDs() throws {
        let content = "```json\n{\"items\":[{\"id\":\"0\",\"t\":\"设置\"},{\"id\":1,\"zh\":\"保存\"}]}\n```"
        let response: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]]]
        let result = try ChatTranslator.parseResponse(try JSONSerialization.data(withJSONObject: response))
        #expect(result == [0: "设置", 1: "保存"])
    }

    @Test func badContentThrows() {
        let response: [String: Any] = ["choices": [["message": ["content": "not json"]]]]
        #expect(throws: TranslationError.self) {
            try ChatTranslator.parseResponse(try JSONSerialization.data(withJSONObject: response))
        }
    }

    @Test func cacheSendsOnlyMissingTexts() async throws {
        let cache = TranslationCache()
        cache.set("设置", for: "Settings", config: config)
        var sent: [String] = []
        let result = try await cache.translate([.init(id: 0, text: "Settings"), .init(id: 1, text: "Save")], config: config) { items in
            sent = items.map(\.text)
            return [1: "保存"]
        }
        #expect(sent == ["Save"])
        #expect(result == [0: "设置", 1: "保存"])
        #expect(cache.get("Save", config: config) == "保存")
    }
}

@Suite struct StitcherTests {
    static let width = 96

    /// A distinct pattern per content row, so every row hashes differently.
    static func contentRow(_ n: Int) -> [UInt8] {
        var row = [UInt8]()
        for x in 0..<width {
            let v = UInt8((n * 37 + x * 11 + (n * x) % 23) % 200 + 40) & 0xF8
            row += [v, UInt8((n * 13 + x) % 250) & 0xF8, UInt8((n + x * 7) % 250) & 0xF8, 255]
        }
        return row
    }

    static func solidRow(_ v: UInt8) -> [UInt8] {
        [UInt8](repeating: v, count: width * 4)
    }

    /// A 100-row window over tall content scrolled by `scroll`, with a 10-row header and 8-row footer that never move.
    /// `jitter` adds ±1 noise to every color value, like successive real screen captures.
    static func frame(scroll: Int, header: Bool = true, jitter: Bool = false) -> PixelBuffer {
        var data = [UInt8]()
        for y in 0..<100 {
            if header, y < 10 { data += solidRow(y % 2 == 0 ? 16 : 32); continue }
            if header, y >= 92 { data += solidRow(y % 2 == 0 ? 200 : 224); continue }
            data += contentRow(scroll + y)
        }
        if jitter {
            var rng = SystemRandomNumberGenerator()
            for i in data.indices where i % 4 != 3 {
                let v = Int(data[i]) + Int.random(in: -1...1, using: &rng)
                data[i] = UInt8(min(max(v, 0), 255))
            }
        }
        return PixelBuffer(width: width, height: 100, bytesPerRow: width * 4, data: data)
    }

    @Test func stitchesWithStickyHeaderAndFooter() {
        let stitcher = ScrollStitcher()
        #expect(stitcher.add(Self.frame(scroll: 0)) == .started)
        #expect(stitcher.add(Self.frame(scroll: 30)) == .appended(30))
        #expect(stitcher.add(Self.frame(scroll: 30)) == .unchanged)
        #expect(stitcher.add(Self.frame(scroll: 70)) == .appended(40))
        // Header once, content rows 10..<162, footer once.
        #expect(stitcher.height == 10 + 152 + 8)
        #expect(Array(stitcher.row(0)) == Self.solidRow(16))
        #expect(Array(stitcher.row(10)) == Self.contentRow(10))
        #expect(Array(stitcher.row(161)) == Self.contentRow(161))
        #expect(Array(stitcher.row(162)) == Self.solidRow(200)) // footer row 92
        #expect(stitcher.makeImage()?.height == 170)
        #expect(stitcher.makePreview(targetWidth: 48)?.height == 85)
    }

    @Test func toleratesCaptureJitter() {
        let stitcher = ScrollStitcher()
        _ = stitcher.add(Self.frame(scroll: 0, jitter: true))
        #expect(stitcher.add(Self.frame(scroll: 0, jitter: true)) == .unchanged)
        #expect(stitcher.add(Self.frame(scroll: 25, jitter: true)) == .appended(25))
        #expect(stitcher.add(Self.frame(scroll: 60, jitter: true)) == .appended(35))
        #expect(stitcher.height == 10 + (60 + 92 - 10) + 8)
    }

    @Test func roundedBottomCornersStayOutOfTheMiddle() {
        // The last 4 rows have "desktop" pixels in their outer columns, like a window's rounded corners,
        // while the content between them keeps scrolling.
        func cornered(_ frame: PixelBuffer) -> PixelBuffer {
            var data = frame.data
            for y in 96..<100 {
                for x in [0, 1, 2, Self.width - 3, Self.width - 2, Self.width - 1] {
                    data.replaceSubrange((y * Self.width + x) * 4 ..< (y * Self.width + x) * 4 + 3, with: [255, 0, 255])
                }
            }
            return PixelBuffer(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, data: data)
        }
        let stitcher = ScrollStitcher()
        for scroll in stride(from: 0, through: 120, by: 20) {
            _ = stitcher.add(cornered(Self.frame(scroll: scroll, header: false)))
        }
        #expect(stitcher.height == 220)
        for y in 0..<(stitcher.height - 4) {
            #expect(stitcher.row(y) == Self.contentRow(y), "row \(y) should be plain content")
        }
    }

    @Test func ignoresBackwardScrollAndResumes() {
        let stitcher = ScrollStitcher()
        _ = stitcher.add(Self.frame(scroll: 0))
        _ = stitcher.add(Self.frame(scroll: 40))
        #expect(stitcher.add(Self.frame(scroll: 20)) == .scrolledBack)
        #expect(stitcher.add(Self.frame(scroll: 60)) == .appended(20))
        #expect(stitcher.height == 10 + (60 + 92 - 10) + 8)
    }

    @Test func reportsJumpWithoutOverlap() {
        let stitcher = ScrollStitcher()
        _ = stitcher.add(Self.frame(scroll: 0))
        #expect(stitcher.add(Self.frame(scroll: 500)) == .noOverlap)
        #expect(stitcher.height == 100)
    }

    @Test func stopsAtHeightLimit() {
        let stitcher = ScrollStitcher(maxHeight: 120)
        _ = stitcher.add(Self.frame(scroll: 0))
        #expect(stitcher.add(Self.frame(scroll: 30)) == .limitReached)
    }

    @Test func ignoresChangingScrollBarColumns() {
        // Same content, but the right-most 4 columns differ between frames like a moving scroll bar knob.
        func withKnob(_ frame: PixelBuffer, _ v: UInt8) -> PixelBuffer {
            var data = frame.data
            for y in 0..<frame.height {
                for x in (Self.width - 8)..<Self.width { data[(y * Self.width + x) * 4 ..< (y * Self.width + x) * 4 + 3] = [v, v, v] }
            }
            return PixelBuffer(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, data: data)
        }
        let strict = ScrollStitcher()
        _ = strict.add(withKnob(Self.frame(scroll: 0, header: false), 0))
        #expect(strict.add(withKnob(Self.frame(scroll: 30, header: false), 128)) == .noOverlap)

        let tolerant = ScrollStitcher(ignoredRightColumns: 8)
        _ = tolerant.add(withKnob(Self.frame(scroll: 0, header: false), 0))
        #expect(tolerant.add(withKnob(Self.frame(scroll: 30, header: false), 128)) == .appended(30))
    }
}

@Suite struct TextSelectionTests {
    /// A line whose characters are each 10pt wide, starting at `x`.
    func line(_ text: String, x: CGFloat = 0, y: CGFloat) -> GlyphLine {
        let boxes = text.indices.enumerated().map { n, _ in CGRect(x: x + CGFloat(n) * 10, y: y, width: 10, height: 14) } as [CGRect?]
        return GlyphLine(text: text, rect: CGRect(x: x, y: y, width: CGFloat(text.count) * 10, height: 14), boxes: boxes)
    }

    @Test func sharesAWordBoxAcrossItsCharacters() {
        let word = CGRect(x: 0, y: 0, width: 40, height: 14)
        let space = CGRect?.none
        let l = GlyphLine(text: "abcd ef", rect: CGRect(x: 0, y: 0, width: 70, height: 14),
                          boxes: [word, word, word, word, space, CGRect(x: 50, y: 0, width: 20, height: 14), CGRect(x: 50, y: 0, width: 20, height: 14)])
        #expect(l.boxes.map(\.minX) == [0, 10, 20, 30, 40, 50, 60])
        #expect(l.boxes[4].width == 10)
    }

    @Test func ignoresTheEmptyBoxesVisionGivesSpaces() {
        let l = GlyphLine(text: "ab c", rect: CGRect(x: 100, y: 0, width: 40, height: 14),
                          boxes: [CGRect(x: 100, y: 0, width: 10, height: 14), CGRect(x: 110, y: 0, width: 10, height: 14), .zero,
                                  CGRect(x: 130, y: 0, width: 10, height: 14)])
        #expect(l.boxes.map(\.minX) == [100, 110, 120, 130])
    }

    @Test func draggingPastALineEndStaysOnThatLine() {
        let layout = TextLayout([line("a much longer line", y: 0), line("short", y: 20)])
        #expect(layout.nearestPosition(to: CGPoint(x: 120, y: 27)) == TextPosition(line: 1, offset: 5))
        #expect(layout.nearestPosition(to: CGPoint(x: 20, y: 60)) == TextPosition(line: 1, offset: 2))
    }

    @Test func missingBoxesFallBackToTheLine() {
        let l = GlyphLine(text: "abcd", rect: CGRect(x: 100, y: 5, width: 40, height: 14), boxes: [])
        #expect(l.boxes.map(\.minX) == [100, 110, 120, 130])
        #expect(l.boxes.allSatisfy { $0.minY == 5 && $0.height == 14 })
    }

    @Test func hitTestFindsTheCaret() {
        let layout = TextLayout([line("hello", y: 0), line("world", y: 20)])
        #expect(layout.hitTest(CGPoint(x: 14, y: 7)) == TextPosition(line: 0, offset: 1))
        #expect(layout.hitTest(CGPoint(x: 16, y: 7)) == TextPosition(line: 0, offset: 2))
        #expect(layout.hitTest(CGPoint(x: 49, y: 27)) == TextPosition(line: 1, offset: 5))
        #expect(layout.hitTest(CGPoint(x: 90, y: 7)) == nil)
        #expect(layout.nearestPosition(to: CGPoint(x: 90, y: 7)) == TextPosition(line: 0, offset: 5))
    }

    @Test func selectsAcrossLinesInReadingOrder() {
        // Given out of order; the layout sorts them top to bottom.
        let layout = TextLayout([line("world", y: 20), line("hello", y: 0)])
        let range = TextSpan(anchor: TextPosition(line: 1, offset: 2), focus: TextPosition(line: 0, offset: 3))
        #expect(layout.text(for: range) == "lo\nwo")
        #expect(layout.rects(for: range) == [CGRect(x: 30, y: 0, width: 20, height: 14), CGRect(x: 0, y: 20, width: 20, height: 14)])
        #expect(layout.text(for: TextSpan(anchor: range.anchor, focus: range.anchor)) == "")
    }

    @Test func doubleClickSelectsAWord() {
        let layout = TextLayout([line("copy the text", y: 0), line("直接选择文字", y: 20)])
        let word = layout.word(at: CGPoint(x: 65, y: 7))!
        #expect(layout.text(for: word) == "the")
        let cjk = layout.word(at: CGPoint(x: 25, y: 27))!
        #expect(!cjk.isEmpty && layout.text(for: cjk).count < 6)
        let whole = layout.line(at: CGPoint(x: 25, y: 27))!
        #expect(layout.text(for: whole) == "直接选择文字")
    }
}
