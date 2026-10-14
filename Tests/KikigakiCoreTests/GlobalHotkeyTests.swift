import Testing
@testable import KikigakiCore

@Suite struct GlobalHotkeyTests {
    @Test func 修飾の別名と大小と空白を揃える() throws {
        let hotkey = try #require(GlobalHotkey(" Command + Shift + SPACE "))
        #expect(hotkey.modifiers == [.cmd, .shift] && hotkey.key == "space")
        #expect(GlobalHotkey("control+option+meta+a") == GlobalHotkey("ctrl+alt+cmd+a"))
        #expect(GlobalHotkey("cmd+esc")?.key == "escape")
        #expect(GlobalHotkey("cmd+return")?.key == "enter")
    }

    @Test func 表記はmacOSのメニューと同じ並びにする() {
        #expect(GlobalHotkey("cmd+shift+space")?.display == "⇧⌘Space")
        #expect(GlobalHotkey("cmd+alt+ctrl+a")?.display == "⌃⌥⌘A")
        #expect(GlobalHotkey("f19")?.display == "F19")
        #expect(GlobalHotkey("ctrl+escape")?.display == "⌃Esc")
    }

    @Test func 単独キーとshiftだけの組はファンクションキー以外を拒否する() {
        #expect(GlobalHotkey("a") == nil)
        #expect(GlobalHotkey("shift+a") == nil)
        #expect(GlobalHotkey("space") == nil)
        #expect(GlobalHotkey("f1") != nil && GlobalHotkey("shift+f20") != nil)
        #expect(GlobalHotkey("f21") == nil)
    }

    @Test func 写せないキーと崩れた書式を拒否する() {
        for text in ["", "cmd", "cmd+", "cmd++a", "cmd+cmd+a", "cmd+a+b", "cmd+;", "cmd+left", "cmd+あ", "cmd+ab"] {
            #expect(GlobalHotkey(text) == nil, "\(text)")
        }
    }

    @Test func 設定は既定で未割り当てで空文字も未割り当て() throws {
        #expect(ResolvedConfig(config: try ConfigLoader.parse(toml: "")).manualSendHotkey == nil)
        #expect(ResolvedConfig(config: try ConfigLoader.parse(toml: #"manualSendHotkey = """#)).manualSendHotkey == nil)
        let config = try ConfigLoader.parse(toml: #"manualSendHotkey = "cmd+shift+space""#)
        #expect(ResolvedConfig(config: config).manualSendHotkey == GlobalHotkey("cmd+shift+space"))
    }

    @Test func 設定の書式違いは設定エラーにする() {
        for text in ["a", "shift+a", "cmd+left"] {
            #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: "manualSendHotkey = \"\(text)\"") }
        }
    }
}
