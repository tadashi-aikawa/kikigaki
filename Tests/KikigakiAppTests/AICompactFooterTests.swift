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

    @Test func その他メニューの入口と状態別有効化を維持する() {
        _ = NSApplication.shared
        let window = TranscriptWindowController()
        window.apply(SessionSnapshot(ai: AIViewState(), state: .recording))
        #expect(!window.footerMenu().items.contains { $0.title == "自動送信…" || $0.title == "自動送信を停止" || $0.title == "前の会議に返事あり" })
        var state = window.snapshot
        state.aiSchedule.active = true; state.aiSchedule.nextFire = Date().addingTimeInterval(180); state.previousAIUnread = 1
        window.apply(state)
        let menu = window.footerMenu()
        #expect(menu.items.map(\.title) == ["会話をコピー", "今すぐ送る", "ペインを開く", "AIセッションを作り直す", "保存を再試行", "前の会議に要返答・警告あり"])
        var fired = false
        window.onFireScheduleAI = { fired = true }
        if let index = menu.items.firstIndex(where: { $0.title == "今すぐ送る" }) { menu.performActionForItem(at: index) }
        #expect(fired)
        state.aiSchedule.skipReason = "返事待ちでスキップ中"; state.aiSchedule.canFireNow = false; window.apply(state)
        #expect(window.footerMenu().items.first { $0.title == "今すぐ送る" }?.isEnabled == false)
        #expect(menu.items.filter { ["会話をコピー", "AIセッションを作り直す", "保存を再試行"].contains($0.title) }.allSatisfy { !$0.isEnabled })
    }
}
