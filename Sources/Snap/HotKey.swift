import Carbon.HIToolbox
import Foundation

/// System-wide hotkeys through Carbon, which works without Accessibility permission.
/// Each action has its own id so several shortcuts can be registered at once.
final class HotKeyCenter {
    enum Action: UInt32 {
        case capture = 1
        case pinClipboard = 2
        case togglePins = 3
        case scanCode = 4
    }

    static let shared = HotKeyCenter()

    private var refs: [Action: EventHotKeyRef] = [:]
    private var handlers: [Action: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if status == noErr, let action = HotKeyCenter.Action(rawValue: id.id) {
                DispatchQueue.main.async { HotKeyCenter.shared.handlers[action]?() }
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    /// Returns false when the combination is already taken by another app.
    @discardableResult
    func register(_ action: Action, shortcut: Shortcut?, handler: @escaping () -> Void) -> Bool {
        unregister(action)
        handlers[action] = handler
        guard let shortcut else { return true }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x534E_4150), id: action.rawValue) // "SNAP"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if let ref { refs[action] = ref }
        return status == noErr
    }

    func unregister(_ action: Action) {
        if let ref = refs.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
    }

    func unregisterAll() {
        for action in Array(refs.keys) { unregister(action) }
    }
}
