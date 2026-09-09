import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct AIRobotTests {
    private func waitingState() throws -> SessionSnapshot {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var history = try AIStreamHistory(meetingID: UUID())
        let context = try history.prepare(lines: [], outputDirectory: root)
        let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: "相談", cliPath: "/tmp/helper",
            sessionPath: root.appendingPathComponent(".kikigaki-context/\(history.meetingID)/ai/sessions/2/1.json").path,
            requestToken: "test", question: "確認", capturedAt: Date(), audioCutoffSeconds: 0, profile: "相談", profileSlot: 2)
        let request = try AIRequest(envelope: AIEnvelope(snapshot: context, participant: participant), number: 1, voiceQuestion: "", snapshot: context)
        var conversation = AIConversation(meetingID: history.meetingID)
        try conversation.append(request)
        try conversation.update(request.id) { try $0.beginSending(at: Date()); try $0.submitted() }
        return SessionSnapshot(ai: AIViewState(conversation: conversation), state: .recording)
    }

    @Test func ロボットメニューは状態別に操作を切り替え本番コールバックへ渡す() throws {
        _ = NSApplication.shared
        let window = TranscriptWindowController()
        var state = SessionSnapshot(ai: AIViewState(), state: .recording, markdownURL: URL(fileURLWithPath: "/tmp/test.md"))
        var configured = 0, manual = 0, fired = 0, stopped = 0
        window.onScheduleAI = { configured += 1 }; window.onAskAI = { _ in manual += 1 }
        window.onFireScheduleAI = { fired += 1 }; window.onStopScheduleAI = { stopped += 1 }
        window.apply(state)
        let idle = window.robotMenu()
        #expect(idle.items.map(\.title) == ["自動実行…", "手動実行…"])
        #expect(window.robotMenuPosition(idle).y - idle.size.height > window.compactFooter.robot.bounds.maxY)
        idle.performActionForItem(at: 0); idle.performActionForItem(at: 1)
        #expect(configured == 1 && manual == 1)
        state.aiSchedule.active = true; state.aiSchedule.nextFire = Date().addingTimeInterval(45)
        window.apply(state)
        let active = window.robotMenu()
        #expect(active.items.map(\.title) == ["今すぐ送る", "自動実行解除", "手動実行…"])
        active.performActionForItem(at: 0); active.performActionForItem(at: 1)
        #expect(fired == 1 && stopped == 1)
        // 自動宛先と別スロットの手動返事待ちも、実行中の表示と即時操作の抑止へ反映する。
        state.ai = try waitingState().ai; window.apply(state)
        #expect(window.compactFooter.robot.displayText == "実行中")
        #expect(window.robotMenu().items[0].isEnabled == false)
        active.performActionForItem(at: 0)
        #expect(fired == 1)
        state.aiSchedule.active = false; window.apply(state)
        #expect(window.robotMenu().items.map(\.title) == ["自動実行…", "手動実行…"])
        state.state = .idle; window.apply(state)
        #expect(!window.robotMenu().items[0].isEnabled)
    }

    @Test func 状態別ラベルと可視性に従って1秒タイマーを止める() throws {
        _ = NSApplication.shared
        var visible = true
        let footer = AICompactFooter(visibility: { visible })
        let now = Date(timeIntervalSince1970: 1000)
        var state = SessionSnapshot(ai: AIViewState(), state: .recording)
        footer.update(state, reduceMotion: false, now: now)
        #expect(footer.robot.displayText.isEmpty && !footer.timerRunning)
        #expect(!footer.robot.isRunning && footer.robot.eyeColor == Washi.red)
        state.aiSchedule.active = true; state.aiSchedule.nextFire = now.addingTimeInterval(45)
        state.aiSchedule.destination = "議事録"
        footer.update(state, reduceMotion: false, now: now)
        #expect(footer.robot.displayText == "0:45" && footer.timerRunning)
        #expect(footer.robot.toolTip == "次 0:45 · 議事録へ")
        state.aiSchedule.nextFire = now.addingTimeInterval(150)
        footer.update(state, reduceMotion: true, now: now)
        #expect(footer.robot.displayText == "2:30" && footer.timerRunning)
        state.aiSchedule.skipReason = "差分なしでスキップ中"
        footer.update(state, reduceMotion: true, now: now)
        #expect(footer.robot.displayText == "—" && footer.robot.toolTip == "差分なしでスキップ中 · 議事録へ")
        state = try waitingState()
        footer.update(state, reduceMotion: false, now: now)
        #expect(footer.robot.displayText == "実行中" && footer.timerRunning && footer.robot.eyeOffset == -1.5)
        #expect(footer.robot.isRunning && footer.robot.eyeColor == .white)
        #expect(footer.robot.statusFont.pointSize == 11)
        #expect(("実行中" as NSString).size(withAttributes: [.font: footer.robot.statusFont]).width <= 36)
        footer.refresh(now: now.addingTimeInterval(1))
        #expect(footer.robot.eyeOffset == 1.5 && footer.robot.tint == Washi.red)
        #expect(footer.robot.layer?.animationKeys()?.isEmpty != false)
        visible = false; footer.updateVisibility()
        #expect(!footer.timerRunning)
        visible = true; footer.updateVisibility()
        #expect(footer.timerRunning)
        footer.isHidden = true; footer.updateVisibility()
        #expect(!footer.timerRunning)
        footer.isHidden = false
        footer.update(state, reduceMotion: true, now: now)
        #expect(!footer.timerRunning && footer.robot.eyeOffset == 0 && footer.robot.displayText == "実行中")
        #expect(footer.robot.isRunning && footer.robot.eyeColor == .white)
        footer.update(SessionSnapshot(), reduceMotion: false, now: now)
        #expect(!footer.timerRunning && footer.robot.displayText.isEmpty && !footer.robot.isEnabled)
        #expect(footer.robot.isHidden && footer.arrangedSubviews[1].isHidden)
        #expect(footer.robot.toolTip == "AI連携が設定されていません")
        footer.update(state, reduceMotion: true, now: now)
        #expect(!footer.robot.isHidden && !footer.arrangedSubviews[1].isHidden)
    }

    @Test func フッターのAI操作を左端一つへまとめ解除をその他から外す() {
        _ = NSApplication.shared
        let window = TranscriptWindowController()
        var state = SessionSnapshot(ai: AIViewState(), state: .recording)
        state.aiSchedule.active = true
        window.apply(state)
        #expect(window.compactFooter.arrangedSubviews.count == 7)
        #expect(!window.footerMenu().items.contains { $0.title == "自動送信を停止" })
    }

    @Test func 実行中の反転とカウントダウンを600幅で撮る() throws {
        guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] else { return }
        _ = NSApplication.shared
        let controller = TranscriptWindowController(shouldReduceMotion: { true })
        let window = controller.window!
        window.setFrameAutosaveName("")
        window.setContentSize(NSSize(width: 600, height: 578))
        window.setFrameOrigin(NSPoint(x: 20000, y: 20000))
        var state = try waitingState()
        state.timeline = .init(startedAt: Date(timeIntervalSince1970: 1_788_759_600))
        state.elapsed = 754
        state.utterances = [.init(speaker: 0, start: 2, end: 4, text: "会場は本社の大会議室にしましょう。")]
        controller.apply(state)
        let content = window.contentView!
        content.layoutSubtreeIfNeeded()
        for phase in 0...2 {
            let robot = controller.compactFooter.robot
            var schedule = AIScheduleViewState()
            schedule.active = true; schedule.nextFire = Date(timeIntervalSince1970: 1150)
            robot.update(schedule: schedule, waiting: phase < 2, animate: true, now: Date(timeIntervalSince1970: Double(1000 + (phase % 2))))
            content.displayIfNeeded()
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: output).appendingPathComponent("robot-\(phase)-600.png"))
        }
    }
}
