import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct AICompactFooterTests {
    @Test func ゲージの宛先と無効理由をホバーで伝える() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var schedule = AIScheduleState(meetingID: UUID())
        try schedule.start(options: .init(prompt: "更新", interval: 102), now: now, runID: UUID())
        let gauge = AIScheduleGauge()
        gauge.update(AIScheduleViewState(schedule: schedule, destination: "議事録"), now: now)
        #expect(gauge.toolTip == "次 1:42 · 議事録へ · ダブルクリックで今すぐ送る")
        gauge.update(AIScheduleViewState(schedule: schedule, destination: "議事録", availability: .awaitingResult), now: now)
        #expect(gauge.toolTip == "返事待ちでスキップ中 · 議事録へ")
        let footer = AICompactFooter()
        footer.update(SessionSnapshot(), reduceMotion: true)
        #expect(footer.gauge.toolTip == "AI連携が設定されていません")
        footer.update(SessionSnapshot(ai: AIViewState()), reduceMotion: true)
        #expect(footer.gauge.toolTip == "録音中・一時停止中に自動送信を設定できます")
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
    @Test func ゲージは停止中のクリックで設定し稼働中のダブルクリックだけ即時実行する() throws {
        _ = NSApplication.shared
        let gauge = AIScheduleGauge()
        var configured = 0, sent = 0
        gauge.onConfigure = { configured += 1 }; gauge.onFire = { sent += 1 }
        let now = Date(timeIntervalSince1970: 1000)
        gauge.update(AIScheduleViewState(), now: now)
        gauge.activate(clickCount: 1)
        #expect(configured == 1 && gauge.displayText.isEmpty)
        #expect(gauge.toolTip == "クリックで自動送信を設定")
        var schedule = AIScheduleState(meetingID: UUID())
        try schedule.start(options: .init(prompt: "更新", interval: 102), now: now, runID: UUID())
        gauge.update(AIScheduleViewState(schedule: schedule), now: now)
        #expect(gauge.displayText == "1:42")
        gauge.activate(clickCount: 1); #expect(sent == 0)
        gauge.activate(clickCount: 2); #expect(sent == 1 && configured == 1)
        gauge.update(AIScheduleViewState(schedule: schedule, availability: .awaitingResult), now: now)
        #expect(gauge.displayText == "—" && gauge.toolTip == "返事待ちでスキップ中")
        gauge.activate(clickCount: 2); #expect(sent == 1)
        gauge.update(AIScheduleViewState(schedule: schedule, hasChanges: false), now: now)
        #expect(gauge.displayText == "—" && gauge.toolTip == "差分なしでスキップ中")
        gauge.isEnabled = false; gauge.update(AIScheduleViewState(), now: now)
        gauge.activate(clickCount: 1); #expect(configured == 1)
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
        #expect(menu.items.map(\.title) == ["会話をコピー", "今すぐ送る", "自動送信を停止", "AIセッションを準備…", "ペインを開く", "AIセッションを作り直す", "保存を再試行", "前の会議に返事あり"])
        var stopped = false, prepared = false
        window.onStopScheduleAI = { stopped = true }; window.onPrepareAI = { prepared = true }
        for title in ["自動送信を停止", "AIセッションを準備…"] {
            if let index = menu.items.firstIndex(where: { $0.title == title }) { menu.performActionForItem(at: index) }
        }
        #expect(stopped && prepared)
        var fired = false
        window.onFireScheduleAI = { fired = true }
        if let index = menu.items.firstIndex(where: { $0.title == "今すぐ送る" }) { menu.performActionForItem(at: index) }
        #expect(fired)
        state.aiSchedule.skipReason = "返事待ちでスキップ中"; window.apply(state)
        #expect(window.footerMenu().items.first { $0.title == "今すぐ送る" }?.isEnabled == false)
        #expect(menu.items.filter { ["会話をコピー", "AIセッションを作り直す", "保存を再試行"].contains($0.title) }.allSatisfy { !$0.isEnabled })
    }
}
