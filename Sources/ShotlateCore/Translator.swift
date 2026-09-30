import Foundation

/// Which service translates: the built-in free one needs no setup, the LLM one needs the user's own API key.
public enum TranslationEngine: String, CaseIterable, Sendable {
    case free
    case llm
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
            return "免费翻译暂时不可用（\(detail)）。可以在设置 → 翻译 中改用大模型。"
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

/// Client for Tencent TranSmart's public web endpoint (no key; unofficial, so failures point users at the LLM engine).
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

    /// Splits long items too, retaining their IDs so translations can be reassembled in order.
    static func batches(_ items: [ChatTranslator.Item], limit: Int = batchLimit) -> [[ChatTranslator.Item]] {
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

    static func send(_ batch: [ChatTranslator.Item], config: TranslationConfig, session: URLSession) async throws -> [String] {
        let request = try makeRequest(texts: batch.map(\.text), config: config)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranslationError.service(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TranslationError.service("HTTP \(http.statusCode)")
        }
        return try parseResponse(data, expected: batch.count)
    }

    public static func translate(_ items: [ChatTranslator.Item], config: TranslationConfig, session: URLSession = .shared) async throws -> [Int: String] {
        guard !items.isEmpty else { return [:] }
        let requests = batches(items)
        return try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
            for (index, batch) in requests.enumerated() {
                group.addTask { (index, try await send(batch, config: config, session: session)) }
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
}

/// The one entry point callers use: picks the service from the settings.
public enum Translator {
    public static func translate(_ items: [ChatTranslator.Item], config: TranslationConfig, session: URLSession = .shared) async throws -> [Int: String] {
        switch config.engine {
        case .free: return try await FreeTranslator.translate(items, config: config, session: session)
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
        [config.engine == .free ? "free" : config.model, config.targetLanguage, text].joined(separator: "\u{1F}")
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
