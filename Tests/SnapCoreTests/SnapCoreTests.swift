import CoreGraphics
import Foundation
import Testing
@testable import SnapCore

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
            line("Save to: ~/Pictures/Snap", x: 10, y: 120),
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
        #expect(!TextBlockBuilder.shouldTranslate("~/Pictures/Snap"))
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

@Suite struct ClipboardTextTests {
    @Test func parsesHexForms() {
        #expect(ColorText.parse("#FF8000")?.hex == "#FF8000")
        #expect(ColorText.parse(" #f80 ")?.hex == "#FF8800")
        #expect(ColorText.parse("#11223344")?.hex == "#112233")
        #expect(ColorText.parse("#12345") == nil)
        #expect(ColorText.parse("#GG0000") == nil)
    }

    @Test func parsesRGBForms() {
        #expect(ColorText.parse("rgb(255, 128, 0)")?.hex == "#FF8000")
        #expect(ColorText.parse("rgba(255, 128, 0, 0.5)")?.hex == "#FF8000")
        #expect(ColorText.parse("10, 20, 30")?.hex == "#0A141E")
        #expect(ColorText.parse("10 20 30")?.hex == "#0A141E")
        #expect(ColorText.parse("1.0, 0.5, 0")?.hex == "#FF8000")
        #expect(ColorText.parse("256, 0, 0") == nil)
        #expect(ColorText.parse("1.5, 0, 0") == nil)
        #expect(ColorText.parse("10, 20") == nil)
        #expect(ColorText.parse("hello world again") == nil)
    }

    @Test func detectsCode() {
        #expect(CodeText.looksLikeCode("{\n  \"a\": 1\n}"))
        #expect(CodeText.looksLikeCode("func add(a: Int) -> Int {\n    return a + 1\n}"))
        #expect(CodeText.looksLikeCode("import os\nprint(os.getcwd())\n"))
        #expect(!CodeText.looksLikeCode("明天下午三点开会，记得带上周报。"))
        #expect(!CodeText.looksLikeCode("The quick brown fox jumps over the lazy dog.\nSecond sentence here."))
    }
}

@Suite struct FileNameTemplateTests {
    let date = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 14:13:20 UTC
    let utc = TimeZone(identifier: "UTC")!

    @Test func defaultTemplate() {
        #expect(FileNameTemplate.expand(FileNameTemplate.default, date: date, appName: "Safari", timeZone: utc) == "Snap 2026-09-21 14.13.20")
    }

    @Test func appAndCompactDate() {
        #expect(FileNameTemplate.expand("{app}_{yyyyMMdd_HHmmss}", date: date, appName: "Xcode", timeZone: utc) == "Xcode_20260921_141320")
        #expect(FileNameTemplate.expand("{APP}", date: date, appName: nil, timeZone: utc) == "Snap")
    }

    @Test func sanitizesPathCharacters() {
        #expect(FileNameTemplate.expand("{yyyy/MM/dd HH:mm}", date: date, appName: nil, timeZone: utc) == "2026-09-21 14.13")
        #expect(FileNameTemplate.expand("{app}", date: date, appName: "A/B: C", timeZone: utc) == "A-B. C")
    }

    @Test func unclosedBraceAndEmpty() {
        #expect(FileNameTemplate.expand("shot {yyyy", date: date, appName: nil, timeZone: utc) == "shot {yyyy")
        #expect(FileNameTemplate.expand("  ", date: date, appName: nil, timeZone: utc) == "Snap")
    }
}

@Suite struct SelectionGeometryTests {
    @Test func parsesSizes() {
        #expect(SizeText.parse("800x600") == CGSize(width: 800, height: 600))
        #expect(SizeText.parse(" 1280 × 720 ") == CGSize(width: 1280, height: 720))
        #expect(SizeText.parse("300*200") == CGSize(width: 300, height: 200))
        #expect(SizeText.parse("300, 200") == CGSize(width: 300, height: 200))
        #expect(SizeText.parse("300") == nil)
        #expect(SizeText.parse("0x10") == nil)
        #expect(SizeText.parse("abc") == nil)
    }

