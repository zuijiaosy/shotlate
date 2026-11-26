import AppKit
import ShotlateCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenu: StatusMenu!
    private var recordingTimer: Timer?
    private let countdown = Countdown()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = BrandGlyph.image()
        // Countdown and recording timers sit next to the icon; fixed-width digits keep it from jittering.
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)

        statusMenu = StatusMenu(actions: .init(
            capture: { [weak self] in self?.capture() },
            delayedCapture: { [weak self] in self?.startDelayedCapture(seconds: $0) },
            cancelDelay: { [weak self] in self?.cancelDelayedCapture() },
            scan: { [weak self] in self?.scanCodes() },
            pinClipboard: { PinManager.shared.pinClipboard() },
            togglePins: { PinManager.shared.toggleHidden() },
            closePins: { PinManager.shared.closeAll() },
            openSettings: { SettingsWindowController.shared.present() },
            openShortcutSettings: { SettingsWindowController.shared.present(pane: .shortcuts) },
            update: { Updater.shared.checkForUpdates() }))
        statusMenu.currentState = { [countdown] in
            StatusMenu.State(hasPins: PinManager.shared.hasPins, pinsHidden: PinManager.shared.isHidingAll,
                             countingDown: countdown.isRunning, pendingVersion: Updater.shared.pendingVersion)
        }
        statusItem.menu = statusMenu.menu

        registerHotKeys()
        let center = NotificationCenter.default
        center.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in self?.registerHotKeys() }
        center.addObserver(forName: .pauseHotKeys, object: nil, queue: .main) { _ in HotKeyCenter.shared.unregisterAll() }
        center.addObserver(forName: .resumeHotKeys, object: nil, queue: .main) { [weak self] _ in self?.registerHotKeys() }
        center.addObserver(forName: GIFRecorder.didChange, object: nil, queue: .main) { [weak self] _ in self?.updateRecordingStatus() }

        TextRecognizer.warmUp()
        Updater.shared.start()

        if !CaptureEngine.hasPermission {
            CGRequestScreenCaptureAccess()
        }
    }

    private func registerHotKeys() {
        let settings = Settings.shared
        let capture = settings.shortcut
        // While a GIF is recording, the capture shortcut stops it.
        let ok = HotKeyCenter.shared.register(.capture, shortcut: capture) {
            if let recorder = GIFRecorder.current { recorder.stop() } else { CaptureSession.begin() }
        }
        statusMenu.setShortcut(capture, registered: ok, for: .capture)

        let pin = settings.pinClipboardShortcut
        let pinOK = HotKeyCenter.shared.register(.pinClipboard, shortcut: pin) { PinManager.shared.pinClipboard() }
        statusMenu.setShortcut(pin, registered: pinOK, for: .pinClipboard)

        let toggle = settings.togglePinsShortcut
        let toggleOK = HotKeyCenter.shared.register(.togglePins, shortcut: toggle) { PinManager.shared.toggleHidden() }
        statusMenu.setShortcut(toggle, registered: toggleOK, for: .togglePins)

        let scan = settings.scanCodeShortcut
        let scanOK = HotKeyCenter.shared.register(.scanCode, shortcut: scan) { CodeScanner.scanScreens() }
        statusMenu.setShortcut(scan, registered: scanOK, for: .scan)
    }

    /// While recording, the menu bar icon becomes a stop button showing the elapsed time.
    private func updateRecordingStatus() {
        guard let button = statusItem.button else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil
        if GIFRecorder.current != nil {
            statusItem.menu = nil
            button.target = self
            button.action = #selector(stopRecording)
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "停止录制 GIF")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            statusItem.length = NSStatusItem.variableLength
            let update = { [weak button] in
                let s = Int(GIFRecorder.current?.elapsed ?? 0)
                button?.title = String(format: " %d:%02d", s / 60, s % 60)
            }
            update()
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in update() }
        } else {
            statusItem.menu = statusMenu.menu
            button.action = nil
            button.image = BrandGlyph.image()
            resetStatusButton()
        }
    }

    @objc private func stopRecording() { GIFRecorder.current?.stop() }

    private func capture() {
        // Let the menu close before the screen is frozen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { CaptureSession.begin() }
    }

    /// Counts down on the menu bar icon, so menus and hover states can be opened before the screen freezes.
    private func startDelayedCapture(seconds: Int) {
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

    private func scanCodes() {
        // Let the menu close first so it doesn't cover a code.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { CodeScanner.scanScreens() }
    }

    private func cancelDelayedCapture() {
        countdown.cancel()
        resetStatusButton()
    }

    private func resetStatusButton() {
        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageOnly
        statusItem.length = NSStatusItem.squareLength
    }

    /// Accessory apps still need an Edit menu, or ⌘C/⌘V/⌘A do nothing in text fields.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "退出 Shotlate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
