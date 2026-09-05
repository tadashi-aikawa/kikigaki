import AppKit
import Carbon.HIToolbox

/// グローバルホットキー(KOKUKOKUのHotkeyをそのまま移植。原点はJINRAI)。
@MainActor
final class Hotkey {
    private static var nextID: UInt32 = 1
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var eventHandlerInstalled = false

    private let hotKeyID: UInt32
    private var hotKeyRef: EventHotKeyRef?

    convenience init?(modifiers: [String], key: String, handler: @escaping () -> Void) {
        guard let keyCode = KeyCodes.keyCode(for: key) else { return nil }
        self.init(
            keyCode: keyCode,
            carbonModifiers: KeyCodes.carbonModifiers(for: modifiers),
            handler: handler)
    }

    init?(keyCode: UInt32, carbonModifiers: UInt32, handler: @escaping () -> Void) {
        Self.installEventHandlerIfNeeded()
        hotKeyID = Self.nextID
        Self.nextID += 1

        var ref: EventHotKeyRef?
        let eventHotKeyID = EventHotKeyID(
            signature: OSType(0x4B4B_474B),  // "KKGK"
            id: hotKeyID)
        let status = RegisterEventHotKey(
            keyCode, carbonModifiers, eventHotKeyID,
            GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        hotKeyRef = ref
        Self.handlers[hotKeyID] = handler
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        Self.handlers[hotKeyID] = nil
    }

    private static func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                let id = hotKeyID.id
                Task { @MainActor in
                    Hotkey.handlers[id]?()
                }
                return noErr
            },
            1, &eventType, nil, nil)
    }
}