    @Test func parsesRatios() {
        #expect(abs((AspectRatio("16:9")?.value ?? 0) - 16.0 / 9.0) < 1e-9)
        #expect(AspectRatio("3/4")?.label == "3:4")
        #expect(AspectRatio("0:4") == nil)
        #expect(AspectRatio.presets.count == 7)
    }

    @Test func fitsRatioInAnyDirection() {
        let a = CGPoint(x: 100, y: 100)
        #expect(SelectionGeometry.fit(anchor: a, toward: CGPoint(x: 260, y: 130), ratio: 16.0 / 9.0) == CGRect(x: 100, y: 100, width: 160, height: 90))
        // Mostly vertical drag: height drives.
        #expect(SelectionGeometry.fit(anchor: a, toward: CGPoint(x: 110, y: 190), ratio: 1) == CGRect(x: 100, y: 100, width: 90, height: 90))
        // Up and to the left.
        #expect(SelectionGeometry.fit(anchor: a, toward: CGPoint(x: 20, y: 80), ratio: 2) == CGRect(x: 20, y: 60, width: 80, height: 40))
    }

    @Test func clampsKeepingRatioAndAnchor() {
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 300)
        let r = SelectionGeometry.clamp(CGRect(x: 400, y: 100, width: 200, height: 100), anchor: CGPoint(x: 400, y: 100), in: bounds)
        #expect(r == CGRect(x: 400, y: 100, width: 100, height: 50))
    }

    @Test func edgeResizeFollowsRatio() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        #expect(SelectionGeometry.fitEdge(CGRect(x: 10, y: 10, width: 320, height: 50), ratio: 16.0 / 9.0, horizontalEdge: true, in: bounds)
            == CGRect(x: 10, y: 10, width: 320, height: 180))
        #expect(SelectionGeometry.fitEdge(CGRect(x: 10, y: 10, width: 50, height: 300), ratio: 0.75, horizontalEdge: false, in: bounds)
            == CGRect(x: 10, y: 10, width: 225, height: 300))
    }
}

@Suite struct ElementHierarchyTests {
    // window > toolbar > button; window > content; a same-size wrapper around the button.
    let nodes = [
        UIElementNode(rect: CGRect(x: 0, y: 0, width: 400, height: 300), parent: nil),     // 0 window content
        UIElementNode(rect: CGRect(x: 0, y: 0, width: 400, height: 40), parent: 0),       // 1 toolbar
        UIElementNode(rect: CGRect(x: 10, y: 5, width: 60, height: 30), parent: 1),       // 2 button wrapper
        UIElementNode(rect: CGRect(x: 10, y: 5, width: 60, height: 30), parent: 2),       // 3 button (same frame)
        UIElementNode(rect: CGRect(x: 0, y: 40, width: 400, height: 260), parent: 0),     // 4 content
    ]
    let window = CGRect(x: 0, y: 0, width: 400, height: 320)

    @Test func innermostFirstThenAncestors() {
        let chain = ElementHierarchy(nodes: nodes).chain(at: CGPoint(x: 20, y: 10), within: window)
        #expect(chain == [nodes[3].rect, nodes[1].rect, nodes[0].rect, window])
    }

    @Test func pointOutsideElementsGivesWindowOnly() {
        let chain = ElementHierarchy(nodes: nodes).chain(at: CGPoint(x: 200, y: 310), within: window)
        #expect(chain == [window])
    }

    @Test func ignoresElementsOutsideTheFrontWindow() {
        let hidden = nodes + [UIElementNode(rect: CGRect(x: 500, y: 0, width: 100, height: 100), parent: nil)]
        let front = CGRect(x: 450, y: 0, width: 300, height: 300)
        // The node at 500,0 is inside the front window; the others are not.
        #expect(ElementHierarchy(nodes: hidden).chain(at: CGPoint(x: 520, y: 20), within: front) == [hidden[5].rect, front])
        #expect(ElementHierarchy(nodes: nodes).chain(at: CGPoint(x: 20, y: 10), within: front) == [front])
    }

