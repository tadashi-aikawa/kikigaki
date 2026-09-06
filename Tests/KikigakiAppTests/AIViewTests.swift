import AppKit
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import Kikigaki

@Suite @MainActor struct AIViewTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func click(_ row: AIMarkRow) throws {
        let button = try #require(descendants(row).compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("▸ ") || $0.title.hasPrefix("▾ ") })
        button.performClick(nil)
    }
    private func capture(_ name: String, view: NSView) throws {
        guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] else { return }
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
    }
    private let started = Date(timeIntervalSince1970: 1_788_759_600)
    private func request(_ number: Int, history: inout AIStreamHistory, root: URL, question: String = "抜けている観点はありますか") throws -> AIRequest {
        let snapshot = try history.prepare(lines: ["[14:05:20] 田中: 社内で体験会を開きます。", "[14:05:30] 松村: 抜けている観点はありますか。"], outputDirectory: root)
        let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: "迅雷", cliPath: root.appendingPathComponent("helper").path,
            sessionPath: root.appendingPathComponent(".kikigaki-context/\(snapshot.meetingID.uuidString)/ai/sessions/1.json").path, requestToken: UUID().uuidString,
            question: question, capturedAt: started.addingTimeInterval(Double(320 + number * 5)), audioCutoffSeconds: 330)
        return try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant), number: number, snapshot: snapshot)
    }

    @Test func 印をその場で展開し既読と件数と更新後の展開を保つ() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID()
        var history = try AIStreamHistory(meetingID: meeting)
        var conversation = AIConversation(meetingID: meeting)
        let requests = try (1...4).map { try request($0, history: &history, root: root) }
        for request in requests {
            try conversation.append(request)
            if request.number == 4 { try conversation.update(request.id) { try $0.failBeforeSending("接続先を確認してください") } }
            else { try conversation.update(request.id) { try $0.beginSending(at: request.envelope.participant.capturedAt); try $0.submitted() } }
        }
        let body = "対象者と開催日時に加えて、次の点も決めておくと案内が作れます。\n\n- 会場と参加方法\n- 持ち物と連絡先\n- 当日の担当者\n\n社内の試行で集めた声をもとに、次回の対象範囲を見直しましょう。"
        _ = try conversation.receive(AIReceiveEvent(request: requests[0], kind: .answered, recordedAt: started.addingTimeInterval(369), body: body), at: started.addingTimeInterval(370))
        _ = try conversation.receive(AIReceiveEvent(request: requests[1], kind: .needsInput, recordedAt: started.addingTimeInterval(371), body: "参加対象は社内だけですか？\n社外の参加者も含むなら、案内と受付の観点も追加します。", reason: "clarification"), at: started.addingTimeInterval(372))
        var state = SessionSnapshot(ai: AIViewState(conversation: conversation, connection: .working), state: .recording,
            utterances: [Utterance(speaker: 0, start: 320, end: 325, text: "来月の体験会は、まず社内で試しましょう。"),
                         Utterance(speaker: 1, start: 330, end: 334, text: "迅雷、抜けている観点はありますか。"),
                         Utterance(speaker: 0, start: 350, end: 355, text: "次の話題へ進めましょう。")],
            tentativeText: "参加者への案内は", timeline: MeetingTimeline(startedAt: started),
            names: SpeakerNames([0: "田中", 1: "松村"]), elapsed: 375, markdownURL: root.appendingPathComponent("meeting.md"))
        state.handoffPreview = HandoffHistory().preview(utterances: state.utterances, names: state.names, timeline: state.timeline)
        let window = TranscriptWindowController(shouldReduceMotion: { true })
        window.window!.setFrameAutosaveName("")
        window.window!.setFrame(NSRect(x: 20000, y: 20000, width: 680, height: 830), display: false)
        let content = window.window!.contentView!
        func apply() { state.ai?.conversation = conversation; window.apply(state); content.layoutSubtreeIfNeeded() }
        func marks() -> [AIMarkRow] { window.transcriptDocument.rows.compactMap { $0 as? AIMarkRow } }
        apply()
        #expect(state.ai?.badges == "未読 1 · 確認待ち 1 · 回答待ち 1 · 失敗 1")
        #expect(descendants(content).compactMap { $0 as? NSTextField }.contains { $0.stringValue == state.ai?.badges && !$0.isHidden })
        #expect(descendants(content).compactMap { $0 as? NSScrollView }.count == 1)
        #expect(!descendants(content).compactMap { $0 as? NSButton }.contains { $0.title.contains("AIとのやりとり") || $0.title == "既読にする" })
        #expect(marks().count == 6 && marks().allSatisfy { !$0.expanded && $0.height(for: 680) == 28 })
        let answer = try #require(marks().first { $0.title == "Q1 迅雷の回答" })
        let confirmation = try #require(marks().first { $0.title == "Q2 迅雷の確認" })
        let waiting = try #require(marks().first { $0.title == "Q3 迅雷へ質問" })
        #expect(answer.accent == .unread && answer.accentColor == Washi.red)
        #expect(confirmation.accent == .confirmation)
        #expect(answer.date == started.addingTimeInterval(370))
        try capture("collapsed", view: content.superview!)
        let footer = try #require(descendants(content).compactMap { $0 as? NSTextField }.first { $0.stringValue == "AIへ渡す会話" }?.superview?.superview)
        try capture("footer-badges", view: footer)
        var readIDs: [UUID] = []
        window.onReadAI = { id in
            readIDs.append(id)
            try! conversation.update(id) { $0.markRead() }
            apply()
        }
        let position = answer.frame.minY - window.scrollView.contentView.bounds.minY
        try click(answer)
        content.layoutSubtreeIfNeeded()
        #expect(readIDs == [requests[0].id])
        #expect(answer.expanded && answer.accent == .muted)
        #expect(abs(answer.frame.minY - window.scrollView.contentView.bounds.minY - position) < 1)
        #expect(descendants(answer).compactMap { $0 as? NSTextField }.contains { $0.stringValue == body && $0.maximumNumberOfLines == 0 })
        #expect(!state.ai!.badges.contains("未読"))
        try capture("answer-expanded", view: content.superview!)
        state.names = SpeakerNames([0: "相川", 1: "松村"])
        state.utterances.append(Utterance(speaker: 1, start: 380, end: 385, text: "担当者は明日決めましょう。"))
        apply()
        #expect(marks().contains { $0 === answer && $0.expanded })
        #expect(readIDs.count == 1)
        try click(answer)
        #expect(!answer.expanded)
        var replied: UUID?
        window.onAskAI = { replied = $0 }
        try click(confirmation); content.layoutSubtreeIfNeeded()
        #expect(confirmation.accent == .confirmation)
        #expect(descendants(confirmation).compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix("? 参加対象") })
        let reply = try #require(descendants(confirmation).compactMap { $0 as? NSButton }.first { $0.title == "返答する" })
        #expect(!reply.isHidden); reply.performClick(nil)
        #expect(replied == requests[1].id)
        try capture("clarification-expanded", view: content.superview!)
        try click(confirmation)
        var cancelled: UUID?
        window.onCancelAI = { cancelled = $0 }
        try click(waiting); content.layoutSubtreeIfNeeded()
        let cancel = try #require(descendants(waiting).compactMap { $0 as? NSButton }.first { $0.title == "取消" })
        #expect(!cancel.isHidden); cancel.performClick(nil); #expect(cancelled == requests[2].id)
        #expect(descendants(waiting).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("対象: 2発言 · 14:05:20〜14:05:30") })
        try capture("question-expanded", view: content.superview!)
        state.state = .idle; apply()
        #expect(waiting.expanded && answer.accent == .muted)
        let failed = try #require(marks().first { $0.title == "Q4 迅雷へ質問" })
        try click(failed)
        #expect(descendants(failed).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("失敗 · 接続先を確認してください") })
        #expect(descendants(failed).compactMap { $0 as? NSButton }.filter { $0.title == "取消" }.allSatisfy { $0.isHidden })
        let sheet = AIQuestionSheet(participant: "迅雷", parentNumber: 2, draft: "社内だけです", voice: "", range: "直近2発言 · 14:05:20〜14:05:30", tentative: false, canSubmit: true, confirmation: "参加対象は社内だけですか？")
        #expect(descendants(sheet.window.contentView!).compactMap { $0 as? NSButton }.contains { $0.title == "送信 ⏎" && $0.keyEquivalent == "\r" })
    }

    @Test(arguments: [false, true]) func 到着は展開もスクロールもせず確認への返答後は薄墨へ戻す(atBottom: Bool) throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID(); var history = try AIStreamHistory(meetingID: meeting)
        let first = try request(1, history: &history, root: root)
        var conversation = AIConversation(meetingID: meeting)
        try conversation.append(first); try conversation.update(first.id) { try $0.beginSending(at: started.addingTimeInterval(330)) }
        var state = SessionSnapshot(ai: AIViewState(conversation: conversation), state: .recording,
            utterances: (0..<40).map { Utterance(speaker: 0, start: Double($0 * 10), end: Double($0 * 10 + 5), text: "会議の発言 \($0)") },
            timeline: MeetingTimeline(startedAt: started), elapsed: 400, markdownURL: root.appendingPathComponent("meeting.md"))
        let window = TranscriptWindowController(shouldReduceMotion: { true })
        window.window!.setFrameAutosaveName("")
        let content = window.window!.contentView!
        window.apply(state); content.layoutSubtreeIfNeeded()
        window.scrollView.contentView.scroll(to: NSPoint(x: 0, y: atBottom ? window.transcriptDocument.frame.height - window.scrollView.contentSize.height : 100))
        let before = window.scrollView.contentView.bounds.minY
        _ = try conversation.receive(AIReceiveEvent(request: first, kind: .needsInput, recordedAt: started.addingTimeInterval(401), body: "社内だけですか？", reason: "clarification"), at: started.addingTimeInterval(402))
        state.ai?.conversation = conversation; window.apply(state); content.layoutSubtreeIfNeeded()
        let row = try #require(window.transcriptDocument.rows.compactMap { $0 as? AIMarkRow }.first { $0.mark.kind == .result })
        #expect(!row.expanded && row.accent == .confirmation)
        #expect(abs(window.scrollView.contentView.bounds.minY - before) < 1)
        let snapshot = try history.prepare(lines: [], outputDirectory: root)
        let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1, participantName: "迅雷",
            cliPath: root.appendingPathComponent("helper").path,
            sessionPath: root.appendingPathComponent(".kikigaki-context/\(meeting.uuidString)/ai/sessions/1.json").path, requestToken: "test",
            question: "社内だけです", capturedAt: started.addingTimeInterval(403), audioCutoffSeconds: 403,
            inReplyToRequestID: first.id, inReplyToEventID: first.id.uuidString + "/result")
        let followup = try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant), number: 2, snapshot: snapshot)
        try conversation.append(followup)
        try conversation.update(followup.id) { try $0.beginSending(at: started.addingTimeInterval(403)) }
        state.ai?.conversation = conversation; window.apply(state)
        #expect(row.accent == .muted)
    }

    @Test func 旧会議の印も展開で既読にし新規送信の操作は出さない() async throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = try testDirectory(); defer { try? FileManager.default.removeItem(at: registry) }
        let fake = FakeHerdr()
        let store = AIRecordStore(directory: registry, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        let record = try store.begin(meetingID: UUID(), markdownURL: root.appendingPathComponent("old.md"), config: .init(config: AIConfig(), home: root))
        let request = try record.controller.prepare(lines: [], question: "明示質問", voiceQuestion: "", capturedAt: Date(), cutoff: 0,
            tail: nil, config: record.manifest.config, helper: root.appendingPathComponent("helper"))
        try await record.controller.connect(config: record.manifest.config, label: "test", executable: root.appendingPathComponent("fake"), arguments: [])
        try await record.controller.send(request, config: record.manifest.config)
        let event = try AIReceiveEvent(request: request, kind: .answered, recordedAt: Date(), body: "停止後の回答です。")
        try AIFileStore(root: root).write(AIJSON.encode(event), to: [".kikigaki-context", record.manifest.meetingID.uuidString, "ai", "inbox", request.id.uuidString + ".result.json"], replacing: false)
        record.controller.scan()
        let window = AIPastMeetingsWindow(store: store, current: { UUID() }); window.update()
        let content = window.window!.contentView!; content.layoutSubtreeIfNeeded()
        let answer = try #require(descendants(content).compactMap { $0 as? AIMarkRow }.first { $0.mark.kind == .result })
        #expect(answer.accent == .unread)
        try click(answer); content.layoutSubtreeIfNeeded()
        #expect(answer.expanded && !record.controller.conversation.questions[0].isUnread)
        #expect(answer.accent == .muted)
        window.update()
        #expect(descendants(content).compactMap { $0 as? AIMarkRow }.contains { $0 === answer && $0.expanded })
        let buttons = descendants(content).compactMap { $0 as? NSButton }
        #expect(!buttons.contains { $0.title.hasPrefix("AIに質問") })
        #expect(buttons.filter { ["取消", "返答する"].contains($0.title) }.allSatisfy { $0.isHidden })
        #expect(descendants(content).compactMap { $0 as? NSPopUpButton }.first?.titleOfSelectedItem == "old")
        try capture("previous-meeting", view: content.superview!)
    }
}
