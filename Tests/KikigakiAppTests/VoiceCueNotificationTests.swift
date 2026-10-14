import Carbon.HIToolbox
import KikigakiCore
import Testing
@testable import Kikigaki

extension AppKitTests {
@Suite @MainActor struct VoiceCueNotificationTests {
    @Test func 通知の文面は受付と追記と失敗を区別する() {
        let sent = VoiceCueFeedback.accepted(destination: "迅雷", phrase: "アバンティ", appendix: false)
        let appendix = VoiceCueFeedback.accepted(destination: "迅雷", phrase: "ＡＶＡＮＴＩ", appendix: true)
        let failed = VoiceCueFeedback.failed(destination: "迅雷", reason: "送信の準備中です")
        #expect(sent.body == "迅雷へ送りました（アバンティ）" && sent.accepted)
        #expect(appendix.body == "迅雷へ追記を送りました（ＡＶＡＮＴＩ）" && appendix.accepted)
        #expect(failed.body == "迅雷へ送れませんでした。送信の準備中です" && !failed.accepted)
        let idle = VoiceCueFeedback.failed(destination: nil, reason: "録音中・一時停止中だけ送れます")
        #expect(idle.body == "送れませんでした。録音中・一時停止中だけ送れます")
    }
    @Test func グローバルキーの表記はCarbonのキーコードと修飾へ写せる() throws {
        for text in ["cmd+shift+space", "ctrl+alt+cmd+a", "alt+9", "f20", "cmd+enter", "ctrl+escape", "cmd+tab"] {
            let hotkey = try #require(GlobalHotkey(text))
            #expect(GlobalHotkeyRegistration.keyCode(hotkey.key) != nil, "\(text)")
        }
        let hotkey = try #require(GlobalHotkey("cmd+shift+space"))
        #expect(GlobalHotkeyRegistration.keyCode(hotkey.key) == UInt32(kVK_Space))
        #expect(GlobalHotkeyRegistration.carbonModifiers(hotkey.modifiers) == UInt32(cmdKey | shiftKey))
    }
    @Test func バンドル外とreplayでは通知センターを使わない() {
        #expect(!VoiceCueNotification.supported(bundleIdentifier: nil, replay: false))
        #expect(!VoiceCueNotification.supported(bundleIdentifier: "", replay: false))
        #expect(!VoiceCueNotification.supported(bundleIdentifier: "local.test", replay: true))
        #expect(VoiceCueNotification.supported(bundleIdentifier: "local.test", replay: false))
        #expect(VoiceCueNotification(bundleIdentifier: nil, replay: false) == nil)
        #expect(VoiceCueNotification(bundleIdentifier: "local.test", replay: true) == nil)
    }
}
}