    @Test func survivesParentCycles() {
        let cyclic = [UIElementNode(rect: CGRect(x: 0, y: 0, width: 10, height: 10), parent: 1),
                      UIElementNode(rect: CGRect(x: 0, y: 0, width: 20, height: 20), parent: 0)]
        #expect(ElementHierarchy(nodes: cyclic).chain(at: CGPoint(x: 5, y: 5), within: nil).count == 2)
    }
}

@Suite struct AutomationTests {
    @Test func parsesCaptureURLs() {
        #expect(Automation.parse(URL(string: "snap://capture")!) == .capture(CaptureRequest(area: .interactive, outputs: [])))
        #expect(Automation.parse(URL(string: "snap://capture?area=full&output=clipboard,pin&delay=2")!)
            == .capture(CaptureRequest(area: .fullScreen, outputs: [.clipboard, .pin], delay: 2)))
        #expect(Automation.parse(URL(string: "snap://capture?area=10,20,300,200&file=/tmp/a%20b.png")!)
            == .capture(CaptureRequest(area: .rect(CGRect(x: 10, y: 20, width: 300, height: 200)), outputs: [.file("/tmp/a b.png")])))
        #expect(Automation.parse(URL(string: "snap://capture?area=window&output=save")!)
            == .capture(CaptureRequest(area: .activeWindow, outputs: [.quickSave])))
        #expect(Automation.parse(URL(string: "snap://capture?area=1,2,3")!) == nil)
        #expect(Automation.parse(URL(string: "snap://capture?output=fax")!) == nil)
        #expect(Automation.parse(URL(string: "http://capture")!) == nil)
    }

    @Test func parsesOtherURLs() {
        #expect(Automation.parse(URL(string: "snap://pin")!) == .pinClipboard)
        #expect(Automation.parse(URL(string: "snap://toggle-pins")!) == .togglePins)
        #expect(Automation.parse(URL(string: "snap://whiteboard?transparent=1")!) == .whiteboard(transparent: true))
        #expect(Automation.parse(URL(string: "snap://whiteboard")!) == .whiteboard(transparent: false))
        #expect(Automation.parse(URL(string: "snap://scan")!) == .scanCode)
        #expect(Automation.parse(URL(string: "snap://nope")!) == nil)
    }

    @Test func parsesSnipasteStyleArguments() {
        #expect(Automation.parse(arguments: ["snip", "--full", "-o", "clipboard"])
            == .capture(CaptureRequest(area: .fullScreen, outputs: [.clipboard])))
        #expect(Automation.parse(arguments: ["snip", "--area", "0", "0", "800", "600", "-o", "pin;quick-save;/tmp/x.png"])
            == .capture(CaptureRequest(area: .rect(CGRect(x: 0, y: 0, width: 800, height: 600)), outputs: [.pin, .quickSave, .file("/tmp/x.png")])))
        #expect(Automation.parse(arguments: ["snip", "--last", "--delay", "1.5"])
            == .capture(CaptureRequest(area: .last, outputs: [], delay: 1.5)))
        #expect(Automation.parse(arguments: ["snip", "--area", "0", "0"]) == nil)
        #expect(Automation.parse(arguments: ["snip", "--bogus"]) == nil)
        #expect(Automation.parse(arguments: ["paste"]) == .pinClipboard)
        #expect(Automation.parse(arguments: ["whiteboard", "--transparent"]) == .whiteboard(transparent: true))
        #expect(Automation.parse(arguments: ["--ui-demo"]) == nil)
    }

    @Test func roundTripsThroughURLs() {
        let commands: [AutomationCommand] = [
            .capture(CaptureRequest(area: .rect(CGRect(x: 1.5, y: 2, width: 30, height: 40)), outputs: [.clipboard, .file("/tmp/a b.png")], delay: 3)),
            .capture(CaptureRequest(area: .last, outputs: [.pin])),
            .capture(CaptureRequest(area: .interactive, outputs: [])),
            .whiteboard(transparent: true), .togglePins, .scanCode, .pinClipboard, .replayHistory, .nextPinGroup,
        ]
        for command in commands {
            #expect(Automation.parse(Automation.url(for: command)) == command)
        }
    }

    @Test func fixedAreasDefaultToClipboard() {
        #expect(CaptureRequest(area: .fullScreen, outputs: []).effectiveOutputs == [.clipboard])
        #expect(CaptureRequest(area: .interactive, outputs: []).effectiveOutputs.isEmpty)
    }
}

