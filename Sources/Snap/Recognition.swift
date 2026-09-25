import AppKit
import SnapCore
import Vision

/// A piece of personal data or a secret found by OCR, with the box around just that text.
struct SensitiveRegion {
    var kind: SensitiveText.Kind
    var rect: CGRect
}

struct RecognitionResult {
    var lines: [OCRLine]
    var codes: [String]
    var sensitive: [SensitiveRegion] = []

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

            var sensitive: [SensitiveRegion] = []
            let lines = (textRequest.results ?? []).compactMap { observation -> OCRLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                for match in SensitiveText.matches(in: candidate.string) {
                    // Vision can box a substring, so only the matching characters get covered, not the whole line.
                    let box = (try? candidate.boundingBox(for: match.range))?.boundingBox ?? observation.boundingBox
                    sensitive.append(SensitiveRegion(kind: match.kind, rect: VisionGeometry.rect(fromNormalized: box, in: selection)))
                }
                return OCRLine(text: candidate.string,
                               rect: VisionGeometry.rect(fromNormalized: observation.boundingBox, in: selection))
            }
            let codes = (barcodeRequest.results ?? []).compactMap(\.payloadStringValue)
            return RecognitionResult(lines: lines, codes: codes, sensitive: sensitive)
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

/// Finds QR codes and barcodes anywhere on the screens, for "scan code" without taking a screenshot first.
enum CodeScanner {
    /// Payloads found in `images`, in order, without duplicates.
    static func scan(_ images: [CGImage]) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            var found: [String] = []
            for image in images {
                let request = VNDetectBarcodesRequest()
                try? VNImageRequestHandler(cgImage: image).perform([request])
                for payload in (request.results ?? []).compactMap(\.payloadStringValue) where !found.contains(payload) {
                    found.append(payload)
                }
            }
            return found
        }.value
    }

    /// Captures every screen, scans it, copies what was found and offers to open a link.
    static func scanScreens() {
        guard CaptureEngine.hasPermission else {
            CaptureSession.requestPermission()
            return
        }
        Task { @MainActor in
            do {
                let images = try await CaptureEngine.captureScreens().map(\.image)
                let codes = await scan(images)
                present(codes)
            } catch {
                HUD.show("扫码失败：\(error.localizedDescription)")
            }
        }
    }

    static func present(_ codes: [String]) {
        guard !codes.isEmpty else {
            HUD.show("屏幕上没有找到二维码或条形码")
            return
        }
        let text = codes.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let links = codes.compactMap { URL(string: $0) }.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        guard let link = links.first else {
            HUD.show(codes.count == 1 ? "已复制：\(text)" : "找到 \(codes.count) 个码，已全部复制")
            return
        }
        let alert = NSAlert()
        alert.messageText = codes.count == 1 ? "识别到链接，已复制" : "识别到 \(codes.count) 个码，已全部复制"
        alert.informativeText = link.absoluteString
        alert.addButton(withTitle: "在浏览器中打开")
        alert.addButton(withTitle: "好")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(link) }
    }
}
