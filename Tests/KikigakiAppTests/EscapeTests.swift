import AppKit
import Testing
@testable import Kikigaki

@Suite(.serialized) @MainActor struct EscapeTests {
    @Test func 未処理のEscapeは本文から届いてもウィンドウを閉じず検索は閉じる() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TranscriptWindowController(minutesDefaults: defaults)
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        controller.show()
        defer { controller.minutesSplit.preview.stop(); window.orderOut(nil) }
        if !controller.minutesSplit.isPreviewVisible { controller.toggleMinutes() }
        let preview = controller.minutesSplit.preview
        // パス未選択時は本文が隠れているため、本文表示時のフォーカス経路を用意する。
        preview.document.isHidden = false
        let web = preview.document.webView
        #expect(window.makeFirstResponder(web))
        // tryToPerformのtrueはセレクタを扱えることを示すだけで、修正前との差分ではない。
        // 修正前はsuper呼び出しでプロセスごと落ちるため、呼び出しを完了して表示を維持することの検査。
        #expect(web.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil))
        #expect(window.isVisible)
        window.makeFirstResponder(nil)
        controller.showSearch(nil)
        #expect(controller.searchOpen)
        preview.showSearch()
        #expect(preview.isSearchOpen && controller.searchOpen)
        // 両方の検索を開いたまま議事録本文へ戻すと、議事録側だけを閉じる。
        #expect(window.makeFirstResponder(web))
        #expect(preview.hasSearchFocus)
        // WebKit自身がキーを扱う場合と切り離し、controllerへ届いた後の振り分けを検査する。
        controller.cancelOperation(nil)
        #expect(!preview.isSearchOpen && controller.searchOpen && window.isVisible)
        preview.showSearch()
        window.makeFirstResponder(nil)
        controller.cancelOperation(nil)
        #expect(!controller.searchOpen && preview.isSearchOpen && window.isVisible)
        #expect(window.makeFirstResponder(web))
        controller.cancelOperation(nil)
        #expect(!preview.isSearchOpen && window.isVisible)
        controller.cancelOperation(nil)
        #expect(window.isVisible)
        // Escapeの受け止めによって通常の閉じる経路を拒否しない。
        window.performClose(nil)
        #expect(!window.isVisible)
    }
}