@Suite struct CommandTextTests {
    @Test func splitsWithQuotes() {
        #expect(Automation.splitArguments(#"snip --area 0 0 10 10 -o "pin;~/My Shots/a.png""#)
            == ["snip", "--area", "0", "0", "10", "10", "-o", "pin;~/My Shots/a.png"])
        #expect(Automation.splitArguments("  paste  ") == ["paste"])
        #expect(Automation.splitArguments(#"a '' b"#) == ["a", "", "b"])
    }

    @Test func parsesTypedCommands() {
        #expect(Automation.parse(command: "snip --full -o clipboard") == .capture(CaptureRequest(area: .fullScreen, outputs: [.clipboard])))
        #expect(Automation.parse(command: " snap://toggle-pins ") == .togglePins)
        #expect(Automation.parse(command: "switch-group") == .nextPinGroup)
        #expect(Automation.parse(command: "rm -rf /") == nil)
        #expect(Automation.parse(command: "") == nil)
    }
}

@Suite struct SnappingTests {
    let other = CGRect(x: 100, y: 100, width: 200, height: 100)

    @Test func snapsSideBySide() {
        // Dropped 8pt right of the other rect's right edge, a bit lower: sticks to the edge and aligns the top.
        let r = Snapping.snap(CGRect(x: 308, y: 105, width: 50, height: 50), to: [other])
        #expect(r == CGRect(x: 300, y: 100, width: 50, height: 50))
    }

    @Test func leavesFarAwayRectsAlone() {
        let far = CGRect(x: 600, y: 400, width: 50, height: 50)
        #expect(Snapping.snap(far, to: [other]) == far)
        // Edge within reach horizontally, but vertically nowhere near: no snap.
        let apart = CGRect(x: 305, y: 500, width: 50, height: 50)
        #expect(Snapping.snap(apart, to: [other]) == apart)
    }

    @Test func snapsInsideScreenEdges() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(Snapping.snap(CGRect(x: 5, y: 790 - 60, width: 100, height: 60), to: [screen]).origin == CGPoint(x: 0, y: 740))
    }

    @Test func picksTheNearestEdge() {
        let a = CGRect(x: 100, y: 0, width: 10, height: 100), b = CGRect(x: 0, y: 0, width: 103, height: 100)
        #expect(Snapping.snap(CGRect(x: 104, y: 10, width: 20, height: 20), to: [a, b]).minX == 103)
    }
}

@Suite struct SuperSnipTests {
    @Test func dragWithModifiersMakesAnArea() {
        var t = SuperSnipTracker()
        #expect(t.handle(.down, at: CGPoint(x: 100, y: 100), modifiersHeld: true) == .track(nil))
        #expect(t.handle(.dragged, at: CGPoint(x: 60, y: 150), modifiersHeld: true) == .track(CGRect(x: 60, y: 100, width: 40, height: 50)))
        // Letting go of the keys mid-drag still finishes the drag that was started.
        #expect(t.handle(.up, at: CGPoint(x: 50, y: 160), modifiersHeld: false) == .finish(CGRect(x: 50, y: 100, width: 50, height: 60)))
        #expect(t.start == nil)
    }

