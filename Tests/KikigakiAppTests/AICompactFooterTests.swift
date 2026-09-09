import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct AICompactFooterTests {
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
        #expect(menu.items.map(\.title) == ["会話をコピー", "今すぐ送る", "AIセッションを準備…", "ペインを開く", "AIセッションを作り直す", "保存を再試行", "前の会議に返事あり"])
        var prepared = false
        window.onPrepareAI = { prepared = true }
        for title in ["AIセッションを準備…"] {
            if let index = menu.items.firstIndex(where: { $0.title == title }) { menu.performActionForItem(at: index) }
        }
        #expect(prepared)
        var fired = false
        window.onFireScheduleAI = { fired = true }
        if let index = menu.items.firstIndex(where: { $0.title == "今すぐ送る" }) { menu.performActionForItem(at: index) }
        #expect(fired)
        state.aiSchedule.skipReason = "返事待ちでスキップ中"; state.aiSchedule.canFireNow = false; window.apply(state)
        #expect(window.footerMenu().items.first { $0.title == "今すぐ送る" }?.isEnabled == false)
        #expect(menu.items.filter { ["会話をコピー", "AIセッションを作り直す", "保存を再試行"].contains($0.title) }.allSatisfy { !$0.isEnabled })
    }
}
