import Foundation

/// Which service translates: the free web engines need no setup, the LLM one needs the user's own API key.
public enum TranslationEngine: String, CaseIterable, Sendable {
    /// macOS's on-device translation: the default where available (macOS 26+), listed first in Settings.
    case system
    /// The default before macOS 26, and the fallback for whatever `system` can't translate.
    case bilibili
    /// Tencent TranSmart. The raw value dates from when it was the only free engine; saved settings still use it.
    case free
    case google
    case bing
    case llm

    public var needsAPIKey: Bool { self == .llm }

    /// Engines this Mac can use; `system` needs macOS 26.
    public var isAvailable: Bool { self != .system || SystemTranslator.isSupported }

    public var displayName: String {
        switch self {
        case .system: return "系统翻译"
        case .free: return "腾讯翻译"
        case .google: return "谷歌翻译"
        case .bing: return "必应翻译"
        case .bilibili: return "B站 Index"
        case .llm: return "大模型"
        }
    }
}

public struct TranslationConfig: Equatable, Sendable {
    public var engine: TranslationEngine
    /// Random per-install id the free service expects in its request header.
    public var clientKey: String
    public var baseURL: String
    public var model: String
    public var apiKey: String
    public var targetLanguage: String
    public var timeout: TimeInterval

    public init(baseURL: String, model: String, apiKey: String, targetLanguage: String, timeout: TimeInterval = 20,
                engine: TranslationEngine = .llm, clientKey: String = "") {
        self.engine = engine
        self.clientKey = clientKey
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.targetLanguage = targetLanguage
        self.timeout = timeout
    }

    public static let defaultBaseURL = "https://api.deepseek.com"
    public static let defaultModel = "deepseek-flash"
    public static let defaultTargetLanguage = "简体中文"
}

public enum TranslationError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidBaseURL(String)
    case http(status: Int, message: String)
    case badResponse(String)
    case service(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "还没有填写 API Key。请在菜单栏 Shotlate → 设置 中填写。"
        case .invalidBaseURL(let url):
            return "Base URL 无效：\(url)"
        case .http(let status, let message):
            switch status {
            case 401: return "API Key 无效（401）。请在设置中检查 Key。"
            case 402: return "账户余额不足（402）。"
            case 429: return "请求太频繁（429），请稍后再试。"
            default: return "翻译服务返回错误 \(status)：\(message)"
            }
        case .badResponse(let detail):
            return "翻译结果无法解析：\(detail)"
        case .service(let detail):
            return "免费翻译暂时不可用（\(detail)）。可以在设置 → 翻译 中换一个引擎。"
        }
    }
}

/// Client for OpenAI-compatible chat completion APIs (DeepSeek by default).
/// Sends all blocks of one screenshot in a single request so the model sees the whole context.
public enum ChatTranslator {
    public struct Item: Equatable, Sendable {
        public var id: Int
        public var text: String

        public init(id: Int, text: String) {
            self.id = id
            self.text = text
        }
    }

    static func systemPrompt(targetLanguage: String) -> String {
        """
        你是软件界面与文档翻译器。把输入中每一项的 text 翻译成\(targetLanguage)，译文简洁自然，符合界面用语习惯。
        代码、文件路径、网址、数字、快捷键和产品名保持原样。
        只输出 JSON，格式为 {"items":[{"id":0,"t":"译文"}]}，id 与输入一一对应，不要遗漏或增加条目。
        """
    }

    public static func makeRequest(items: [Item], config: TranslationConfig) throws -> URLRequest {
        guard !config.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else { throw TranslationError.missingAPIKey }
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions"), url.scheme?.hasPrefix("http") == true, url.host != nil else {
            throw TranslationError.invalidBaseURL(config.baseURL)
        }

