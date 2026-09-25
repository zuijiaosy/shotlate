import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var captureItem: NSMenuItem!
    private var hotKey: HotKey!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snap")
        image?.isTemplate = true
        statusItem.button?.image = image

        let menu = NSMenu()
        captureItem = NSMenuItem(title: "截图", action: #selector(capture), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Snap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        hotKey = HotKey { CaptureSession.begin() }
        registerHotKey()
        let center = NotificationCenter.default
        center.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in self?.registerHotKey() }
        center.addObserver(forName: .snapPauseHotKey, object: nil, queue: .main) { [weak self] _ in self?.hotKey.unregister() }
        center.addObserver(forName: .snapResumeHotKey, object: nil, queue: .main) { [weak self] _ in self?.registerHotKey() }

        TextRecognizer.warmUp()

        if !CaptureEngine.hasPermission {
            CGRequestScreenCaptureAccess()
        }
    }

    private func registerHotKey() {
        let shortcut = Settings.shared.shortcut
        let ok = hotKey.register(shortcut)
        captureItem.title = ok ? "截图（\(shortcut.displayString)）" : "截图（快捷键 \(shortcut.displayString) 已被占用）"
    }

    @objc private func capture() {
        // Let the menu close before the screen is frozen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { CaptureSession.begin() }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.present()
    }

    /// Accessory apps still need an Edit menu, or ⌘C/⌘V/⌘A do nothing in text fields.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "退出 Snap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
