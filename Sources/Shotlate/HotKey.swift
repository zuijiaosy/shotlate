import Carbon.HIToolbox
import Foundation

/// System-wide hotkeys through Carbon, which works without Accessibility permission.
final class HotKeyCenter {
    enum Action: UInt32 {
        case capture = 1
        case pinClipboard = 2
        case togglePins = 3
        case scanCode = 4
    }

    static let shared = HotKeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

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
        let id = action.rawValue
        unregister(id: id)
        handlers[id] = handler
        guard let shortcut else { return true }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E_4150), id: id) // "SNAP"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if let ref { refs[id] = ref }
        return status == noErr
    }

    func unregister(_ action: Action) {
        unregister(id: action.rawValue)
    }

    private func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }

    func unregisterAll() {
        for id in Array(handlers.keys) { unregister(id: id) }
    }

    var registeredCount: Int { refs.count }

    func testing_fire(_ id: UInt32) { handlers[id]?() }
}
