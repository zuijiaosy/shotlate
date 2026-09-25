import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var captureItem: NSMenuItem!
    private var pinClipboardItem: NSMenuItem!
    private var restorePinItem: NSMenuItem!
    private var closePinsItem: NSMenuItem!
    private var togglePinsItem: NSMenuItem!
    private var passthroughItem: NSMenuItem!
    private var cancelDelayItem: NSMenuItem!
    private var replayItem: NSMenuItem!
    private let countdown = Countdown()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snap")
        image?.isTemplate = true
        statusItem.button?.image = image

        let menu = NSMenu()
        menu.delegate = self
        captureItem = item("截图", #selector(capture))
        menu.addItem(captureItem)
        let delayItem = NSMenuItem(title: "延时截图", action: nil, keyEquivalent: "")
        let delayMenu = NSMenu()
        for seconds in [3, 5, 10] {
            let i = item("\(seconds) 秒后", #selector(delayedCapture(_:)))
            i.tag = seconds
            delayMenu.addItem(i)
        }
        delayItem.submenu = delayMenu
        menu.addItem(delayItem)
        cancelDelayItem = item("取消延时截图", #selector(cancelDelayedCapture))
        menu.addItem(cancelDelayItem)
        replayItem = item("回放上一次截图", #selector(replayHistory))
        menu.addItem(replayItem)
        menu.addItem(.separator())
        pinClipboardItem = item("从剪贴板贴图", #selector(pinClipboard))
        menu.addItem(pinClipboardItem)
        restorePinItem = item("恢复关闭的贴图", #selector(restorePin))
        menu.addItem(restorePinItem)
        togglePinsItem = item("隐藏全部贴图", #selector(togglePins))
        menu.addItem(togglePinsItem)
        closePinsItem = item("关闭全部贴图", #selector(closePins))
        menu.addItem(closePinsItem)
        passthroughItem = item("取消贴图的鼠标穿透", #selector(disablePassthrough))
        menu.addItem(passthroughItem)
        menu.addItem(.separator())
        menu.addItem(item("设置…", #selector(openSettings), ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Snap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        registerHotKeys()
        let center = NotificationCenter.default
        center.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in self?.registerHotKeys() }
        center.addObserver(forName: .snapPauseHotKey, object: nil, queue: .main) { _ in HotKeyCenter.shared.unregisterAll() }
        center.addObserver(forName: .snapResumeHotKey, object: nil, queue: .main) { [weak self] _ in self?.registerHotKeys() }

        TextRecognizer.warmUp()

        if !CaptureEngine.hasPermission {
            CGRequestScreenCaptureAccess()
        }
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func registerHotKeys() {
        let settings = Settings.shared
        let capture = settings.shortcut
        let ok = HotKeyCenter.shared.register(.capture, shortcut: capture) { CaptureSession.begin() }
        captureItem.title = ok ? "截图（\(capture.displayString)）" : "截图（快捷键 \(capture.displayString) 已被占用）"

        let pin = settings.pinClipboardShortcut
        let pinOK = HotKeyCenter.shared.register(.pinClipboard, shortcut: pin) { PinManager.shared.pinClipboard() }
        if let pin {
            pinClipboardItem.title = pinOK ? "从剪贴板贴图（\(pin.displayString)）" : "从剪贴板贴图（快捷键 \(pin.displayString) 已被占用）"
        } else {
            pinClipboardItem.title = "从剪贴板贴图"
        }

        let toggle = settings.togglePinsShortcut
        let toggleOK = HotKeyCenter.shared.register(.togglePins, shortcut: toggle) { PinManager.shared.toggleHidden() }
        togglePinsShortcutLabel = toggle.map { toggleOK ? "（\($0.displayString)）" : "（快捷键 \($0.displayString) 已被占用）" } ?? ""
    }

    private var togglePinsShortcutLabel = ""

    func menuNeedsUpdate(_ menu: NSMenu) {
        let pins = PinManager.shared
        restorePinItem.isEnabled = pins.hasHistory
        closePinsItem.isEnabled = pins.hasPins
        togglePinsItem.isEnabled = pins.hasPins
        togglePinsItem.title = (pins.isHidingAll ? "显示全部贴图" : "隐藏全部贴图") + togglePinsShortcutLabel
        passthroughItem.isHidden = !pins.hasPassthrough
        cancelDelayItem.isHidden = !countdown.isRunning
        replayItem.isEnabled = !CaptureHistory.shared.entries.isEmpty
    }

    @objc private func capture() {
        // Let the menu close before the screen is frozen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { CaptureSession.begin() }
    }

    /// Counts down on the menu bar icon, so menus and hover states can be opened before the screen freezes.
    @objc private func delayedCapture(_ sender: NSMenuItem) {
        startDelayedCapture(seconds: sender.tag)
    }

    func startDelayedCapture(seconds: Int) {
        let button = statusItem.button
        countdown.start(seconds: seconds, tick: { remaining in
            button?.imagePosition = .imageLeading
            button?.title = " \(remaining)"
            self.statusItem.length = NSStatusItem.variableLength
        }, fire: { [weak self] in
            self?.resetStatusButton()
            CaptureSession.begin()
        })
    }

    @objc private func replayHistory() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { CaptureSession.begin(replay: true) }
    }

    @objc private func cancelDelayedCapture() {
        countdown.cancel()
        resetStatusButton()
    }

    private func resetStatusButton() {
        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageOnly
        statusItem.length = NSStatusItem.squareLength
    }

    @objc private func pinClipboard() { PinManager.shared.pinClipboard() }
    @objc private func restorePin() { PinManager.shared.restoreLast() }
    @objc private func closePins() { PinManager.shared.closeAll() }
    @objc private func togglePins() { PinManager.shared.toggleHidden() }
    @objc private func disablePassthrough() { PinManager.shared.disablePassthrough() }

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