    @Test func plainClicksPassThrough() {
        var t = SuperSnipTracker()
        #expect(t.handle(.down, at: .zero, modifiersHeld: false) == .pass)
        #expect(t.handle(.dragged, at: CGPoint(x: 10, y: 10), modifiersHeld: false) == .pass)
        #expect(t.handle(.up, at: CGPoint(x: 10, y: 10), modifiersHeld: false) == .pass)
    }

    @Test func tinyDragCancels() {
        var t = SuperSnipTracker()
        _ = t.handle(.down, at: CGPoint(x: 5, y: 5), modifiersHeld: true)
        #expect(t.handle(.up, at: CGPoint(x: 7, y: 6), modifiersHeld: true) == .cancel)
    }
}

@Suite struct HotCornerTests {
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: 0, width: 1920, height: 1080)]

    @Test func findsCorners() {
        let d = HotCornerDetector()
        #expect(d.corner(at: CGPoint(x: 0, y: 899), screens: screens)! == (.topLeft, 0))
        #expect(d.corner(at: CGPoint(x: 1439, y: 0), screens: screens)! == (.bottomRight, 0))
        #expect(d.corner(at: CGPoint(x: 1441, y: 1079), screens: screens)! == (.topLeft, 1))
        #expect(d.corner(at: CGPoint(x: 700, y: 899), screens: screens) == nil)
    }

    @Test func firesOnceAfterDwell() {
        var d = HotCornerDetector(dwell: 0.3)
        let t0 = Date(timeIntervalSince1970: 0)
        let corner = CGPoint(x: 1, y: 1)
        #expect(d.update(corner, screens: screens, now: t0) == nil)
        #expect(d.update(corner, screens: screens, now: t0.addingTimeInterval(0.2)) == nil)
        #expect(d.update(corner, screens: screens, now: t0.addingTimeInterval(0.35)) == .bottomLeft)
        #expect(d.update(corner, screens: screens, now: t0.addingTimeInterval(1)) == nil)
        // Leave and come back: fires again.
        #expect(d.update(CGPoint(x: 400, y: 400), screens: screens, now: t0.addingTimeInterval(1.1)) == nil)
        #expect(d.update(corner, screens: screens, now: t0.addingTimeInterval(1.2)) == nil)
        #expect(d.update(corner, screens: screens, now: t0.addingTimeInterval(1.6)) == .bottomLeft)
    }

    @Test func passingThroughDoesNotFire() {
        var d = HotCornerDetector(dwell: 0.3)
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(d.update(CGPoint(x: 1, y: 1), screens: screens, now: t0) == nil)
        #expect(d.update(CGPoint(x: 50, y: 50), screens: screens, now: t0.addingTimeInterval(0.1)) == nil)
        #expect(d.update(CGPoint(x: 1, y: 1), screens: screens, now: t0.addingTimeInterval(0.35)) == nil)
    }
}

@Suite struct SensitiveTextTests {
    func kinds(_ s: String) -> [SensitiveText.Kind] { SensitiveText.matches(in: s).map(\.kind) }
    func texts(_ s: String) -> [String] { SensitiveText.matches(in: s).map { String(s[$0.range]) } }

    @Test func findsPhonesAndEmails() {
        #expect(texts("联系人：张三 13812345678，邮箱 zhang.san@example.com") == ["13812345678", "zhang.san@example.com"])
        #expect(texts("电话 +86 138-1234-5678") == ["+86 138-1234-5678"])
        #expect(kinds("Call +1 415-555-0132 now") == [.phone])
    }

    @Test func findsIDsCardsAndSecrets() {
        #expect(kinds("身份证 11010519491231002X") == [.idCard])
        #expect(kinds("卡号 6222 0202 0000 0000 008") == [])        // fails Luhn
        #expect(kinds("Visa 4111 1111 1111 1111") == [.bankCard])   // passes Luhn
        #expect(kinds("OPENAI_API_KEY=sk-proj_abcdefghijklmnopqrstuv") == [.secret])
        #expect(kinds("AWS AKIAIOSFODNN7EXAMPLE") == [.secret])
    }

