import Carbon.HIToolbox
import KikigakiCore

/// `RegisterEventHotKey` でOS全体のキーを1つ登録する。アクセシビリティの許可は要らない。
/// 同じキーを別アプリが先に登録していると失敗するので、nilを返して呼び出し側が警告する。
@MainActor
final class GlobalHotkeyRegistration {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandlerInstalled = false

    private let id: UInt32
    private var ref: EventHotKeyRef?

    init?(_ hotkey: GlobalHotkey, handler: @escaping () -> Void) {
        guard let keyCode = Self.keyCode(hotkey.key) else { return nil }
        Self.installEventHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, Self.carbonModifiers(hotkey.modifiers),
                                         EventHotKeyID(signature: OSType(0x4B4B_474B), id: id),  // "KKGK"
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        self.ref = ref
        Self.handlers[id] = handler
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.handlers[id] = nil
    }

    /// 物理位置のANSIコードで引く。文字配列(Dvorak等)の違いは追わない。parliamentのヘルパーと同じ
    static func keyCode(_ key: String) -> UInt32? {
        let codes: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
            "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
            "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
            "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
            "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8,
            "9": kVK_ANSI_9,
            "space": kVK_Space, "enter": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
            "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11,
            "f12": kVK_F12, "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15, "f16": kVK_F16,
            "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20,
        ]
        return codes[key].map(UInt32.init)
    }

    static func carbonModifiers(_ modifiers: Set<GlobalHotkey.Modifier>) -> UInt32 {
        modifiers.reduce(0) { flags, modifier in
            switch modifier {
            case .ctrl: flags | UInt32(controlKey)
            case .alt: flags | UInt32(optionKey)
            case .shift: flags | UInt32(shiftKey)
            case .cmd: flags | UInt32(cmdKey)
            }
        }
    }

    private static func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            Task { @MainActor in GlobalHotkeyRegistration.handlers[id]?() }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
