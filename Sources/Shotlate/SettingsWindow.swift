import AppKit
import ServiceManagement
import ShotlateCore
import SwiftUI

enum ShortcutTarget: Equatable { case capture, pinClipboard, togglePins, scanCode }

/// Every change is written through right away; there is no save button.
final class SettingsModel: ObservableObject {
    private let settings = Settings.shared

    @Published var baseURL = Settings.shared.baseURL { didSet { settings.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines) } }
    @Published var model = Settings.shared.model { didSet { settings.model = model.trimmingCharacters(in: .whitespacesAndNewlines) } }
    @Published var apiKey = "" { didSet { if loadsSecrets { settings.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines) } } }
    @Published var targetLanguage = Settings.shared.targetLanguage { didSet { settings.targetLanguage = targetLanguage } }
    @Published var saveDirectory = Settings.shared.saveDirectory { didSet { settings.saveDirectory = saveDirectory } }
    @Published var imageFormat = Settings.shared.imageFormat { didSet { settings.imageFormat = imageFormat } }
    @Published var shortcut = Settings.shared.shortcut { didSet { settings.shortcut = shortcut; shortcutsChanged() } }
    @Published var pinShortcut = Settings.shared.pinClipboardShortcut { didSet { settings.pinClipboardShortcut = pinShortcut; shortcutsChanged() } }
    @Published var togglePinsShortcut = Settings.shared.togglePinsShortcut { didSet { settings.togglePinsShortcut = togglePinsShortcut; shortcutsChanged() } }
    @Published var scanCodeShortcut = Settings.shared.scanCodeShortcut { didSet { settings.scanCodeShortcut = scanCodeShortcut; shortcutsChanged() } }
    @Published var recording: ShortcutTarget?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled { didSet { applyLaunchAtLogin() } }
    @Published var loginItemError: String?
    @Published var testResult: String?
    @Published var isTesting = false

    static let languages = ["简体中文", "繁體中文", "English", "日本語", "한국어"]
    private let loadsSecrets: Bool

    /// `loadSecrets` false leaves the API key alone (the self-checks don't need it).
    init(loadSecrets: Bool = true) {
        loadsSecrets = loadSecrets
        if loadSecrets { apiKey = Settings.shared.apiKey }
    }

    var config: TranslationConfig {
        TranslationConfig(baseURL: baseURL, model: model, apiKey: apiKey, targetLanguage: targetLanguage)
    }

    /// Re-registers the global hotkeys; while one is being recorded they stay paused until it is done.
    private func shortcutsChanged() {
        guard recording == nil else { return }
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
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

    /// Registers or removes the login item. Only works from the built app bundle, not `swift run`.
    private func applyLaunchAtLogin() {
        let service = SMAppService.mainApp
        guard launchAtLogin != (service.status == .enabled) else { return }
        do {
            if launchAtLogin, service.status != .enabled {
                try service.register()
            } else if !launchAtLogin, service.status == .enabled {
                try service.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "设置开机启动失败：\(error.localizedDescription)"
            launchAtLogin = service.status == .enabled
        }
    }

    private var monitor: Any?

    func startRecording(_ target: ShortcutTarget) {
        if recording != nil { stopRecordingShortcut() }
        recording = target
        NotificationCenter.default.post(name: .pauseHotKeys, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Esc cancels recording
                self.stopRecordingShortcut()
                return nil
            }
            if let shortcut = Shortcut(event: event) {
                switch self.recording {
                case .capture: self.shortcut = shortcut
                case .pinClipboard: self.pinShortcut = shortcut
                case .togglePins: self.togglePinsShortcut = shortcut
                case .scanCode: self.scanCodeShortcut = shortcut
                case nil: break
                }
                self.stopRecordingShortcut()
            }
            return nil
        }
    }

    func stopRecordingShortcut() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        NotificationCenter.default.post(name: .resumeHotKeys, object: nil)
    }
}

extension Notification.Name {
    static let pauseHotKeys = Notification.Name("ShotlatePauseHotKey")
    static let resumeHotKeys = Notification.Name("ShotlateResumeHotKey")
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case shortcuts, output, translate, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shortcuts: return "快捷键"
        case .output: return "保存"
        case .translate: return "翻译"
        case .general: return "通用"
        }
    }

    var symbol: String {
        switch self {
        case .shortcuts: return "keyboard"
        case .output: return "square.and.arrow.down"
        case .translate: return "translate"
        case .general: return "gearshape"
        }
    }
}

/// Menu on the left, the chosen pane on the right. Changes take effect as they are made.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State var pane: SettingsPane = .shortcuts

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 2) {
                ForEach(SettingsPane.allCases) { p in
                    Button { pane = p } label: {
                        HStack(spacing: 8) {
                            Image(systemName: p.symbol).frame(width: 20)
                            Text(p.title)
                        }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundStyle(pane == p ? Color.white : Color.primary)
                            .background(RoundedRectangle(cornerRadius: 6).fill(pane == p ? Color.accentColor : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 170)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            Form { content }
                .formStyle(.grouped)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    @ViewBuilder private var content: some View {
        switch pane {
        case .shortcuts: shortcuts
        case .output: output
        case .translate: translate
        case .general: general
        }
    }

    private var shortcuts: some View {
        Section {
            LabeledContent("截图") {
                Button(model.recording == .capture ? "请按下新的组合键…（Esc 取消）" : model.shortcut.displayString) {
                    model.recording == .capture ? model.stopRecordingShortcut() : model.startRecording(.capture)
                }
            }
            optionalShortcutRow("从剪贴板贴图", .pinClipboard, $model.pinShortcut)
            optionalShortcutRow("隐藏 / 显示全部贴图", .togglePins, $model.togglePinsShortcut)
            optionalShortcutRow("扫描屏幕上的二维码", .scanCode, $model.scanCodeShortcut)
        } footer: {
            Text("全局快捷键，在任何应用里都能用。截图时各个工具的单键快捷键，在工具栏按钮的悬停卡片上修改。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var output: some View {
        Section {
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
        } footer: {
            Text("截图时按 ⌘S 直接保存到这里；⇧⌘S 另存为。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var translate: some View {
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
        } footer: {
            Text("使用 OpenAI 兼容接口，默认是 DeepSeek 的 deepseek-flash。API Key 保存在本机的 ~/Library/Application Support/Shotlate/api-key，只有你的账户能读取。发送给翻译服务的只有识别出的文字，截图本身不会上传。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var general: some View {
        Section {
            Toggle("登录时启动 Shotlate", isOn: $model.launchAtLogin)
            if let error = model.loginItemError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
    }

    /// A shortcut that can be cleared.
    private func optionalShortcutRow(_ title: String, _ target: ShortcutTarget, _ value: Binding<Shortcut?>) -> some View {
        LabeledContent(title) {
            HStack {
                Button(model.recording == target ? "请按下新的组合键…（Esc 取消）" : value.wrappedValue?.displayString ?? "未设置") {
                    model.recording == target ? model.stopRecordingShortcut() : model.startRecording(target)
                }
                if value.wrappedValue != nil {
                    Button("清除") { value.wrappedValue = nil }
                }
            }
        }
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var model = SettingsModel()

    private init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 680, height: 460),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentMinSize = CGSize(width: 640, height: 420)
        window.title = "Shotlate 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        // Reload so the window reflects what is stored now.
        model = SettingsModel()
        let controller = NSHostingController(rootView: SettingsView(model: model))
        controller.sizingOptions = []
        window?.contentViewController = controller
        window?.setContentSize(CGSize(width: 680, height: 460))
        window?.center()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if model.recording != nil { model.stopRecordingShortcut() }
    }
}
