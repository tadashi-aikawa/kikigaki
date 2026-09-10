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
        #expect(!footer.robot.isRunning && footer.robot.eyeColor == Washi.muted)
        #expect(footer.robot.tint == Washi.muted)
        state.aiSchedule.active = true; state.aiSchedule.nextFire = now.addingTimeInterval(45)
        state.aiSchedule.destination = "議事録"
        footer.update(state, reduceMotion: false, now: now)
        #expect(footer.robot.displayText == "0:45" && footer.timerRunning)
        #expect(footer.robot.tint == Washi.red && footer.robot.eyeColor == Washi.red)
        #expect(footer.robot.toolTip == "次 0:45 · 議事録へ")
        state.aiSchedule.nextFire = now.addingTimeInterval(150)
        footer.update(state, reduceMotion: true, now: now)
        #expect(footer.robot.displayText == "2:30" && footer.timerRunning)
        state.aiSchedule.skipReason = "差分なしでスキップ中"
        footer.update(state, reduceMotion: true, now: now)
        #expect(footer.robot.displayText == "2:30" && footer.robot.toolTip == "差分なしでスキップ中 · 議事録へ")
        state = try waitingState()
        footer.update(state, reduceMotion: false, now: now)
        #expect(footer.robot.displayText == "実行中" && footer.timerRunning && footer.robot.eyeOffset == -1.5)
        #expect(footer.robot.isRunning && footer.robot.eyeColor == .white)
        #expect(footer.robot.statusFont == footer.unread.labelFont)
        #expect(footer.robot.statusFont.pointSize == 9)
        let countdownWidths = ["1:11", "2:30", "8:88"].map {
            ($0 as NSString).size(withAttributes: [.font: footer.robot.statusFont]).width
        }
        #expect(Set(countdownWidths).count == 1)
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
        #expect(window.compactFooter.arrangedSubviews.first === window.compactFooter.robot)
        #expect(window.compactFooter.arrangedSubviews.last === window.compactFooter.more)
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

    @Test func ロボットの顔と未読の丸の中心を同じ高さにする() {
        _ = NSApplication.shared
        let footer = AICompactFooter(visibility: { false })
        footer.robot.frame = NSRect(x: 16, y: 6, width: 36, height: 40)
        footer.unread.frame = NSRect(x: 68, y: 6, width: 36, height: 40)
        let face = footer.robot.convert(footer.robot.headFrame, to: footer)
        let badge = footer.unread.convert(footer.unread.badgeFrame, to: footer)
        #expect(face.midY == badge.midY)
        #expect(footer.robot.headFrame.maxY + 7 <= footer.robot.bounds.height)
        #expect(AIFooterMetrics.labelY == 2)
    }

    @Test func 準備中とスキップ理由別の表示を分けてタイマーを片付ける() throws {
        let footer = AICompactFooter(visibility: { true })
        let now = Date(timeIntervalSince1970: 1000)
        var schedule = AIScheduleState(meetingID: UUID())
        try schedule.start(options: .init(prompt: "更新"), now: now, runID: UUID())
        var state = SessionSnapshot(ai: AIViewState(), state: .recording)
        for availability in [AIScheduleAvailability.ready, .busy, .confirmation, .disconnected] {
            state.aiSchedule = AIScheduleViewState(schedule: schedule, availability: availability, hasChanges: false)
            footer.update(state, reduceMotion: true, now: now)
            #expect(footer.robot.displayText == (availability == .disconnected ? "—" : "3:00"))
            #expect(footer.robot.toolTip?.contains(state.aiSchedule.skipReason!) == true)
        }
        schedule.recordingStopped()
        state.aiSchedule = AIScheduleViewState(schedule: schedule)
        footer.update(state, reduceMotion: false, now: now)
        #expect(footer.robot.displayText == "—")
        state.aiSchedule = AIScheduleViewState()
        state.ai?.isPreparing = true
        footer.update(state, reduceMotion: false, now: now)
        #expect(footer.robot.displayText == "準備中" && footer.timerRunning && !footer.robot.isRunning)
        footer.refresh(now: now.addingTimeInterval(1))
        #expect(footer.robot.eyeOffset == 1.5)
        footer.update(state, reduceMotion: true, now: now)
        #expect(footer.robot.eyeOffset == 0 && !footer.timerRunning)
        state = try waitingState(); state.ai?.isPreparing = true
        footer.update(state, reduceMotion: false, now: now)
        #expect(footer.robot.displayText == "実行中" && !footer.robot.isPreparing)
        footer.update(SessionSnapshot(), reduceMotion: true)
        #expect(!footer.timerRunning)
    }

    @Test func 自動の4状態と目の2コマを600幅の実画面で撮る() throws {
        guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_STATE_CAPTURE"] else { return }
        _ = NSApplication.shared
        let controller = TranscriptWindowController(shouldReduceMotion: { true })
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        window.setContentSize(NSSize(width: 600, height: 578))
        window.setFrameOrigin(NSPoint(x: 20000, y: 20000)); window.orderFront(nil)
        defer { window.orderOut(nil) }
        let now = Date(timeIntervalSince1970: 1000)
        for (name, active, preparing, running, phase) in [
            ("off", false, false, false, 0), ("countdown", true, false, false, 0),
            ("preparing-0", true, true, false, 0), ("preparing-1", true, true, false, 1),
            ("running-0", true, false, true, 0), ("running-1", true, false, true, 1)
        ] {
            var state = try waitingState()
            if !running {
                var conversation = try #require(state.ai?.conversation)
                let request = try #require(conversation.questions.first?.request)
                let event = try AIReceiveEvent(request: request, kind: .answered, recordedAt: Date(),
                    body: "決定事項\n\n- 会場は本社の大会議室\n- 担当は田中さん\n\n次回までに見積もりを確認します。")
                try conversation.update(request.id) { _ = try $0.receive(event, at: Date(), order: 1) }
                state.ai?.conversation = conversation
            }
            state.ai?.isPreparing = preparing
            state.aiSchedule.active = active; state.aiSchedule.nextFire = active ? now.addingTimeInterval(150) : nil
            state.timeline = .init(startedAt: Date(timeIntervalSince1970: 1_788_759_600))
            state.elapsed = 754
            state.utterances = (0..<40).map { index in
                .init(speaker: index % 3, start: Double(index * 15), end: Double(index * 15 + 10),
                      text: index % 2 == 0 ? "会場は本社の大会議室にしましょう。担当と期限も確認します。" : "見積もりを金曜日までに共有します。次回は進捗を確認しましょう。")
            }
            controller.apply(state)
            controller.compactFooter.robot.update(schedule: state.aiSchedule, waiting: running, preparing: preparing,
                animate: true, now: now.addingTimeInterval(Double(phase)))
            let content = try #require(window.contentView)
            content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: output).appendingPathComponent("\(name)-600.png"))
        }
    }
}
