import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct AICompactFooterTests {
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
        state.aiSchedule.active = true; state.previousAIUnread = 1
        window.apply(state)
        let menu = window.footerMenu()
        #expect(menu.items.map(\.title) == ["会話をコピー", "自動送信を停止", "AIセッションを準備…", "ペインを開く", "AIセッションを作り直す", "保存を再試行", "前の会議に返事あり"])
        var stopped = false, prepared = false
        window.onStopScheduleAI = { stopped = true }; window.onPrepareAI = { prepared = true }
        menu.performActionForItem(at: 1); menu.performActionForItem(at: 2)
        #expect(stopped && prepared)
        #expect(!menu.items[0].isEnabled && !menu.items[4].isEnabled && !menu.items[5].isEnabled)
    }
}
