import AppKit
import SnapCore

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
    private var groupsItem: NSMenuItem!
    private var scanItem: NSMenuItem!
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
        scanItem = item("扫描屏幕上的二维码 / 条形码", #selector(scanCodes))
        menu.addItem(scanItem)
        menu.addItem(item("白板", #selector(whiteboard)))
        menu.addItem(item("透明白板（在屏幕上画）", #selector(transparentBoard)))
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
        groupsItem = NSMenuItem(title: "贴图分组", action: nil, keyEquivalent: "")
        groupsItem.submenu = NSMenu()
        menu.addItem(groupsItem)
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
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            HotKeyCenter.shared.setSuspended(app.map { IgnoredApps.matches($0, patterns: Settings.shared.ignoredApps) } ?? false)
        }

        TextRecognizer.warmUp()
        if Settings.shared.restorePins { PinStore.shared.restore() }
        if Settings.shared.superSnip { SuperSnip.shared.setEnabled(true) }

        if !CaptureEngine.hasPermission {
            CGRequestScreenCaptureAccess()
        }
    }

    /// `snap://` URLs from other apps, scripts and the command line.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let command = Automation.parse(url) {
                AutomationRunner.run(command)
            } else {
                HUD.show("无法识别的链接：\(url.absoluteString)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Settings.shared.restorePins {
            PinStore.shared.save()
        } else {
            PinStore.shared.clear()
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
        registerScanHotKey()
        registerCustomHotKeys()
        togglePinsShortcutLabel = toggle.map { toggleOK ? "（\($0.displayString)）" : "（快捷键 \($0.displayString) 已被占用）" } ?? ""
    }

    private var togglePinsShortcutLabel = ""

    /// User commands from settings, each on its own id.
    private func registerCustomHotKeys() {
        HotKeyCenter.shared.unregisterCustom()
        for (i, command) in Settings.shared.customCommands.enumerated() {
            guard let shortcut = command.shortcut else { continue }
            let text = command.command
            HotKeyCenter.shared.register(id: HotKeyCenter.customBase + UInt32(i), shortcut: shortcut) {
                guard let parsed = Automation.parse(command: text) else { return HUD.show("无法识别的命令：\(text)") }
                AutomationRunner.run(parsed)
            }
        }
    }

    private func registerScanHotKey() {
        let scan = Settings.shared.scanCodeShortcut
        let ok = HotKeyCenter.shared.register(.scanCode, shortcut: scan) { CodeScanner.scanScreens() }
        scanItem.title = "扫描屏幕上的二维码 / 条形码" + (scan.map { ok ? "（\($0.displayString)）" : "（快捷键 \($0.displayString) 已被占用）" } ?? "")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let pins = PinManager.shared
        restorePinItem.isEnabled = pins.hasHistory
        closePinsItem.isEnabled = pins.hasPins
        togglePinsItem.isEnabled = pins.hasPins
        togglePinsItem.title = (pins.isHidingAll ? "显示全部贴图" : "隐藏全部贴图") + togglePinsShortcutLabel
        passthroughItem.isHidden = !pins.hasPassthrough
        cancelDelayItem.isHidden = !countdown.isRunning
        replayItem.isEnabled = !CaptureHistory.shared.entries.isEmpty
        rebuildGroupsMenu()
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

    private func rebuildGroupsMenu() {
        let pins = PinManager.shared
        groupsItem.title = "贴图分组：\(pins.currentGroup)"
        let menu = groupsItem.submenu!
        menu.removeAllItems()
        for name in pins.groups {
            let i = item("\(name)（\(pins.count(in: name))）", #selector(switchGroup(_:)))
            i.representedObject = name
            i.state = name == pins.currentGroup ? .on : .off
            menu.addItem(i)
        }
        menu.addItem(.separator())
        menu.addItem(item("新建分组…", #selector(newGroup)))
        menu.addItem(item("重命名「\(pins.currentGroup)」…", #selector(renameGroup)))
        let delete = item("删除「\(pins.currentGroup)」并关闭其中的贴图", #selector(deleteGroup))
        delete.isEnabled = pins.groups.count > 1
        menu.addItem(delete)
    }

    @objc private func switchGroup(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        PinManager.shared.switchGroup(to: name)
    }

    @objc private func newGroup() {
        guard let name = askForName(title: "新建贴图分组", message: "新建后会切换到这个分组，之后的贴图都放在这里。", initial: "") else { return }
        PinManager.shared.createGroup(name)
    }

    @objc private func renameGroup() {
        let current = PinManager.shared.currentGroup
        guard let name = askForName(title: "重命名贴图分组", message: "", initial: current) else { return }
        PinManager.shared.renameGroup(current, to: name)
    }

    @objc private func deleteGroup() {
        PinManager.shared.deleteGroup(PinManager.shared.currentGroup)
    }

    private func askForName(title: String, message: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    @objc private func whiteboard() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { CaptureSession.beginBoard(transparent: false) }
    }

    @objc private func transparentBoard() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { CaptureSession.beginBoard(transparent: true) }
    }

    @objc private func scanCodes() {
        // Let the menu close first so it doesn't cover a code.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { CodeScanner.scanScreens() }
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
