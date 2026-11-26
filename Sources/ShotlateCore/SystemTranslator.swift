import Foundation
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

/// macOS's own on-device translation (the Translation framework): a few hundred milliseconds, offline, and not
/// an unofficial endpoint that can vanish. Creating a session outside SwiftUI needs macOS 26, and only language
/// pairs the user has downloaded work; anything it can't handle goes to Bilibili instead, so the default engine
/// never leaves the user without a translation.
public enum SystemTranslator {
    public static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    static func languageCode(_ language: String) -> String {
        switch language {
        case "繁體中文": return "zh-Hant"
        case "English": return "en"
        case "日本語": return "ja"
        case "한국어": return "ko"
        default: return "zh-Hans"
        }
    }

    /// Detected over all paragraphs at once: short labels like "Fixed" are too little text to tell on their own.
    static func sourceLanguage(_ texts: [String]) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(texts.joined(separator: "\n"))
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue
    }

    /// The framework leaves a space after full-width sentence punctuation ("重试。 30 秒后"), which looks broken in CJK.
    static func tidy(_ text: String, targetCode: String) -> String {
        guard targetCode.hasPrefix("zh") || targetCode == "ja" else { return text }
        return text.replacingOccurrences(of: #"([。！？；：，、])[ \t]+"#, with: "$1", options: .regularExpression)
    }

    /// Whether the pair English → target is downloaded (nil before macOS 26); Settings shows it next to the engine.
    public static func isInstalled(source: String = "en", targetLanguage: String) async -> Bool? {
        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            let status = await LanguageAvailability().status(from: Locale.Language(identifier: source),
                                                             to: Locale.Language(identifier: languageCode(targetLanguage)))
            return status == .installed
        }
        #endif
        return nil
    }

    public static func translate(_ items: [ChatTranslator.Item], config: TranslationConfig, session: URLSession = .shared) async throws -> [Int: String] {
        guard !items.isEmpty else { return [:] }
        #if canImport(Translation)
        if #available(macOS 26.0, *), let result = await translateOnDevice(items, targetLanguage: config.targetLanguage) {
            return result
        }
        #endif
        return try await BilibiliTranslator.translate(items, config: config, session: session)
    }

    #if canImport(Translation)
    /// A new session costs about a second before its first result, so one is kept per language pair.
    private final class SessionStore: @unchecked Sendable {
        private var sessions: [String: AnyObject] = [:]
        private let lock = NSLock()

        @available(macOS 26.0, *)
        func session(source: String, target: String) -> TranslationSession {
            lock.withLock {
                let key = source + ">" + target
                if let session = sessions[key] as? TranslationSession { return session }
                let session = TranslationSession(installedSource: Locale.Language(identifier: source),
                                                 target: Locale.Language(identifier: target))
                sessions[key] = session
                return session
            }
        }

        func drop(source: String, target: String) { lock.withLock { sessions[source + ">" + target] = nil } }
    }

    private static let store = SessionStore()

    /// nil means "can't do it here" (unknown language, pair not downloaded, framework error): use the fallback.
    @available(macOS 26.0, *)
    static func translateOnDevice(_ items: [ChatTranslator.Item], targetLanguage: String) async -> [Int: String]? {
        let target = languageCode(targetLanguage)
        guard let source = sourceLanguage(items.map(\.text)) else { return nil }
        let sourceLanguage = Locale.Language(identifier: source), targetLanguage = Locale.Language(identifier: target)
        // Already in the target language: nothing to translate.
        if sourceLanguage.languageCode == targetLanguage.languageCode, sourceLanguage.script == targetLanguage.script {
            return Dictionary(items.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        }
        guard await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage) == .installed else { return nil }
        let requests = items.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id)) }
        // A cached session can go stale (pack removed, translationd restarted), so one retry gets a fresh one.
        for _ in 0..<2 {
            do {
                let responses = try await store.session(source: source, target: target).translations(from: requests)
                var result: [Int: String] = [:]
                for response in responses {
                    guard let id = response.clientIdentifier.flatMap(Int.init), !response.targetText.isEmpty else { continue }
                    result[id] = tidy(response.targetText, targetCode: target)
                }
                return result
            } catch {
                store.drop(source: source, target: target)
            }
        }
        return nil
    }
    #endif
}
