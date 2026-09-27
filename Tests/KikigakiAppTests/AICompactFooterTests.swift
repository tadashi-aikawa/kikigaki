import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct AICompactFooterTests {
    @Test func 会話行のない警告はクリックで全文を表示する() async throws {
        _ = NSApplication.shared
        let footer = AICompactFooter(visibility: { false })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = footer; window.orderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
            window.orderOut(nil)
        }
        var state = SessionSnapshot()
        state.aiRecoveryWarning = "接続先を確認してください"
        footer.update(state, reduceMotion: true)
        footer.update(state, reduceMotion: true)
        #expect(footer.warning.toolTip == state.aiRecoveryWarning)
        footer.warning.performClick(nil)
        let sheet = try #require(window.attachedSheet)
        func text(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(text)
        }
        #expect(text(try #require(sheet.contentView)).contains("接続先を確認してください"))
    }
    @Test func コピー成功通知が消えたら元のエラー色へ戻る() async throws {
        _ = NSApplication.shared
        let window = TranscriptWindowController()
        window.apply(SessionSnapshot(message: "保存に失敗しました", handoffMessage: "コピーしました"))
        func labels(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(labels)
        }
        let label = try #require(labels(window.window!.contentView!).first { $0.stringValue == "コピーしました" })
        #expect(label.textColor == Washi.muted)
        try await Task.sleep(for: .milliseconds(4300))
        #expect(label.stringValue == "保存に失敗しました")
        #expect(label.textColor == Washi.red)
    }

    @Test func その他メニューはAIの項目を使える時だけ出す() {
        _ = NSApplication.shared
        let window = TranscriptWindowController()
        var ai = AIViewState(); ai.canOpenPane = false
        var state = SessionSnapshot(ai: ai, state: .recording)
        state.aiSchedule.active = true; state.aiSchedule.nextFire = Date().addingTimeInterval(180)
        state.aiRecoveryWarning = "復元できない会議があります"
        window.apply(state)
        // 自動送信・作り直しはロボットへ集め、前の会議の案内は出さない。
        let quiet = window.footerMenu()
        #expect(quiet.items.map(\.title) == ["会話をコピー"])
        #expect(!quiet.items[0].isEnabled)
        state.utterances = [.init(speaker: 0, start: 0, end: 1, text: "本文")]
        state.markdownURL = URL(fileURLWithPath: "/tmp/kikigaki-menu.md")
        state.ai?.canOpenPane = true; state.ai?.saveFailed = true; state.ai?.canRecreate = true
        window.apply(state)
        let menu = window.footerMenu()
        #expect(menu.items.map(\.title) == ["会話をコピー", "", "ペインを開く", "保存を再試行"])
        #expect(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.isEnabled })
        var opened = false, retried = false
        window.onOpenAIPane = { opened = true }; window.onRetryAISave = { retried = true }
        menu.performActionForItem(at: 2); menu.performActionForItem(at: 3)
        #expect(opened && retried)
        state.state = .idle; state.ai?.canOpenPane = false; state.ai?.saveFailed = false
        window.apply(state)
        #expect(window.footerMenu().items.map(\.title) == ["会話をコピー"])
        #expect(window.footerMenu().items[0].isEnabled)
    }
}
