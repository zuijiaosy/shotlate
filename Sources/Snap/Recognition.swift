import AppKit
import SnapCore
import Vision

struct RecognitionResult {
    var lines: [OCRLine]
    var codes: [String]

    /// Recognized text in reading order: one line per OCR line, paragraphs kept together.
    var plainText: String {
        var parts = TextBlockBuilder.group(lines).map { $0.lines.map(\.text).joined(separator: "\n") }
        parts += codes
        return parts.joined(separator: "\n")
    }
}

enum TextRecognizer {
    /// Loads the recognition model in the background at launch. The first request in a process can
    /// take many seconds while the model is compiled; paying that before the user presses OCR hides it.
    static func warmUp() {
        Task.detached(priority: .utility) {
            let size = 64
            guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            guard let image = ctx.makeImage() else { return }
            _ = try? await recognize(image, selection: CGRect(x: 0, y: 0, width: size, height: size))
        }
    }

    /// Runs Vision text and barcode recognition on `image`, the pixels of `selection`.
    /// Returned line rects are in the same coordinate space as `selection`.
    static func recognize(_ image: CGImage, selection: CGRect) async throws -> RecognitionResult {
        try await Task.detached(priority: .userInitiated) {
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            textRequest.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
            textRequest.automaticallyDetectsLanguage = true
            let barcodeRequest = VNDetectBarcodesRequest()
            try VNImageRequestHandler(cgImage: image).perform([textRequest, barcodeRequest])

            let lines = (textRequest.results ?? []).compactMap { observation -> OCRLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return OCRLine(text: candidate.string,
                               rect: VisionGeometry.rect(fromNormalized: observation.boundingBox, in: selection))
            }
            let codes = (barcodeRequest.results ?? []).compactMap(\.payloadStringValue)
            return RecognitionResult(lines: lines, codes: codes)
        }.value
    }
}

enum TranslationLayout {
    static let minimumFontSize: CGFloat = 9

    /// Turns translated paragraphs into drawable blocks: samples colors from `crop`
    /// (the pixels of `selection`) and fits the font size to each paragraph's box.
    static func layout(blocks: [TextBlock], translations: [Int: String], crop: CGImage, selection: CGRect) -> [TranslatedBlock] {
        guard let buffer = PixelBuffer(image: crop), selection.width > 0 else { return [] }
        let scale = CGFloat(crop.width) / selection.width
        return blocks.compactMap { block in
            guard let text = translations[block.id] else { return nil }
            let rect = block.rect
            let pixelRect = CGRect(x: (rect.minX - selection.minX) * scale, y: (rect.minY - selection.minY) * scale,
                                   width: rect.width * scale, height: rect.height * scale)
            let colors = ColorSampler.sample(buffer, rect: pixelRect, ring: max(2, Int(scale * 2)))
            // Bold stems are clearly thicker relative to the line height than regular ones.
            let strokeRatio = colors.strokeWidth / Double(max(1, block.lineHeight * scale))
            let bold = strokeRatio > 0.17
            if ProcessInfo.processInfo.environment["SNAP_DEBUG_LAYOUT"] != nil {
                print("  block #\(block.id) stroke \(String(format: "%.3f", strokeRatio)) centered \(colors.isCentered)")
            }
            let (fontSize, height) = fit(text, in: rect, lineHeight: block.lineHeight, bold: bold)
            var drawRect = rect
            drawRect.size.height = max(rect.height, height)
            return TranslatedBlock(rect: drawRect, text: text, fontSize: fontSize, bold: bold, centered: colors.isCentered,
                                   background: color(colors.background), foreground: color(colors.foreground))
        }
    }

    /// Starts near the original text size and shrinks by 0.5pt until the text fits the box,
    /// stopping at the minimum size; the returned height may then exceed the box.
    static func fit(_ text: String, in rect: CGRect, lineHeight: CGFloat, bold: Bool) -> (CGFloat, CGFloat) {
        var size = max(minimumFontSize, min(lineHeight * 0.85, 64))
        while true {
            let height = ContentRenderer.attributedText(text, size: size, bold: bold, color: .black)
                .boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                              options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            if height <= rect.height + lineHeight * 0.25 || size <= minimumFontSize {
                return (size, ceil(height))
            }
            size -= 0.5
        }
    }

    static func color(_ c: RGBA) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }
}
