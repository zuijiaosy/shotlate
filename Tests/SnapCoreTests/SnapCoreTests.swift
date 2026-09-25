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