        let input: [String: Any] = ["items": items.map { ["id": $0.id, "text": $0.text] }]
        let inputJSON = String(decoding: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]), as: UTF8.self)
        let body: [String: Any] = [
            "model": config.model,
            "response_format": ["type": "json_object"],
            "temperature": 0.3,
            "stream": false,
            "messages": [
                ["role": "system", "content": systemPrompt(targetLanguage: config.targetLanguage)],
                ["role": "user", "content": inputJSON],
            ],
        ]

        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey.trimmingCharacters(in: .whitespaces))", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Parses a chat completion response into `id → translation`.
    /// Items the model dropped are simply absent; callers keep the original text for them.
    public static func parseResponse(_ data: Data) throws -> [Int: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw TranslationError.badResponse("缺少 choices[0].message.content") }
        return try parseContent(content)
    }

    static func parseContent(_ content: String) throws -> [Int: String] {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some models wrap JSON in a Markdown code fence despite json_object mode.
        if text.hasPrefix("```") {
            text = text.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if let fence = text.range(of: "```", options: .backwards) { text = String(text[..<fence.lowerBound]) }
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let items = object["items"] as? [[String: Any]]
        else { throw TranslationError.badResponse("返回内容不是预期的 JSON") }

        var result: [Int: String] = [:]
        for item in items {
            let id: Int?
            switch item["id"] {
            case let n as Int: id = n
            case let s as String: id = Int(s)
            default: id = nil
            }
            let translation = (item["t"] ?? item["zh"] ?? item["translation"]) as? String
            if let id, let translation, !translation.isEmpty { result[id] = translation }
        }
        return result
    }

    static func errorMessage(from data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = root["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }

    public static func translate(_ items: [Item], config: TranslationConfig, session: URLSession = .shared) async throws -> [Int: String] {
        guard !items.isEmpty else { return [:] }
        let request = try makeRequest(items: items, config: config)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TranslationError.http(status: http.statusCode, message: errorMessage(from: data))
        }
        return try parseResponse(data)
    }
}

/// Plumbing shared by the keyless web engines: batching, error mapping and reassembly.
enum WebTranslation {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

    /// Splits long items too, retaining their IDs so translations can be reassembled in order.
    static func batches(_ items: [ChatTranslator.Item], limit: Int) -> [[ChatTranslator.Item]] {
        precondition(limit >= 2)
        var result: [[ChatTranslator.Item]] = []
        var current: [ChatTranslator.Item] = []
        var count = 0
        for item in items {
            var chunks: [String] = []
            var chunk = ""
            var length = 0
            // Count UTF-16 units conservatively without splitting surrogate pairs.
            for scalar in item.text.unicodeScalars {
                let size = scalar.utf16.count
                if length + size > limit {
                    chunks.append(chunk)
                    chunk = ""
                    length = 0
                }
                chunk.unicodeScalars.append(scalar)
                length += size
            }
            if !chunk.isEmpty || chunks.isEmpty { chunks.append(chunk) }
            for text in chunks {
                let size = text.utf16.count
                if !current.isEmpty, count + size > limit {
                    result.append(current)
                    current = []
                    count = 0
                }
                current.append(.init(id: item.id, text: text))
                count += size
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// These services are unofficial, so any transport failure is reported as "the free service is down".
    static func load(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse?) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, response as? HTTPURLResponse)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranslationError.service(error.localizedDescription)
        }
    }

    static func fetch(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await load(request, session: session)
        if let response, !(200..<300).contains(response.statusCode) {
            throw TranslationError.service("HTTP \(response.statusCode)")
        }
        return data
    }

    /// Sends the batches concurrently; `send` returns one translation per item of its batch, in order.
    static func translate(_ items: [ChatTranslator.Item], limit: Int,
                          send: @escaping @Sendable ([ChatTranslator.Item]) async throws -> [String]) async throws -> [Int: String] {
        guard !items.isEmpty else { return [:] }
        let requests = batches(items, limit: limit)
        return try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
            for (index, batch) in requests.enumerated() {
                group.addTask { (index, try await send(batch)) }
            }
            var responses = Array(repeating: [String](), count: requests.count)
            for try await (index, texts) in group { responses[index] = texts }
            var merged: [Int: String] = [:]
            for (batch, texts) in zip(requests, responses) {
                for (item, text) in zip(batch, texts) {
                    // An empty fragment must not discard that part of the original paragraph.
                    merged[item.id, default: ""] += text.isEmpty ? item.text : text
                }
            }
            return merged
        }
    }

    /// One request per item, a few at a time: the fallback when a joined batch comes back misaligned.
    static func each(_ items: [ChatTranslator.Item], concurrency: Int = 4,
                     _ translate: @escaping @Sendable (String) async throws -> String) async throws -> [String] {
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var result = Array(repeating: "", count: items.count)
            var next = 0
            func start() {
                guard next < items.count else { return }
                let index = next, text = items[index].text
                next += 1
                group.addTask { (index, try await translate(text)) }
            }
            for _ in 0..<concurrency { start() }
            for try await (index, text) in group {
                result[index] = text
                start()
            }
            return result
        }
    }

    /// `application/x-www-form-urlencoded`, which allows repeated keys (Google wants one `q` per text).
    static func formBody(_ fields: [(String, String)]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encode = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return Data(fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&").utf8)
    }

    static func formRequest(_ url: URL, fields: [(String, String)], timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = formBody(fields)
        return request
    }
}

