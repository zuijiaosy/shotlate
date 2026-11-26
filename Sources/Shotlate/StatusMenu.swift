import AppKit

/// The menu behind the menu-bar icon. Rows that only matter sometimes (pin management, cancelling a countdown,
/// an update, a shortcut clash) appear only then, instead of sitting there greyed out. Global shortcuts show in
/// the menu's own right-hand column; they are display-only key equivalents, the hotkeys do the work.
final class StatusMenu: NSObject, NSMenuDelegate {
    struct State {
        var hasPins = false
        var pinsHidden = false
        var countingDown = false
        var pendingVersion: String?
    }

    struct Actions {
        var capture: () -> Void
        var delayedCapture: (Int) -> Void
        var cancelDelay: () -> Void
        var scan: () -> Void
        var pinClipboard: () -> Void
        var togglePins: () -> Void
        var closePins: () -> Void
        var openSettings: () -> Void
        var openShortcutSettings: () -> Void
        var update: () -> Void
    }

    enum ShortcutRow: CaseIterable { case capture, scan, pinClipboard, togglePins }

    let menu = NSMenu()
    /// Asked each time the menu opens.
    var currentState: () -> State = { State() }

    private let actions: Actions
    private let updateItem, conflictItem, noticeSeparator: NSMenuItem
    private let captureItem, delayItem, cancelDelayItem, scanItem, pinClipboardItem: NSMenuItem
    private let pinsSeparator, togglePinsItem, closePinsItem: NSMenuItem
    private var clashes: [ShortcutRow: String] = [:]

    init(actions: Actions) {
        self.actions = actions
        updateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        conflictItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        noticeSeparator = .separator()
        captureItem = NSMenuItem(title: "截图", action: nil, keyEquivalent: "")
        delayItem = NSMenuItem(title: "延时截图", action: nil, keyEquivalent: "")
        cancelDelayItem = NSMenuItem(title: "取消延时截图", action: nil, keyEquivalent: "")
        scanItem = NSMenuItem(title: "扫描二维码", action: nil, keyEquivalent: "")
        pinClipboardItem = NSMenuItem(title: "从剪贴板贴图", action: nil, keyEquivalent: "")
        pinsSeparator = .separator()
        togglePinsItem = NSMenuItem(title: "隐藏全部贴图", action: nil, keyEquivalent: "")
        closePinsItem = NSMenuItem(title: "关闭全部贴图", action: nil, keyEquivalent: "")
        super.init()
        menu.delegate = self

        hook(updateItem, "arrow.down.circle") { [unowned self] in self.actions.update() }
        hook(conflictItem, "exclamationmark.triangle") { [unowned self] in self.actions.openShortcutSettings() }
        hook(captureItem, nil) { [unowned self] in self.actions.capture() }
        captureItem.image = Self.rowIcons ? BrandGlyph.image(pointSize: 16) : nil
        let delayMenu = NSMenu()
        for seconds in [3, 5, 10] {
            let item = NSMenuItem(title: "\(seconds) 秒", action: nil, keyEquivalent: "")
            hook(item, nil) { [unowned self] in self.actions.delayedCapture(seconds) }
            delayMenu.addItem(item)
        }
        delayItem.submenu = delayMenu
        delayItem.image = Self.icon("timer")
        hook(cancelDelayItem, "xmark.circle") { [unowned self] in self.actions.cancelDelay() }
        hook(scanItem, "qrcode.viewfinder") { [unowned self] in self.actions.scan() }
        hook(pinClipboardItem, "pin") { [unowned self] in self.actions.pinClipboard() }
        hook(togglePinsItem, "eye.slash") { [unowned self] in self.actions.togglePins() }
        hook(closePinsItem, "xmark.circle") { [unowned self] in self.actions.closePins() }
        let settingsItem = NSMenuItem(title: "设置…", action: nil, keyEquivalent: ",")
        hook(settingsItem, "gearshape") { [unowned self] in self.actions.openSettings() }
        let quitItem = NSMenuItem(title: "退出 Shotlate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.image = Self.icon("power")

        for item in [updateItem, conflictItem, noticeSeparator, captureItem, delayItem, cancelDelayItem, scanItem, pinClipboardItem,
                     pinsSeparator, togglePinsItem, closePinsItem, .separator(), settingsItem, quitItem] {
            menu.addItem(item)
        }
        refresh(State())
    }

    /// Shows a global shortcut next to its row, or, if another app holds it, a notice at the top of the menu.
    func setShortcut(_ shortcut: Shortcut?, registered: Bool, for row: ShortcutRow) {
        let item = self.item(for: row)
        clashes[row] = (shortcut != nil && !registered) ? shortcut!.displayString : nil
        if let shortcut, registered, let equivalent = shortcut.menuKeyEquivalent {
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.modifiers
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    func refresh(_ state: State) {
        updateItem.isHidden = state.pendingVersion == nil
        updateItem.title = "更新到 \(state.pendingVersion ?? "")…"
        let clashing = ShortcutRow.allCases.compactMap { clashes[$0] }
        conflictItem.isHidden = clashing.isEmpty
        conflictItem.title = "快捷键 \(clashing.joined(separator: "、")) 已被占用…"
        noticeSeparator.isHidden = updateItem.isHidden && conflictItem.isHidden

        delayItem.isHidden = state.countingDown
        cancelDelayItem.isHidden = !state.countingDown

        for item in [pinsSeparator, togglePinsItem, closePinsItem] { item.isHidden = !state.hasPins }
        togglePinsItem.title = state.pinsHidden ? "显示全部贴图" : "隐藏全部贴图"
        togglePinsItem.image = Self.icon(state.pinsHidden ? "eye" : "eye.slash")
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh(currentState()) }

    /// Visible rows top to bottom ("—" for a separator), shortcut appended after a tab; for the self-checks.
    var visibleRows: [String] {
        menu.items.filter { !$0.isHidden }.map { item in
            if item.isSeparatorItem { return "—" }
            return item.keyEquivalent.isEmpty ? item.title : item.title + "\t" + item.keyEquivalent
        }
    }

    // MARK: - Plumbing

    private var handlers: [ObjectIdentifier: () -> Void] = [:]

    private func hook(_ item: NSMenuItem, _ symbol: String?, _ handler: @escaping () -> Void) {
        item.target = self
        item.action = #selector(run(_:))
        handlers[ObjectIdentifier(item)] = handler
        if let symbol { item.image = Self.icon(symbol) }
    }

    @objc private func run(_ sender: NSMenuItem) { handlers[ObjectIdentifier(sender)]?() }

    private func item(for row: ShortcutRow) -> NSMenuItem {
        switch row {
        case .capture: return captureItem
        case .scan: return scanItem
        case .pinClipboard: return pinClipboardItem
        case .togglePins: return togglePinsItem
        }
    }

    /// macOS 26 menus give rows icons (and add a gear to 设置… on their own, which left it the only indented row);
    /// earlier menus are text only, so icons there would look foreign.
    static var rowIcons: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    private static func icon(_ name: String) -> NSImage? {
        guard rowIcons else { return nil }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
}