    @Test func leavesOrdinaryNumbersAlone() {
        #expect(kinds("订单 20260925153000，共 3 件，合计 128.50 元") == [])
        #expect(kinds("版本 2.11.3 于 2026-01-18 发布") == [])
    }
}

@Suite struct StructuredTextTests {
    func cell(_ t: String, _ x: CGFloat, _ y: CGFloat, w: CGFloat = 60) -> OCRLine { OCRLine(text: t, rect: CGRect(x: x, y: y, width: w, height: 16)) }

    @Test func rebuildsATable() {
        let lines = [
            cell("姓名", 10, 10), cell("城市", 120, 11), cell("分数", 230, 10),
            cell("张三", 10, 40), cell("北京", 121, 39), cell("95", 232, 40, w: 20),
            cell("李四", 11, 70), cell("上海", 120, 70), cell("88", 231, 71, w: 20),
        ]
        let grid = StructuredText.table(lines)
        #expect(grid == [["姓名", "城市", "分数"], ["张三", "北京", "95"], ["李四", "上海", "88"]])
        #expect(StructuredText.markdown(grid!) == "| 姓名 | 城市 | 分数 |\n| --- | --- | --- |\n| 张三 | 北京 | 95 |\n| 李四 | 上海 | 88 |")
    }

    @Test func emptyCellsStayInTheirColumn() {
        let lines = [cell("a", 10, 10), cell("b", 120, 10), cell("c", 230, 10),
                     cell("d", 10, 40), cell("f", 230, 40),
                     cell("g", 10, 70), cell("h", 120, 70), cell("i", 230, 70)]
        #expect(StructuredText.table(lines)?[1] == ["d", "", "f"])
    }

    @Test func rightAlignedAndCenteredColumnsStayTogether() {
        // Numbers right-aligned in column 2, grades centered in column 3: their left edges differ by far more than a few points.
        let lines = [
            cell("Product", 10, 10), cell("Q1 Sales", 140, 10, w: 56), cell("Grade", 240, 10, w: 40),
            cell("Wireless Mouse", 10, 40, w: 100), cell("12,480", 152, 40, w: 44), cell("A", 255, 40, w: 10),
            cell("USB-C Hub", 10, 70, w: 72), cell("8,315", 161, 70, w: 35), cell("B+", 252, 70, w: 16),
        ]
        #expect(StructuredText.table(lines) == [["Product", "Q1 Sales", "Grade"], ["Wireless Mouse", "12,480", "A"], ["USB-C Hub", "8,315", "B+"]])
    }

    @Test func spreadsheetWithRightAlignedNumbersAndSplitCells() {
        // Measured from a real screenshot of a two-column sheet: numbers are right-aligned, and Vision
        // returned "原始金额合计" and "（元）" as two boxes that touch (the second starts where the first ends).
        func c(_ t: String, _ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat) -> OCRLine { OCRLine(text: t, rect: CGRect(x: x0, y: y - 14, width: x1 - x0, height: 28)) }
        let lines = [
            c("指标", 118, 172, 163), c("数值", 545, 605, 163),
            c("记录总数", 118, 228, 198), c("190", 765, 820, 198),
            c("原始金额合计", 118, 283, 237), c("（元）", 284, 345, 237), c("¥16,036.74", 678, 820, 237),
            c("退款金额合计", 118, 283, 275), c("（元）", 284, 348, 275), c("¥2,411.84", 692, 820, 275),
            c("已领完记录数", 118, 283, 350), c("154", 770, 820, 350),
            c("退款/撤回记录数", 118, 316, 389), c("36", 780, 820, 389),
            c("来源图片", 118, 228, 465), c("记录数", 545, 633, 465),
            c("1.jpg", 118, 180, 503), c("160", 768, 820, 503),
        ]
        let grid = StructuredText.table(lines)
        #expect(grid?.first == ["指标", "数值"])
        #expect(grid?[2] == ["原始金额合计 （元）", "¥16,036.74"])
        #expect(grid?.last == ["1.jpg", "160"])
    }