/// Client for Tencent TranSmart's public web endpoint (no key; unofficial, so failures point users at another engine).
/// It takes a whole list of texts per request but rejects a request over roughly 5000 characters, hence the batching.
public enum FreeTranslator {
    static let endpoint = URL(string: "https://transmart.qq.com/api/imt")!
    static let batchLimit = 4000

    /// Language names shown in Settings → codes the service accepts.
    static func languageCode(_ language: String) -> String {
        switch language {
        case "繁體中文": return "zh-TW"
        case "English": return "en"
        case "日本語": return "ja"
        case "한국어": return "ko"
        default: return "zh"
        }
    }

    static func makeRequest(texts: [String], config: TranslationConfig) throws -> URLRequest {
        let clientKey = config.clientKey.isEmpty ? "browser-chrome-110.0.0-Mac OS-shotlate" : config.clientKey
        let body: [String: Any] = [
            "header": ["fn": "auto_translation", "client_key": clientKey],
            "type": "plain",
            "model_category": "normal",
            "source": ["lang": "auto", "text_list": texts],
            "target": ["lang": languageCode(config.targetLanguage)],
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Returns the translations in request order. A count mismatch would shift every later paragraph, so it is an error.
    static func parseResponse(_ data: Data, expected: Int) throws -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = root["header"] as? [String: Any]
        else { throw TranslationError.badResponse("返回内容不是预期的 JSON") }
        let code = header["ret_code"] as? String ?? "unknown"
        guard code == "succ" else { throw TranslationError.service(code) }
        guard let texts = root["auto_translation"] as? [String], texts.count == expected else {
            throw TranslationError.badResponse("译文数量与原文不一致")
        }
        return texts
    }

    public static func translate(_ items: [ChatTranslator.Item], config: TranslationConfig, session: URLSession = .shared) async throws -> [Int: String] {
        try await WebTranslation.translate(items, limit: batchLimit) { batch in
            let data = try await WebTranslation.fetch(try makeRequest(texts: batch.map(\.text), config: config), session: session)
            return try parseResponse(data, expected: batch.count)
        }
    }
}

/// Google's endpoint for Chrome's translate extension: plain text, many `q` per request, no key.
/// Unofficial and not reachable from mainland China without a proxy (URLSession follows the system proxy).
public enum GoogleTranslator {
    static let batchLimit = 4000

    static func languageCode(_ language: String) -> String {
        switch language {
        case "繁體中文": return "zh-TW"
        case "English": return "en"
        case "日本語": return "ja"
        case "한국어": return "ko"
        default: return "zh-CN"
        }
    }

    static func makeRequest(texts: [String], config: TranslationConfig) -> URLRequest {
        var components = URLComponents(string: "https://clients5.google.com/translate_a/t")!
        components.queryItems = [
            .init(name: "client", value: "dict-chrome-ex"),
            .init(name: "sl", value: "auto"),
            .init(name: "tl", value: languageCode(config.targetLanguage)),
        ]
        return WebTranslation.formRequest(components.url!, fields: texts.map { ("q", $0) }, timeout: config.timeout)
    }

