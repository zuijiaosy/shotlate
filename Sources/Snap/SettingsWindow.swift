import AppKit
import SnapCore
import SwiftUI

final class SettingsModel: ObservableObject {
    @Published var baseURL = Settings.shared.baseURL
    @Published var model = Settings.shared.model
    @Published var apiKey = Settings.shared.apiKey
    @Published var targetLanguage = Settings.shared.targetLanguage
    @Published var saveDirectory = Settings.shared.saveDirectory
    @Published var imageFormat = Settings.shared.imageFormat
    @Published var shortcut = Settings.shared.shortcut
    @Published var isRecordingShortcut = false
    @Published var testResult: String?
    @Published var isTesting = false
    @Published var savedMessage: String?

    static let languages = ["简体中文", "繁體中文", "English", "日本語", "한국어"]

    var config: TranslationConfig {
        TranslationConfig(baseURL: baseURL, model: model, apiKey: apiKey, targetLanguage: targetLanguage)
    }

    func save() {
        let s = Settings.shared
        s.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        s.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        s.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        s.targetLanguage = targetLanguage
        s.saveDirectory = saveDirectory
        s.imageFormat = imageFormat
        s.shortcut = shortcut
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
        savedMessage = "已保存"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.savedMessage = nil }
    }

    func resetTranslationDefaults() {
        baseURL = TranslationConfig.defaultBaseURL
        model = TranslationConfig.defaultModel
        targetLanguage = TranslationConfig.defaultTargetLanguage
    }

    func testConnection() {
        isTesting = true
        testResult = nil
        let config = self.config
        Task { @MainActor in
            defer { isTesting = false }
            do {
                let result = try await ChatTranslator.translate([.init(id: 0, text: "Take a screenshot and translate it in place.")], config: config)
                testResult = result[0].map { "连接成功：\($0)" } ?? "连接成功，但没有返回译文"
            } catch {
                testResult = "失败：" + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveDirectory
        if panel.runModal() == .OK, let url = panel.url { saveDirectory = url }
    }

    private var monitor: Any?

    func startRecordingShortcut() {
        isRecordingShortcut = true
        NotificationCenter.default.post(name: .snapPauseHotKey, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Esc cancels recording
                self.stopRecordingShortcut()
                return nil
            }
            if let shortcut = Shortcut(event: event) {
                self.shortcut = shortcut
                self.stopRecordingShortcut()
            }
            return nil
        }
    }

    func stopRecordingShortcut() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecordingShortcut = false
        NotificationCenter.default.post(name: .snapResumeHotKey, object: nil)
    }
}

extension Notification.Name {
    static let snapPauseHotKey = Notification.Name("SnapPauseHotKey")
    static let snapResumeHotKey = Notification.Name("SnapResumeHotKey")
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("截图") {
                LabeledContent("快捷键") {
                    Button(model.isRecordingShortcut ? "请按下新的组合键…（Esc 取消）" : model.shortcut.displayString) {
                        model.isRecordingShortcut ? model.stopRecordingShortcut() : model.startRecordingShortcut()
                    }
                }
                LabeledContent("保存位置") {
                    HStack {
                        Text(model.saveDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("选择…") { model.chooseDirectory() }
                    }
                }
                Picker("保存格式", selection: $model.imageFormat) {
                    Text("PNG").tag(ImageFormat.png)
                    Text("JPG").tag(ImageFormat.jpeg)
                }
                .pickerStyle(.segmented)
            }

            Section {
                TextField("Base URL", text: $model.baseURL, prompt: Text(TranslationConfig.defaultBaseURL))
                TextField("模型", text: $model.model, prompt: Text(TranslationConfig.defaultModel))
                SecureField("API Key", text: $model.apiKey, prompt: Text("sk-…"))
                Picker("译成", selection: $model.targetLanguage) {
                    ForEach(SettingsModel.languages, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Button("测试连接") { model.testConnection() }
                        .disabled(model.isTesting || model.apiKey.isEmpty)
                    if model.isTesting { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("恢复默认") { model.resetTranslationDefaults() }
                }
                if let result = model.testResult {
                    Text(result)
                        .font(.callout)
                        .foregroundStyle(result.hasPrefix("失败") ? .red : .secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("翻译")
            } footer: {
                Text("使用 OpenAI 兼容接口，默认是 DeepSeek 的 deepseek-flash。API Key 保存在钥匙串中。发送给翻译服务的只有识别出的文字，截图本身不会上传。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                if let saved = model.savedMessage { Text(saved).foregroundStyle(.secondary) }
                Button("保存") { model.save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var model = SettingsModel()

    private init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Snap 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        // Reload so the window reflects what is stored, not a stale unsaved draft.
        model = SettingsModel()
        window?.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        window?.center()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if model.isRecordingShortcut { model.stopRecordingShortcut() }
    }
}
