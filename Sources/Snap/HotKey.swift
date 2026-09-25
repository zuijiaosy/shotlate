import Carbon.HIToolbox
import Foundation

/// System-wide hotkeys through Carbon, which works without Accessibility permission.
/// Built-in actions use fixed ids; user commands get ids from `customBase` up.
final class HotKeyCenter {
    enum Action: UInt32 {
        case capture = 1
        case pinClipboard = 2
        case togglePins = 3
        case scanCode = 4
    }

    static let shared = HotKeyCenter()
    static let customBase: UInt32 = 100

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var shortcuts: [UInt32: Shortcut] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    /// While suspended (an ignored app is in front) nothing is registered, so the keys reach that app.
    private(set) var isSuspended = false

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if status == noErr {
                let key = id.id
                DispatchQueue.main.async { HotKeyCenter.shared.handlers[key]?() }
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    /// Returns false when the combination is already taken by another app.
    @discardableResult
    func register(_ action: Action, shortcut: Shortcut?, handler: @escaping () -> Void) -> Bool {
        register(id: action.rawValue, shortcut: shortcut, handler: handler)
    }

    @discardableResult
    func register(id: UInt32, shortcut: Shortcut?, handler: @escaping () -> Void) -> Bool {
        unregister(id: id)
        handlers[id] = handler
        guard let shortcut else { return true }
        shortcuts[id] = shortcut
        return isSuspended ? true : install(id, shortcut)
    }

    private func install(_ id: UInt32, _ shortcut: Shortcut) -> Bool {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E_4150), id: id) // "SNAP"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if let ref { refs[id] = ref }
        return status == noErr
    }

    func unregister(_ action: Action) {
        unregister(id: action.rawValue)
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        shortcuts[id] = nil
        handlers[id] = nil
    }

    /// Removes every user command (ids from `customBase`).
    func unregisterCustom() {
        for id in Array(Set(handlers.keys).union(shortcuts.keys)) where id >= Self.customBase { unregister(id: id) }
    }

    func unregisterAll() {
        for id in Array(Set(handlers.keys).union(shortcuts.keys)) { unregister(id: id) }
    }

    /// Temporarily releases (or takes back) every registered combination without forgetting them.
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        if suspended {
            for (_, ref) in refs { UnregisterEventHotKey(ref) }
            refs.removeAll()
        } else {
            for (id, shortcut) in shortcuts { _ = install(id, shortcut) }
        }
    }

    var registeredCount: Int { refs.count }

    func testing_fire(_ id: UInt32) { handlers[id]?() }
}
