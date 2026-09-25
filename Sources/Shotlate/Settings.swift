import AppKit
import Carbon.HIToolbox
import ShotlateCore

/// A global keyboard shortcut in Carbon terms, plus the key label shown in the UI.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var keyLabel: String

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(optionKey), keyLabel: "A")
    static let defaultPinClipboard = Shortcut(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(optionKey | shiftKey), keyLabel: "V")
    static let defaultTogglePins = Shortcut(keyCode: UInt32(kVK_ANSI_H), carbonModifiers: UInt32(optionKey | shiftKey), keyLabel: "H")

    init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        let functionKeyName = Self.functionKeys[Int(event.keyCode)]
        let isFunctionKey = functionKeyName != nil
        // A plain letter without modifiers would swallow normal typing everywhere.
        guard carbon != 0 || isFunctionKey else { return nil }
        let label: String
        if isFunctionKey {
            label = functionKeyName!
        } else if let chars = event.charactersIgnoringModifiers, !chars.isEmpty, chars != " " {
            label = chars.uppercased()
        } else if event.keyCode == UInt16(kVK_Space) {
            label = "Space"
        } else {
            label = "Key \(event.keyCode)"
        }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: carbon, keyLabel: label)
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyLabel
    }
}

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg
    var id: String { rawValue }
    var fileExtension: String { self == .png ? "png" : "jpg" }
}

/// App settings. Everything lives in UserDefaults except the API key, which has its own file (see `SecretFile`).
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("ShotlateSettingsDidChange")

    private let defaults = UserDefaults.standard

    var baseURL: String {
        get { defaults.string(forKey: "translate.baseURL") ?? TranslationConfig.defaultBaseURL }
        set { defaults.set(newValue, forKey: "translate.baseURL") }
    }

    var model: String {
        get { defaults.string(forKey: "translate.model") ?? TranslationConfig.defaultModel }
        set { defaults.set(newValue, forKey: "translate.model") }
    }

    var targetLanguage: String {
        get { defaults.string(forKey: "translate.targetLanguage") ?? TranslationConfig.defaultTargetLanguage }
        set { defaults.set(newValue, forKey: "translate.targetLanguage") }
    }

    /// In a file only the user can read, not the Keychain: a Keychain item asks for the login password again
    /// whenever the app's signature changes, which is every rebuild. An unbundled dev build (`.build/debug/Shotlate`)
    /// reads DEEPSEEK_API_KEY instead, so scripted runs never touch the real key.
    var apiKey: String {
        get {
            guard Bundle.main.bundleIdentifier != nil else { return ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] ?? "" }
            return SecretFile.read("api-key") ?? ""
        }
        set {
            guard Bundle.main.bundleIdentifier != nil else { return }
            SecretFile.write(newValue, "api-key")
        }
    }

    var saveDirectory: URL {
        get {
            if let path = defaults.string(forKey: "output.directory") { return URL(fileURLWithPath: path) }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        }
        set { defaults.set(newValue.path, forKey: "output.directory") }
    }

    var imageFormat: ImageFormat {
        get { ImageFormat(rawValue: defaults.string(forKey: "output.format") ?? "") ?? .png }
        set { defaults.set(newValue.rawValue, forKey: "output.format") }
    }

    var shortcut: Shortcut {
        get {
            guard let data = defaults.data(forKey: "capture.shortcut"),
                  let value = try? JSONDecoder().decode(Shortcut.self, from: data) else { return .default }
            return value
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "capture.shortcut") }
    }

    /// nil means the user cleared the shortcut.
    var pinClipboardShortcut: Shortcut? {
        get { optionalShortcut("pin.shortcut", default: .defaultPinClipboard) }
        set { setOptionalShortcut(newValue, "pin.shortcut") }
    }

    var togglePinsShortcut: Shortcut? {
        get { optionalShortcut("pin.toggleShortcut", default: .defaultTogglePins) }
        set { setOptionalShortcut(newValue, "pin.toggleShortcut") }
    }

    /// Not set by default: scanning is an occasional action and shouldn't take a key combination unasked.
    var scanCodeShortcut: Shortcut? {
        get {
            guard let data = defaults.data(forKey: "scan.shortcut") else { return nil }
            return try? JSONDecoder().decode(Shortcut.self, from: data)
        }
        set { setOptionalShortcut(newValue, "scan.shortcut") }
    }

    /// A missing key means "never set", which gets the default; empty data means the user cleared it.
    private func optionalShortcut(_ key: String, default value: Shortcut) -> Shortcut? {
        guard let data = defaults.data(forKey: key) else { return value }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    private func setOptionalShortcut(_ shortcut: Shortcut?, _ key: String) {
        defaults.set(shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
    }

    var translationConfig: TranslationConfig {
        TranslationConfig(baseURL: baseURL, model: model, apiKey: apiKey, targetLanguage: targetLanguage)
    }
}

/// Small secrets in `~/Library/Application Support/Shotlate`, readable and writable only by the user (0600).
enum SecretFile {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Shotlate", isDirectory: true)
    }

    static func read(_ name: String) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An empty value removes the file.
    static func write(_ value: String, _ name: String) {
        let url = directory.appendingPathComponent(name)
        let fm = FileManager.default
        guard !value.isEmpty else {
            try? fm.removeItem(at: url)
            return
        }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Created with 0600 before any bytes are written, so the key is never readable by others.
        fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try? Data(value.utf8).write(to: url)
    }
}