    /// With `sl=auto` each entry is `[translation, detectedLanguage]`; a fixed source language gives bare strings.
    static func parseResponse(_ data: Data, expected: Int) throws -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw TranslationError.badResponse("返回内容不是预期的 JSON")
        }
        let texts = root.compactMap { entry -> String? in
            if let text = entry as? String { return text }
            return (entry as? [Any])?.first as? String
        }
        guard texts.count == expected, root.count == expected else { throw TranslationError.badResponse("译文数量与原文不一致") }
        return texts
    }

    public static func translate(_ items: [ChatTranslator.Item], config: TranslationConfig, session: URLSession = .shared) async throws -> [Int: String] {
        try await WebTranslation.translate(items, limit: batchLimit) { batch in
            let data = try await WebTranslation.fetch(makeRequest(texts: batch.map(\.text), config: config), session: session)
            return try parseResponse(data, expected: batch.count)
        }
    }
}

/// Bing Translator's web endpoint. It needs the IG / IID / key / token embedded in the translator page,
/// so the page is fetched once and its token reused until it expires (about an hour) or gets rejected.
/// One text per request, at most 5000 characters: paragraphs are joined by newlines and split again.
public enum BingTranslator {
    struct Token: Equatable, Sendable {
        var host: String
        var ig: String
        var iid: String
        var key: String
        var token: String
        var expires: Date
    }

    private final class TokenStore: @unchecked Sendable {
        private var token: Token?
        private let lock = NSLock()
        func get(now: Date) -> Token? { lock.withLock { token.flatMap { $0.expires > now ? $0 : nil } } }
        func set(_ value: Token?) { lock.withLock { token = value } }
    }

    private static let store = TokenStore()
    /// www.bing.com redirects mainland users to cn.bing.com; the token only works on the host that issued it.
    static let page = URL(string: "https://www.bing.com/translator")!
    /// Joined texts plus their newline separators must stay under the 5000-character limit.
    static let batchLimit = 2500

    static func languageCode(_ language: String) -> String {
        switch language {
        case "繁體中文": return "zh-Hant"
        case "English": return "en"
        case "日本語": return "ja"
        case "한국어": return "ko"
        default: return "zh-Hans"
        }
    }

