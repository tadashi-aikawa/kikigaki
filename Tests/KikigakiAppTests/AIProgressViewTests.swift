import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct AIProgressViewTests {
    private let sent = Date(timeIntervalSince1970: 100)
    private func conversation(count: Int = 1, accepted: Bool = true) throws -> AIConversation {
        let meeting = UUID()
        var result = AIConversation(meetingID: meeting)
        let root = URL(fileURLWithPath: "/tmp/ai-progress-ui-tests")
        for slot in 1...count {
            var history = try AIStreamHistory(meetingID: meeting)
            let snapshot = try history.prepare(lines: ["[00:00:01] 話者A: 確認してください"], outputDirectory: root)
            let participant = AIParticipantContext(streamID: snapshot.streamID, requestID: UUID(), sessionGeneration: 1,
                participantName: "宛先\(slot)", cliPath: "/tmp/helper",
                sessionPath: root.appendingPathComponent(".kikigaki-context/\(meeting)/"
                    + AIEnvelope.sessionPath(slot: slot, generation: 1)).path,
                requestToken: "test", question: "", capturedAt: sent,
                audioCutoffSeconds: 2, profile: "宛先\(slot)", profileSlot: slot)
            let request = try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant),
                number: slot, voiceQuestion: "確認してください", snapshot: snapshot, voiceUtteranceStart: 1)
            try result.append(request)
            try result.update(request.id) { try $0.beginSending(at: sent); try $0.submitted() }
            if accepted { try result.receive(AIReceiveEvent(request: request, kind: .accept, recordedAt: sent), at: sent) }
        }
        return result
    }
    private func rows(_ controller: TranscriptWindowController) -> [AIReplyRow] {
        controller.transcriptDocument.rows.compactMap { $0 as? AIReplyRow }
    }

    @Test func 宛先ごとの観測と履歴を行へ渡し切替時に破棄する() throws {
        _ = NSApplication.shared
        let conversation = try conversation(count: 3)
        var state = SessionSnapshot(ai: AIViewState(conversation: conversation, connection: .blocked,
            editing: [conversation.questions[0].request.id: AIEditingReport(total: 2)],
            selectedSlot: 3, connections: [1: .working, 2: .idle, 3: .blocked], generations: [1: 1, 2: 1, 3: 1]),
            timeline: MeetingTimeline(startedAt: sent))
        let controller = TranscriptWindowController(shouldReduceMotion: { true })
        controller.apply(state)
        #expect(rows(controller).map { $0.progressView.progress?.status } == [.editing, .awaitingReply, .blocked])
        #expect(rows(controller)[0].progressView.displayText.hasPrefix("編集中(全2か所) · "))
        #expect(rows(controller).allSatisfy { $0.noteText.isEmpty && $0.height(for: 600) == 82 })
        state.ai?.connections[1] = .disconnected
        state.ai?.generations[3] = 2
        controller.apply(state)
        #expect(rows(controller)[0].progressView.progress?.currentStage == .editing)
        #expect(rows(controller)[0].progressView.progress?.status == .disconnected)
        #expect(rows(controller)[2].progressView.progress?.status == .unknown)
        state.ai?.connections.removeValue(forKey: 2)
        state.ai?.generations.removeValue(forKey: 2)
        #expect(state.ai?.generation(for: conversation.questions[1].request) == nil)
        #expect(state.ai?.connection(for: conversation.questions[1].request) == .unknown)
        controller.apply(state)
        #expect(rows(controller)[1].progressView.progress?.status == .unknown)
        // 申告が読めなくなっても、確認済みの編集は表示用の履歴が保つ。
        state.ai?.editing = [:]
        controller.apply(state)
        #expect(rows(controller)[0].progressView.progress?.currentStage == .editing)
        state.timeline = MeetingTimeline(startedAt: sent.addingTimeInterval(1))
        controller.apply(state)
        // 会議を切り替えたら表示用の履歴も捨てる。前の会議の編集を新しい行へ持ち越さない。
        #expect(rows(controller)[0].progressView.progress?.currentStage == .reading)
        state.ai?.readOnly = true; state.ai?.connections[1] = .working
        controller.apply(state)
        #expect(rows(controller).allSatisfy { $0.progressView.displayText == "読込済み · 作業中" && !$0.progressView.timerRunning })
    }

    @Test func 返答で同じ行の進行表示を終了し送達不明には返事行を作らない() throws {
        _ = NSApplication.shared
        var conversation = try conversation(accepted: false)
        let request = conversation.questions[0].request
        var state = SessionSnapshot(ai: AIViewState(conversation: conversation, connection: .working))
        let controller = TranscriptWindowController(shouldReduceMotion: { false })
        controller.apply(state)
        let row = try #require(rows(controller).first)
        #expect(row.progressView.progress?.currentStage == .sending)
        try conversation.receive(AIReceiveEvent(request: request, kind: .answered, recordedAt: sent, body: "回答です"), at: sent)
        state.ai?.conversation = conversation; controller.apply(state)
        #expect(rows(controller).first === row)
        // 到着の点灯が終わるまでは同じ行が進行表示を保つ。
        #expect(row.isShowingArrival && !row.progressView.timerRunning)
        row.stopArrival()
        #expect(row.progressView.isHidden && !row.progressView.timerRunning)
        var unknown = AIConversation(meetingID: conversation.meetingID)
        try unknown.append(request); try unknown.update(request.id) { try $0.beginSending(at: sent) }
        state.ai?.conversation = unknown; controller.apply(state)
        #expect(rows(controller).isEmpty)
        #expect(controller.transcriptDocument.rows.compactMap { $0 as? AISendLineRow }.first?.displayText.contains("送達不明") == true)
    }

    @Test(arguments: [false, true]) func 返答到着は全段点灯を見せてから本文へ入れ替える(reduceMotion: Bool) throws {
        _ = NSApplication.shared
        var conversation = try conversation()
        let request = conversation.questions[0].request
        var state = SessionSnapshot(ai: AIViewState(conversation: conversation, connection: .working,
            editing: [request.id: AIEditingReport(total: 2)], connections: [1: .working], generations: [1: 1]),
            timeline: MeetingTimeline(startedAt: sent))
        let controller = TranscriptWindowController(shouldReduceMotion: { reduceMotion })
        controller.apply(state)
        let row = try #require(rows(controller).first)
        #expect(row.isWaiting && !row.isShowingArrival)
        try conversation.receive(AIReceiveEvent(request: request, kind: .answered, recordedAt: sent, body: "回答です"), at: sent)
        state.ai?.conversation = conversation
        controller.apply(state)
        #expect(rows(controller).first === row)
        #expect(row.isShowingArrival == !reduceMotion)
        if reduceMotion {
            // 視差効果を減らす設定では点灯せず即入れ替える。
            #expect(row.progressView.isHidden && !row.isWaiting)
            return
        }
        let progress = try #require(row.progressView.progress)
        #expect(progress.isArrival && progress.observedStages == Set(AIProgress.Stage.allCases))
        #expect(progress.currentStage == nil && row.progressView.displayText == "返答到着")
        #expect(!row.progressView.isHidden && !row.progressView.timerRunning && row.isWaiting)
        row.stopArrival()
        #expect(!row.isShowingArrival && !row.isWaiting && row.progressView.isHidden)
        // 到着済みの行を開き直しても点灯しない。
        let reopened = TranscriptWindowController(shouldReduceMotion: { false })
        reopened.apply(state)
        #expect(rows(reopened).first?.isShowingArrival == false)
    }

    @Test func 可視範囲と動きを減らす設定で時計を止め再表示時に現在時刻へ戻す() throws {
        _ = NSApplication.shared
        var visible = true
        let view = AIProgressView(visibility: { visible })
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1000))
        document.addSubview(view); scroll.documentView = document
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 44)
        let question = try conversation().questions[0]
        let progress = AIProgress(question: question, connection: .working, connectionGeneration: 1)
        view.update(progress, reduceMotion: false, now: sent.addingTimeInterval(42))
        #expect(view.timerRunning && view.displayText.hasSuffix("0:42経過"))
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 500)); view.updateVisibility()
        #expect(!view.timerRunning)
        scroll.contentView.setBoundsOrigin(.zero); view.updateVisibility(now: sent.addingTimeInterval(80))
        #expect(view.timerRunning && view.displayText.hasSuffix("1:20経過"))
        visible = false; view.updateVisibility()
        #expect(!view.timerRunning)
        visible = true; view.update(progress, reduceMotion: true, now: sent.addingTimeInterval(90))
        #expect(!view.timerRunning && view.displayText.hasSuffix("1:30経過"))
        view.updateVisibility(now: sent.addingTimeInterval(95))
        #expect(view.displayText.hasSuffix("1:30経過"))
        view.isHidden = true; view.updateVisibility()
        view.isHidden = false; view.updateVisibility(now: sent.addingTimeInterval(100))
        #expect(!view.timerRunning)
        view.update(nil, reduceMotion: false)
        #expect(!view.timerRunning && view.isHidden)
    }

    @Test func 実ウィンドウの遮蔽と最小化と開き直しとスクロールで時計を制御する() async throws {
        // AppKitの実イベントループを持つ別プロセスで検証する。可視性の注入・通知の偽造はしない。
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = root.appendingPathComponent(".build/debug/Kikigaki")
        process.arguments = ["--show-window"]
        var environment = ProcessInfo.processInfo.environment
        environment["KIKIGAKI_DEBUG_AI_PROGRESS_VERIFY"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        for _ in 0..<1200 where process.isRunning { try await Task.sleep(for: .milliseconds(25)) }
        try #require(!process.isRunning, "ウィンドウ検証が30秒以内に終了する")
        let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, Comment(rawValue: log))
        #expect(log.contains("AI progress window verification passed"), Comment(rawValue: log))
    }
}