    @Test func proseIsNotATable() {
        let lines = [OCRLine(text: "A paragraph of text that wraps", rect: CGRect(x: 10, y: 10, width: 300, height: 16)),
                     OCRLine(text: "onto a second line.", rect: CGRect(x: 10, y: 30, width: 180, height: 16))]
        #expect(StructuredText.table(lines) == nil)
    }

    @Test func keepsIndentation() {
        // 10pt per character.
        let lines = [OCRLine(text: "func f() {", rect: CGRect(x: 20, y: 10, width: 100, height: 14)),
                     OCRLine(text: "return 1", rect: CGRect(x: 60, y: 30, width: 80, height: 14)),
                     OCRLine(text: "}", rect: CGRect(x: 20, y: 50, width: 10, height: 14))]
        #expect(StructuredText.indented(lines) == "func f() {\n    return 1\n}")
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

@Suite struct ElementVisibilityTests {
    /// A white 200×200 screen (2 pixels per point), with dark "text" strokes (horizontal bars every 6 px)
    /// on the rows 40..<60 and 120..<140, spanning x 20..<180.
    static func page() -> PixelBuffer {
        let w = 400, h = 400
        var data = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h where (80..<120).contains(y) || (240..<280).contains(y) {
            for x in 40..<360 where y % 6 < 2 {
                let i = (y * w + x) * 4
                data[i] = 30; data[i + 1] = 30; data[i + 2] = 30
            }
        }
        // A grey button with a flat fill at 20,160 110×20 (points).
        for y in 320..<360 { for x in 40..<260 { let i = (y * w + x) * 4; data[i] = 200; data[i + 1] = 200; data[i + 2] = 200 } }
        return PixelBuffer(width: w, height: h, bytesPerRow: w * 4, data: data)
    }

    @Test func frameCuttingThroughTextIsRejected() {
        // A tall strip crossing both text rows, like an invisible web node.
        #expect(ElementVisibility.cutsThroughContent(CGRect(x: 90, y: 10, width: 30, height: 170), in: Self.page(), scale: 2))
    }

    @Test func framesOnBlankSpaceOrBordersAreKept() {
        let page = Self.page()
        // The paragraph around the first text row, with a little padding.
        #expect(!ElementVisibility.cutsThroughContent(CGRect(x: 15, y: 35, width: 170, height: 30), in: page, scale: 2))
        // The button: its edges sit on its fill's border.
        #expect(!ElementVisibility.cutsThroughContent(CGRect(x: 20, y: 160, width: 110, height: 20), in: page, scale: 2))
        // Empty space.
        #expect(!ElementVisibility.cutsThroughContent(CGRect(x: 20, y: 70, width: 100, height: 40), in: page, scale: 2))
    }

    @Test func hierarchySkipsRejectedFrames() {
        let nodes = [
            UIElementNode(rect: CGRect(x: 0, y: 0, width: 200, height: 200), parent: nil),   // 0 page
            UIElementNode(rect: CGRect(x: 15, y: 35, width: 170, height: 30), parent: 0),    // 1 paragraph
            UIElementNode(rect: CGRect(x: 90, y: 10, width: 30, height: 170), parent: 0),    // 2 invisible strip
        ]
        let hierarchy = ElementHierarchy(nodes: nodes, screenshot: Self.page(), scale: 2)
        #expect(hierarchy.excluded == [2])
        #expect(hierarchy.chain(at: CGPoint(x: 100, y: 50), within: nil) == [nodes[1].rect, nodes[0].rect])
        #expect(hierarchy.chain(at: CGPoint(x: 100, y: 100), within: nil) == [nodes[0].rect])
    }
}