    static func parseToken(html: String, host: String, now: Date = Date()) -> Token? {
        guard let ig = html.firstMatch(of: #/IG:"([0-9A-Fa-f]+)"/#)?.1,
              let iid = html.firstMatch(of: #/data-iid="([^"]+)"/#)?.1,
              let helper = html.firstMatch(of: #/params_AbusePreventionHelper\s*=\s*\[(\d+),"([^"]+)",(\d+)/#)
        else { return nil }
        // Renew a minute early so a request never goes out with a token that expires on the way.
        let lifetime = (TimeInterval(helper.3) ?? 600_000) / 1000
        return Token(host: host, ig: String(ig), iid: String(iid), key: String(helper.1), token: String(helper.2),
                     expires: now.addingTimeInterval(max(lifetime - 60, 60)))
    }

    static func token(config: TranslationConfig, session: URLSession, refresh: Bool) async throws -> Token {
        if !refresh, let token = store.get(now: Date()) { return token }
        var request = URLRequest(url: page, timeoutInterval: config.timeout)
        request.setValue(WebTranslation.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await WebTranslation.load(request, session: session)
        let host = response?.url?.host ?? page.host!
        guard let token = parseToken(html: String(decoding: data, as: UTF8.self), host: host) else {
            throw TranslationError.service("没有拿到必应的访问令牌")
        }
        store.set(token)
        return token
    }

    static func makeRequest(text: String, token: Token, config: TranslationConfig) -> URLRequest {
        let url = URL(string: "https://\(token.host)/ttranslatev3?isVertical=1&IG=\(token.ig)&IID=\(token.iid).1")!
        var request = WebTranslation.formRequest(url, fields: [
            ("fromLang", "auto-detect"), ("to", languageCode(config.targetLanguage)),
            ("text", text), ("token", token.token), ("key", token.key),
        ], timeout: config.timeout)
        // Without the referer the endpoint answers 200 with an empty body.
        request.setValue("https://\(token.host)/translator", forHTTPHeaderField: "Referer")
        return request
    }

    /// nil means the token was refused (an empty body or `{"statusCode":205}`), so it is worth fetching a new one.
    /// The same goes for HTTP 401, handled in `translateText`.
    static func parseResponse(_ data: Data) throws -> String? {
        guard !data.isEmpty, let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if root is [String: Any] { return nil }
        guard let first = (root as? [[String: Any]])?.first,
              let translations = first["translations"] as? [[String: Any]],
              let text = translations.first?["text"] as? String
        else { throw TranslationError.badResponse("缺少 translations[0].text") }
        return text
    }

    static func translateText(_ text: String, config: TranslationConfig, session: URLSession) async throws -> String {
        // Cached token, then a fresh one, then that fresh one again: behind a proxy that rotates its exit IP,
        // even a brand-new token is sometimes refused once and accepted on the next try.
        for attempt in 0..<3 {
            let token = try await token(config: config, session: session, refresh: attempt == 1)
            let (data, response) = try await WebTranslation.load(makeRequest(text: text, token: token, config: config), session: session)
            let status = response?.statusCode ?? 200
            if status == 401 { continue }
            guard (200..<300).contains(status) else { throw TranslationError.service("HTTP \(status)") }
            if let translation = try parseResponse(data) { return translation }
        }
        store.set(nil)
        throw TranslationError.service("必应拒绝了请求")
    }

    static func send(_ batch: [ChatTranslator.Item], config: TranslationConfig, session: URLSession) async throws -> [String] {
        let texts = batch.map { $0.text.replacingOccurrences(of: "\n", with: " ") }
        let lines = try await translateText(texts.joined(separator: "\n"), config: config, session: session)
            .components(separatedBy: "\n")
        if lines.count == batch.count { return lines }
        // Bing sometimes merges short neighbouring lines; translate them one by one rather than misalign them.
        return try await WebTranslation.each(batch) { try await translateText($0, config: config, session: session) }
    }

    public static func translate(_ items: [ChatTranslator.Item], config: TranslationConfig, session: URLSession = .shared) async throws -> [Int: String] {
        try await WebTranslation.translate(items, limit: batchLimit) { try await send($0, config: config, session: session) }
    }
}

/// Bilibili's free public Index-Translate API: an OpenAI-compatible endpoint for a dedicated translation model, no key.
/// Several paragraphs go out as one JSON object using the model's own instruction format; if the reply is not
/// that JSON, the batch is retried one paragraph at a time.
public enum BilibiliTranslator {
    static let endpoint = URL(string: "https://index-translate.bilibili.com/v1/chat/completions")!
    static let model = "Index-Translate-35B-A3B"
    /// Keeps each reply short enough to come back well within the timeout.
    static let batchLimit = 2000

    /// The model is prompted in Chinese and expects the target language's Chinese name.
    static func languageName(_ language: String) -> String {
        switch language {
        case "繁體中文": return "繁体中文"
        case "English": return "英语"
        case "日本語": return "日语"
        case "한국어": return "韩语"
        default: return "简体中文"
        }
    }

    /// The prompts follow `inference/llm/call_api.py` in bilibili/Index-Translate, which the model was trained on.
    static func prompt(texts: [String], targetLanguage: String) -> String {
        let target = languageName(targetLanguage)
        guard texts.count > 1 else {
            return "请将以下文本翻译为\(target)，直接输出翻译结果，不要进行任何解释。\n\n\(texts.first ?? "")"
        }
        // Keys in numeric order (a sorted dictionary would put "10" before "2").
        let fields = texts.enumerated().map { index, text in
            let value = (try? JSONSerialization.data(withJSONObject: [text])).map { String(decoding: $0, as: UTF8.self).dropFirst().dropLast() }
            return "\"\(index)\": \(value ?? "\"\"")"
        }
        return """
        请将以下文本翻译成\(target)，并且严格遵循所有约束要求。

        【源文】
        {\(fields.joined(separator: ", "))}

        【约束要求】
        1. 【注意】严格保留合法 JSON 语法格式，仅翻译 value 文本

        请以相同的 JSON 格式输出翻译结果，key 保持不变，value 为对应译文。只输出 JSON，不要有任何额外说明。
        """
    }

    static func makeRequest(prompt: String, config: TranslationConfig) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0,
            "max_tokens": 8192,
            "stream": false,
            // The model would otherwise spend the reply on a reasoning block.
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: max(config.timeout, 45))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Shotlate", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func content(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              var text = message["content"] as? String
        else { throw TranslationError.badResponse("缺少 choices[0].message.content") }
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// nil when the reply is not the expected JSON object; keys the model dropped come back empty (original kept).
    static func parseBatch(_ content: String, expected: Int) -> [String]? {
        var text = content
        if text.hasPrefix("```") {
            text = text.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if let fence = text.range(of: "```", options: .backwards) { text = String(text[..<fence.lowerBound]) }
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return (0..<expected).map { object[String($0)] as? String ?? "" }
    }

    static func translateText(_ text: String, config: TranslationConfig, session: URLSession) async throws -> String {
        let request = try makeRequest(prompt: prompt(texts: [text], targetLanguage: config.targetLanguage), config: config)
        return try content(await WebTranslation.fetch(request, session: session))
    }

    static func send(_ batch: [ChatTranslator.Item], config: TranslationConfig, session: URLSession) async throws -> [String] {
        if batch.count == 1 { return [try await translateText(batch[0].text, config: config, session: session)] }
        let request = try makeRequest(prompt: prompt(texts: batch.map(\.text), targetLanguage: config.targetLanguage), config: config)
        let reply = try content(await WebTranslation.fetch(request, session: session))
        if let texts = parseBatch(reply, expected: batch.count) { return texts }
        return try await WebTranslation.each(batch) { try await translateText($0, config: config, session: session) }
    }

    public static func translate(_ items: [ChatTranslator.Item], config: TranslationConfig, session: URLSession = .shared) async throws -> [Int: String] {
        try await WebTranslation.translate(items, limit: batchLimit) { try await send($0, config: config, session: session) }
    }
}

/// The one entry point callers use: picks the service from the settings.
public enum Translator {
    public static func translate(_ items: [ChatTranslator.Item], config: TranslationConfig, session: URLSession = .shared) async throws -> [Int: String] {
        switch config.engine {
        case .system: return try await SystemTranslator.translate(items, config: config, session: session)
        case .free: return try await FreeTranslator.translate(items, config: config, session: session)
        case .google: return try await GoogleTranslator.translate(items, config: config, session: session)
        case .bing: return try await BingTranslator.translate(items, config: config, session: session)
        case .bilibili: return try await BilibiliTranslator.translate(items, config: config, session: session)
        case .llm: return try await ChatTranslator.translate(items, config: config, session: session)
        }
    }
}

/// In-memory cache so toggling or re-translating the same text costs nothing.
public final class TranslationCache: @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    static func key(_ text: String, _ config: TranslationConfig) -> String {
        [config.engine == .llm ? config.model : config.engine.rawValue, config.targetLanguage, text].joined(separator: "\u{1F}")
    }

    public func get(_ text: String, config: TranslationConfig) -> String? {
        lock.withLock { storage[Self.key(text, config)] }
    }

    public func set(_ translation: String, for text: String, config: TranslationConfig) {
        lock.withLock { storage[Self.key(text, config)] = translation }
    }

    /// Translates `items`, sending only the texts that are not cached yet.
    public func translate(_ items: [ChatTranslator.Item], config: TranslationConfig,
                          send: ([ChatTranslator.Item]) async throws -> [Int: String]) async throws -> [Int: String] {
        var result: [Int: String] = [:]
        var missing: [ChatTranslator.Item] = []
        for item in items {
            if let cached = get(item.text, config: config) { result[item.id] = cached } else { missing.append(item) }
        }
        if !missing.isEmpty {
            let fresh = try await send(missing)
            for item in missing {
                if let t = fresh[item.id] {
                    result[item.id] = t
                    set(t, for: item.text, config: config)
                }
            }
        }
        return result
    }
}
