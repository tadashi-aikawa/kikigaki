import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct AIDestinationButtonTests {
    private func waitingState(automatic: Bool, both: Bool = false) throws -> SessionSnapshot {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var history = try AIStreamHistory(meetingID: UUID())
        let context = try history.prepare(lines: [], outputDirectory: root)
        var conversation = AIConversation(meetingID: history.meetingID)
        for side in both ? [true, false] : [automatic] {
            let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
                participantName: "相談", cliPath: "/tmp/helper",
                sessionPath: root.appendingPathComponent(".kikigaki-context/\(history.meetingID)/ai/sessions/\(side ? 1 : 2)/1.json").path,
                requestToken: "test", question: "確認", capturedAt: Date(), audioCutoffSeconds: 0,
                trigger: side ? .scheduled : nil, profile: "相談", profileSlot: side ? 1 : 2)
            let request = try AIRequest(envelope: AIEnvelope(snapshot: context, participant: participant),
                number: conversation.questions.count + 1, voiceQuestion: "", snapshot: context)
            try conversation.append(request)
            try conversation.update(request.id) { try $0.beginSending(at: Date()); try $0.submitted() }
        }
        return SessionSnapshot(ai: AIViewState(conversation: conversation), state: .recording)
    }

    @Test func 自動メニューは状態別に切り替え最後の1回も解除できる() throws {
        _ = NSApplication.shared
        let window = TranscriptWindowController()
        var state = SessionSnapshot(ai: AIViewState(), state: .recording, markdownURL: URL(fileURLWithPath: "/tmp/test.md"))
        var configured = 0, manual = 0, fired = 0, stopped = 0
        window.onScheduleAI = { configured += 1 }; window.onAskAI = { _ in manual += 1 }
        window.onFireScheduleAI = { fired += 1 }; window.onStopScheduleAI = { stopped += 1 }
        window.apply(state)
        let idle = window.automaticMenu()
        #expect(idle.items.map(\.title) == ["自動実行…"])
        #expect(window.automaticMenuPosition(idle).y - idle.size.height > window.compactFooter.automaticDestination.bounds.maxY)
        idle.performActionForItem(at: 0)
        window.compactFooter.manualDestination.performClick(nil)
        #expect(configured == 1 && manual == 1)
        #expect(window.compactFooter.manualDestination.destinationName == "指定しない")
        state.aiSchedule.active = true; state.aiSchedule.nextFire = Date().addingTimeInterval(45)
        window.apply(state)
        let active = window.automaticMenu()
        #expect(active.items.map(\.title) == ["今すぐ送る", "自動実行解除"])
        active.performActionForItem(at: 0); active.performActionForItem(at: 1)
        #expect(fired == 1 && stopped == 1)
        state.ai = try waitingState(automatic: false).ai; window.apply(state)
        #expect(window.compactFooter.manualDestination.displayText == "実行中")
        #expect(!window.automaticMenu().items[0].isEnabled)
        active.performActionForItem(at: 0)
        #expect(fired == 1)
        // 録音停止後、最後の1回を保留している間も解除は押せる。
        state.state = .idle; state.aiSchedule.nextFire = nil; window.apply(state)
        let final = window.automaticMenu()
        #expect(final.items.map(\.title) == ["今すぐ送る", "自動実行解除"])
        #expect(!final.items[0].isEnabled && final.items[1].isEnabled)
        final.performActionForItem(at: 1)
        #expect(stopped == 2)
        #expect(!window.compactFooter.manualDestination.isEnabled)
        #expect(window.compactFooter.manualDestination.displayText == "実行中")
        #expect(window.compactFooter.manualDestination.fillColor.alphaComponent < 1)
        window.compactFooter.manualDestination.performClick(nil)
        #expect(manual == 1)
        state.aiSchedule.active = false; window.apply(state)
        #expect(window.automaticMenu().items.map(\.title) == ["自動実行…"])
        #expect(!window.automaticMenu().items[0].isEnabled)
        #expect(!window.compactFooter.destinations.isHidden)
    }

    @Test func 作り直しはその他メニューへ移し録音停止後は出さない() {
        _ = NSApplication.shared
        let window = TranscriptWindowController()
        var state = SessionSnapshot(ai: AIViewState(canRecreate: true), state: .recording,
                                    markdownURL: URL(fileURLWithPath: "/tmp/test.md"))
        window.apply(state)
        #expect(!window.automaticMenu().items.contains { $0.title == "AIセッションを作り直す" })
        let menu = window.footerMenu()
        var recreated = 0; window.onRecreateAI = { recreated += 1 }
        menu.performActionForItem(at: menu.items.firstIndex { $0.title == "AIセッションを作り直す" }!)
        #expect(recreated == 1)
        state.state = .idle; window.apply(state)
        #expect(!window.footerMenu().items.contains { $0.title == "AIセッションを作り直す" })
    }

    @Test func カウントダウンの条件と可視性でタイマーを止める() {
        _ = NSApplication.shared
        var visible = true
        let footer = AICompactFooter(visibility: { visible })
        let now = Date(timeIntervalSince1970: 1000)
        var state = SessionSnapshot(ai: AIViewState(), state: .recording)
        footer.update(state, reduceMotion: false, now: now)
        #expect(footer.automaticDestination.destinationName == "送らない")
        #expect(footer.manualDestination.destinationName == "指定しない")
        #expect(!footer.timerRunning)
        state.aiSchedule.active = true; state.aiSchedule.nextFire = now.addingTimeInterval(45)
        state.aiSchedule.destination = "議事録"
        footer.update(state, reduceMotion: false, now: now)
        #expect(footer.automaticDestination.displayText == "0:45" && footer.timerRunning)
        #expect(footer.automaticDestination.toolTip == "自動実行を待っています · 議事録へ")
        state.aiSchedule.nextFire = now.addingTimeInterval(150)
        state.aiSchedule.skipReason = "差分なしでスキップ中"
        footer.update(state, reduceMotion: true, now: now)
        #expect(footer.automaticDestination.displayText == "2:30" && footer.timerRunning)
        #expect(footer.automaticDestination.toolTip == "差分なしでスキップ中 · 議事録へ")
        state.ai?.automaticPreparing = true
        footer.update(state, reduceMotion: false, now: now)
        #expect(footer.automaticDestination.displayText == "準備中" && !footer.timerRunning)
        state.ai?.automaticPreparing = false
        state.ai?.manualPreparing = true
        footer.update(state, reduceMotion: true, now: now)
        #expect(footer.automaticDestination.displayText == "2:30" && footer.timerRunning)
        visible = false; footer.updateVisibility(); #expect(!footer.timerRunning)
        visible = true; footer.updateVisibility(); #expect(footer.timerRunning)
        footer.isHidden = true; footer.updateVisibility(); #expect(!footer.timerRunning)
        footer.isHidden = false
        state.aiSchedule.canCountDown = false
        footer.update(state, reduceMotion: false, now: now)
        #expect(footer.automaticDestination.displayText == "—" && !footer.timerRunning)
        state.aiSchedule.canCountDown = true; state.aiSchedule.nextFire = nil
        footer.update(state, reduceMotion: false, now: now)
        #expect(footer.automaticDestination.displayText == "—" && !footer.timerRunning)
        footer.update(SessionSnapshot(), reduceMotion: false)
        #expect(footer.destinations.isHidden && footer.arrangedSubviews[1].isHidden && !footer.timerRunning)
        footer.update(state, reduceMotion: true, now: now)
        #expect(!footer.destinations.isHidden && !footer.arrangedSubviews[1].isHidden)
    }

    @Test func 準備中と実行中を送った側だけに表示し両方も塗る() throws {
        let footer = AICompactFooter(visibility: { true })
        let now = Date(timeIntervalSince1970: 1000)
        for automatic in [false, true] {
            var state = try waitingState(automatic: automatic)
            state.manualDestination = .init(slot: 1, name: "会議の固定宛先")
            footer.update(state, reduceMotion: true, now: now)
            let running = automatic ? footer.automaticDestination : footer.manualDestination
            let other = automatic ? footer.manualDestination : footer.automaticDestination
            #expect(running.isRunning && running.filled && running.foreground == .white)
            #expect(running.displayText == "実行中" && !other.filled && !footer.timerRunning)
            #expect(footer.manualDestination.destinationName == "会議の固定宛先")
            state.ai?.automaticPreparing = !automatic
            state.ai?.manualPreparing = automatic
            footer.update(state, reduceMotion: false, now: now)
            #expect(running.isRunning && other.isPreparing)
            #expect(other.displayText == "準備中" && other.filled && other.foreground == .white)
        }
        let both = try waitingState(automatic: true, both: true)
        footer.update(both, reduceMotion: true, now: now)
        #expect(footer.automaticDestination.isRunning && footer.manualDestination.isRunning)
        #expect(footer.automaticDestination.filled && footer.manualDestination.filled)
    }

    @Test func 長い間隔と状態文字は固定サイズで名前の領域を侵食しない() {
        let button = AIFooterDestination(automatic: true)
        button.frame = NSRect(x: 0, y: 0, width: 159, height: 20)
        let now = Date(timeIntervalSince1970: 1000)
        var schedule = AIScheduleViewState(); schedule.active = true
        for (seconds, expected) in [(7200.0, "120:00"), (5730.0, "95:30"), (6000.0, "100:00")] {
            schedule.nextFire = now.addingTimeInterval(seconds)
            button.update(.init(slot: 1, name: "長い名前の宛先"), schedule: schedule, waiting: false, preparing: false, now: now)
            #expect(button.displayText == expected)
            #expect(button.nameFrame.width > 0)
            #expect(button.nameFrame.maxX + 6 + button.statusWidth + 20 <= button.bounds.width)
        }
        let widths = ["111:11", "120:00", "888:88"].map {
            ($0 as NSString).size(withAttributes: [.font: button.statusFont]).width
        }
        #expect(Set(widths).count == 1)
        #expect(button.statusFont.pointSize == 10 && button.nameFont.pointSize == 12)
    }
}
