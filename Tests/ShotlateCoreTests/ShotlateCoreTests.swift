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

    @Test func resumesAfterLosingTrack() {
        // A fling jumps past the visible band; frames only match again once the user scrolls back
        // to where the last stitched frame overlaps, and stitching then carries on seamlessly.
        let stitcher = ScrollStitcher()
        _ = stitcher.add(Self.frame(scroll: 0))
        #expect(stitcher.add(Self.frame(scroll: 150)) == .noOverlap)
        #expect(stitcher.add(Self.frame(scroll: 170)) == .noOverlap)
        #expect(stitcher.add(Self.frame(scroll: 60)) == .appended(60))
        #expect(stitcher.add(Self.frame(scroll: 100)) == .appended(40))
        #expect(stitcher.height == 10 + (100 + 92 - 10) + 8)
        for y in 10..<(100 + 92) { #expect(stitcher.row(y) == Self.contentRow(y), "row \(y)") }
    }

    @Test func scrollHintPicksOffsetInRepeatingContent() {
        // Content that repeats every 20 rows matches at several offsets; the scroll hint picks the real one.
        func periodic(_ scroll: Int) -> PixelBuffer {
            var data = [UInt8]()
            for y in 0..<100 { data += y < 10 ? Self.solidRow(16) : Self.contentRow((scroll + y) % 20) }
            return PixelBuffer(width: Self.width, height: 100, bytesPerRow: Self.width * 4, data: data)
        }
        let hinted = ScrollStitcher()
        _ = hinted.add(periodic(0))
        #expect(hinted.add(periodic(30), expectedOffset: 28) == .appended(30))

        let unhinted = ScrollStitcher()
        _ = unhinted.add(periodic(0))
        #expect(unhinted.add(periodic(30)) != .appended(30))
    }

    @Test func stopsAtHeightLimit() {
        let stitcher = ScrollStitcher(maxHeight: 120)
        _ = stitcher.add(Self.frame(scroll: 0))
        #expect(stitcher.add(Self.frame(scroll: 30)) == .limitReached)
    }

    @Test func ignoresChangingScrollBarColumns() {
        // Same content, but 8 columns at both edges differ between frames like overlay scroll bar knobs.
        func withKnobs(_ frame: PixelBuffer, _ v: UInt8) -> PixelBuffer {
            var data = frame.data
            for y in 0..<frame.height {
                for x in Array(0..<8) + Array((Self.width - 8)..<Self.width) {
                    data[(y * Self.width + x) * 4 ..< (y * Self.width + x) * 4 + 3] = [v, v, v]
                }
            }
            return PixelBuffer(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, data: data)
        }
        let stitcher = ScrollStitcher(ignoredSideColumns: 8)
        _ = stitcher.add(withKnobs(Self.frame(scroll: 0, header: false), 0))
        #expect(stitcher.add(withKnobs(Self.frame(scroll: 30, header: false), 255)) == .appended(30))
    }

    /// A frame with a `footer`-row toolbar at the bottom that never moves.
    static func footered(scroll: Int, footer: Int, caret: Bool = false) -> PixelBuffer {
        var data = [UInt8]()
        for y in 0..<100 {
            if y >= 100 - footer {
                var row = solidRow(y % 3 == 0 ? 90 : 180)
                // A caret a few pixels wide in the input box, blinking between frames.
                if caret, y >= 100 - footer + 4, y < 100 - footer + 16 {
                    for x in 40..<42 { row.replaceSubrange(x * 4 ..< x * 4 + 3, with: scroll % 2 == 0 ? [0, 0, 0] : [255, 255, 255]) }
                }
                data += row
            } else {
                data += contentRow(scroll + y)
            }
        }
        return PixelBuffer(width: width, height: 100, bytesPerRow: width * 4, data: data)
    }

    @Test func tallFooterAppearsOnlyAtTheBottom() {
        let stitcher = ScrollStitcher()
        for scroll in [0, 12, 30, 51, 70, 90] { _ = stitcher.add(Self.footered(scroll: scroll, footer: 30)) }
        #expect(stitcher.height == 90 + 100)
        for y in 0..<(90 + 70) { #expect(stitcher.row(y) == Self.contentRow(y), "row \(y)") }
        #expect(stitcher.row(stitcher.height - 1) == Self.footered(scroll: 90, footer: 30).data.suffix(Self.width * 4).map { $0 })
    }

    @Test func blinkingCaretInFooterIsNotContent() {
        let stitcher = ScrollStitcher()
        _ = stitcher.add(Self.footered(scroll: 0, footer: 30, caret: true))
        #expect(stitcher.add(Self.footered(scroll: 1, footer: 30, caret: true)) == .appended(1))
        #expect(stitcher.add(Self.footered(scroll: 1, footer: 30, caret: false)) == .unchanged)
        #expect(stitcher.add(Self.footered(scroll: 25, footer: 30, caret: true)) == .appended(24))
        for y in 0..<(25 + 70) { #expect(stitcher.row(y) == Self.contentRow(y), "row \(y)") }
    }

    /// Content made of soft horizontal stripes sampled at fractional scroll positions, like a browser
    /// scrolling by half pixels and re-rendering: no two frames share exact rows.
    static func smooth(scroll: Double) -> PixelBuffer {
        var data = [UInt8]()
        for y in 0..<100 {
            let v = scroll + Double(y)
            for x in 0..<width {
                let a = 128 + 60 * sin(v * 0.21 + Double(x) * 0.13) + 50 * sin(v * 0.037 * Double(x % 7 + 1))
                data += [UInt8(max(0, min(255, a))), UInt8(max(0, min(255, 255 - a))), 128, 255]
            }
        }
        return PixelBuffer(width: width, height: 100, bytesPerRow: width * 4, data: data)
    }

    @Test func followsFractionalScrolling() {
        let stitcher = ScrollStitcher()
        _ = stitcher.add(Self.smooth(scroll: 0))
        var total = 0
        for scroll in [7.5, 19.25, 33.5, 50.0] {
            guard case .appended(let d) = stitcher.add(Self.smooth(scroll: scroll)) else {
                Issue.record("frame at \(scroll) did not stitch")
                return
            }
            total += d
            #expect(abs(Double(total) - scroll) <= 1)
        }
    }

    @Test func lowTextureContentStillStitches() {
        // Mostly blank rows with a line of detail every 15 rows.
        func sparse(_ scroll: Int) -> PixelBuffer {
            var data = [UInt8]()
            for y in 0..<100 { data += (scroll + y) % 15 == 0 ? Self.contentRow(scroll + y) : Self.solidRow(250) }
            return PixelBuffer(width: Self.width, height: 100, bytesPerRow: Self.width * 4, data: data)
        }
        let stitcher = ScrollStitcher()
        _ = stitcher.add(sparse(0))
        #expect(stitcher.add(sparse(20)) == .appended(20))
        #expect(stitcher.add(sparse(47)) == .appended(27))
    }

    @Test func rubberBandAtTheEndLeavesNoGap() {
        // At the end of the page the content overshoots, showing blank rows above the footer, then bounces back.
        func overscrolled(_ by: Int) -> PixelBuffer {
            var data = [UInt8]()
            for y in 0..<100 {
                if y < 10 { data += Self.solidRow(y % 2 == 0 ? 16 : 32) } else if y >= 92 { data += Self.solidRow(y % 2 == 0 ? 200 : 224) }
                else { data += y >= 92 - by ? Self.solidRow(255) : Self.contentRow(60 + y + by) }
            }
            return PixelBuffer(width: Self.width, height: 100, bytesPerRow: Self.width * 4, data: data)
        }
        let stitcher = ScrollStitcher()
        _ = stitcher.add(Self.frame(scroll: 0))
        _ = stitcher.add(Self.frame(scroll: 30))
        _ = stitcher.add(Self.frame(scroll: 60))
        #expect(stitcher.add(overscrolled(6)) == .appended(6))
        #expect(stitcher.add(Self.frame(scroll: 60)) == .scrolledBack)
        #expect(stitcher.height == 10 + (60 + 82) + 8)
        for y in 10..<(60 + 92) { #expect(stitcher.row(y) == Self.contentRow(y), "row \(y)") }
    }

    @Test func previewShowsTheNewestRows() {
        let stitcher = ScrollStitcher()
        for scroll in stride(from: 0, through: 300, by: 30) { _ = stitcher.add(Self.frame(scroll: scroll)) }
        let preview = stitcher.makePreview(targetWidth: 96, maxHeight: 50)
        #expect(preview?.height == 50)
        #expect(preview?.width == 96)
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

@Suite struct FreeTranslatorTests {
    func item(_ id: Int, _ n: Int) -> ChatTranslator.Item { .init(id: id, text: String(repeating: "a", count: n)) }

    @Test func batchesStayUnderLimitAndKeepOrder() {
        let items = (0..<5).map { item($0, 1500) }
        let batches = FreeTranslator.batches(items)
        #expect(batches.map { $0.map(\.id) } == [[0, 1], [2, 3], [4]])
    }

    @Test func batchAtExactLimitStaysTogether() {
        #expect(FreeTranslator.batches([item(0, 2000), item(1, 2000)]).count == 1)
        #expect(FreeTranslator.batches([item(0, 2000), item(1, 2001)]).count == 2)
    }

    @Test func overlongItemIsSplitWithoutLosingText() {
        let batches = FreeTranslator.batches([item(0, 10), item(1, 9000), item(2, 10)])
        #expect(batches.map { $0.map(\.id) } == [[0], [1], [1], [1, 2]])
        #expect(batches.allSatisfy { $0.reduce(0) { $0 + $1.text.utf16.count } <= 4000 })
        #expect(batches.flatMap { $0 }.filter { $0.id == 1 }.map(\.text).joined() == item(1, 9000).text)
    }

    @Test func unicodeChunksStayWithinServiceLimit() {
        let text = String(repeating: "中😀e\u{301}", count: 2000)
        let chunks = FreeTranslator.batches([.init(id: 42, text: text)]).flatMap { $0 }
        #expect(chunks.allSatisfy { $0.text.utf16.count <= 4000 && $0.id == 42 })
        #expect(chunks.map(\.text).joined() == text)
    }

    @Test func translatesAndReassemblesLongParagraphs() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [FreeTranslationProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        let config = TranslationConfig(baseURL: "", model: "", apiKey: "", targetLanguage: "English", engine: .free)
        let long = String(repeating: "a", count: 4000) + String(repeating: "b", count: 4000) + String(repeating: "c", count: 1000)
        let result = try await Translator.translate([
            .init(id: 7, text: "before"), .init(id: 42, text: long), .init(id: 9, text: "after"),
        ], config: config, session: session)
        #expect(result == [7: "BEFORE", 42: long.uppercased(), 9: "AFTER"])
    }

    @Test func buildsRequest() throws {
        let config = TranslationConfig(baseURL: "", model: "", apiKey: "", targetLanguage: "日本語", engine: .free, clientKey: "k1")
        let request = try FreeTranslator.makeRequest(texts: ["Settings", "Open"], config: config)
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(request.httpMethod == "POST")
        #expect((body["header"] as? [String: Any])?["client_key"] as? String == "k1")
        #expect((body["target"] as? [String: Any])?["lang"] as? String == "ja")
        let source = try #require(body["source"] as? [String: Any])
        #expect(source["lang"] as? String == "auto")
        #expect(source["text_list"] as? [String] == ["Settings", "Open"])
    }

    @Test func mapsEveryLanguage() {
        #expect(["简体中文", "繁體中文", "English", "日本語", "한국어"].map(FreeTranslator.languageCode) == ["zh", "zh-TW", "en", "ja", "ko"])
    }

    @Test func parsesResponse() throws {
        let ok = #"{"header":{"ret_code":"succ"},"auto_translation":["设置","打开"]}"#
        #expect(try FreeTranslator.parseResponse(Data(ok.utf8), expected: 2) == ["设置", "打开"])
        #expect(throws: TranslationError.badResponse("译文数量与原文不一致")) {
            try FreeTranslator.parseResponse(Data(ok.utf8), expected: 3)
        }
        let limit = #"{"header":{"ret_code":"outOfLimit"}}"#
        #expect(throws: TranslationError.service("outOfLimit")) {
            try FreeTranslator.parseResponse(Data(limit.utf8), expected: 1)
        }
    }

    @Test func cacheKeyIgnoresModelForFreeEngine() {
        var a = TranslationConfig(baseURL: "", model: "m1", apiKey: "", targetLanguage: "English", engine: .free)
        var b = a
        b.model = "m2"
        #expect(TranslationCache.key("x", a) == TranslationCache.key("x", b))
        a.engine = .llm
        #expect(TranslationCache.key("x", a) != TranslationCache.key("x", b))
    }
}

private final class FreeTranslationProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
                    if count == 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let source = try #require(body["source"] as? [String: Any])
            let texts = try #require(source["text_list"] as? [String])
            let withinLimit = texts.reduce(0) { $0 + $1.utf16.count } <= 4000
            let responseBody: [String: Any] = [
                "header": ["ret_code": withinLimit ? "succ" : "outOfLimit"],
                "auto_translation": texts.map { $0.uppercased() },
            ]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: responseBody))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
