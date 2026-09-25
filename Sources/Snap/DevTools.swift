import AppKit
import SnapCore

/// Command-line entry points for checking OCR and in-place translation without the capture UI.
///
///   Snap --translate-image input.png output.png [--scale 2]
///
/// Uses the API key from DEEPSEEK_API_KEY or the Keychain. Without a key it substitutes
/// placeholder translations so layout and rendering can still be checked.
enum DevTools {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if args.count >= 4, args[1] == "--ui-demo" {
            // Run inside the real event loop so async work (Vision, network) resumes on the main thread as in the app.
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                await UIDemo.run(input: URL(fileURLWithPath: args[2]), outputDirectory: URL(fileURLWithPath: args[3]))
                exit(0)
            }
            app.run()
        }
        if args.count >= 3, args[1] == "--check" {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                exit(await FeatureChecks.run(args[2], output: args.count >= 4 ? URL(fileURLWithPath: args[3]) : nil))
            }
            app.run()
        }
        if args.count >= 4, args[1] == "--stitch-diagnose" {
            func load(_ path: String) -> PixelBuffer? {
                guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
                return PixelBuffer(image: image)
            }
            if let a = load(args[2]), let b = load(args[3]) {
                print(ScrollStitcher(ignoredRightColumns: 36).diagnose(a, b))
            }
            exit(0)
        }
        if args.count >= 3, args[1] == "--scroll-demo" {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                ScrollDemo.run(output: URL(fileURLWithPath: args[2]))
            }
            app.run()
        }
        guard args.count >= 4, args[1] == "--translate-image" else { return }
        var scale: CGFloat = 1
        if let i = args.firstIndex(of: "--scale"), i + 1 < args.count, let s = Double(args[i + 1]) { scale = CGFloat(s) }
        do {
            try translateImage(input: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]), scale: scale)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func wait<T>(_ operation: @escaping () async throws -> T) throws -> T {
        var result: Result<T, Error>!
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    static func translateImage(input: URL, output: URL, scale: CGFloat) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw CocoaError(.fileReadCorruptFile) }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)

        let recognition = try wait { try await TextRecognizer.recognize(image, selection: bounds) }
        print("OCR lines: \(recognition.lines.count)")
        for line in recognition.lines { print("  \(line.rect.integral)  \(line.text)") }

        let blocks = TextBlockBuilder.group(recognition.lines).filter { TextBlockBuilder.shouldTranslate($0.text) }
        print("Blocks to translate: \(blocks.count)")
        for block in blocks { print("  #\(block.id) \(block.rect.integral)  \(block.text)") }

        var config = Settings.shared.translationConfig
        if let key = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !key.isEmpty { config.apiKey = key }
        let items = blocks.map { ChatTranslator.Item(id: $0.id, text: $0.text) }
        let translations: [Int: String]
        if config.apiKey.isEmpty {
            print("No API key: using placeholder translations")
            translations = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, placeholder(for: $0.text)) })
        } else {
            let started = Date()
            translations = try wait { try await ChatTranslator.translate(items, config: config) }
            print(String(format: "Translated with %@ in %.1fs", config.model, Date().timeIntervalSince(started)))
        }
        for (id, text) in translations.sorted(by: { $0.key < $1.key }) { print("  #\(id) → \(text)") }

        let laidOut = TranslationLayout.layout(blocks: blocks, translations: translations, crop: image, selection: bounds)
        for b in laidOut { print("  draw \(b.rect.integral) size \(b.fontSize) bold \(b.bold) bg \(b.background.hexString) fg \(b.foreground.hexString)") }

        let renderer = ContentRenderer(base: NSImage(cgImage: image, size: bounds.size), bounds: bounds, effect: { _ in NSImage() })
        guard let rep = Exporter.render(renderer: renderer, selection: bounds, scale: scale, items: [],
                                        translation: laidOut, options: ExportOptions(cornerRadius: 0, shadow: false, format: .png)),
              let data = Exporter.data(rep, format: .png)
        else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: output)
        print("Wrote \(output.path)")
    }

    /// Roughly the length a Chinese translation would have, so layout is realistic.
    private static func placeholder(for text: String) -> String {
        let sample = "这是一段用于检查排版效果的占位译文内容示例文字"
        let length = max(2, text.count / 3)
        return String(repeating: sample, count: length / sample.count + 1).prefix(length).description
    }
}

extension NSColor {
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "?" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
