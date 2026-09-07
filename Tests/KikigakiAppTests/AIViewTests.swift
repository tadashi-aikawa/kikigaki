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
    private func request(_ number: Int, history: inout AIStreamHistory, root: URL, question: String = "抜けている観点はありますか", voiceStart: Double? = nil, parent: UUID? = nil) throws -> AIRequest {
        let snapshot = try history.prepare(lines: ["[14:05:20] 田中: 社内で体験会を開きます。", "[14:05:30] 松村: 抜けている観点はありますか。"], outputDirectory: root)
        let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: "迅雷", cliPath: root.appendingPathComponent("helper").path,
            sessionPath: root.appendingPathComponent(".kikigaki-context/\(snapshot.meetingID.uuidString)/ai/sessions/1.json").path, requestToken: UUID().uuidString,
            question: question, capturedAt: started.addingTimeInterval(Double(320 + number * 5)), audioCutoffSeconds: 330,
            inReplyToRequestID: parent, inReplyToEventID: parent.map { "\($0.uuidString)/result" })
        return try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant), number: number,
            voiceQuestion: "うんうん、悪くはないかな。ありがとう。", snapshot: snapshot, voiceUtteranceStart: voiceStart)
    }

    @Test func 宛名と親番号で送信と返事を表示する() throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID(); var history = try AIStreamHistory(meetingID: meeting)
        let first = try request(1, history: &history, root: root, question: "案内文をファイルへ追記して")
        var conversation = AIConversation(meetingID: meeting)
        try conversation.append(first)
        try conversation.update(first.id) { try $0.beginSending(at: started.addingTimeInterval(325)); try $0.submitted() }
        _ = try conversation.receive(AIReceiveEvent(request: first, kind: .needsInput, recordedAt: started.addingTimeInterval(326), body: "社内向けの案内でよいですか？", reason: "clarification"), at: started.addingTimeInterval(326))
        let followup = try request(2, history: &history, root: root, question: "はい、社内向けでお願いします", parent: first.id)
        try conversation.append(followup)
        try conversation.update(followup.id) { try $0.beginSending(at: started.addingTimeInterval(330)); try $0.submitted() }
        _ = try conversation.receive(AIReceiveEvent(request: followup, kind: .answered, recordedAt: started.addingTimeInterval(331), body: "案内文を追記しました。"), at: started.addingTimeInterval(331))
        let marks = AIInlineMark.ordered(conversation)
        #expect(marks.map(\.title) == ["#1 迅雷へ", "#1 迅雷の確認", "#2 #1への返答", "#2 迅雷から"])
        #expect(AIMarkdown.section(conversation).contains("### AI #1"))
        var state = SessionSnapshot(ai: AIViewState(conversation: conversation), state: .recording,
            utterances: [.init(speaker: 0, start: 320, end: 322, text: "案内は社内向けで進めましょう。")],
            timeline: .init(startedAt: started), elapsed: 340, markdownURL: root.appendingPathComponent("meeting.md"))
        state.handoffPreview = HandoffHistory().preview(utterances: state.utterances, names: state.names, timeline: state.timeline)
        let window = TranscriptWindowController(shouldReduceMotion: { true })
        window.window!.setFrameAutosaveName("")
        window.window!.setFrame(NSRect(x: 20000, y: 20000, width: 680, height: 620), display: false)
        window.apply(state)
        let content = window.window!.contentView!; content.layoutSubtreeIfNeeded()
        let labels = descendants(content).compactMap { $0 as? NSButton }.map(\.title)
        #expect(labels.contains("▸ #1 迅雷へ · 案内文をファイルへ追記して"))
        #expect(labels.contains("▸ #2 #1への返答 · はい、社内向けでお願いします"))
        try capture("wording-marks", view: content.superview!)
        let sheet = AIQuestionSheet(participant: "迅雷", parentNumber: nil, draft: "次の案内も整えてください", voice: "", range: "直近1発言", tentative: false, canSubmit: true)
        #expect(descendants(sheet.window.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "迅雷へ" })
        let footer = try #require(descendants(content).compactMap { $0 as? NSTextField }.first { $0.stringValue == "AIへ渡す会話" }?.superview?.superview)
        let bitmap = try #require(footer.bitmapImageRepForCachingDisplay(in: footer.bounds)); footer.cacheDisplay(in: footer.bounds, to: bitmap)
        let footerImage = NSImage(size: footer.bounds.size); footerImage.addRepresentation(bitmap)
        let sheetContent = sheet.window.contentView!
        let composite = NSBox(frame: NSRect(x: 0, y: 0, width: 680, height: 470))
        composite.boxType = .custom; composite.borderType = .noBorder; composite.fillColor = Washi.paper
        let footerView = NSImageView(frame: NSRect(x: 0, y: 0, width: 680, height: footer.bounds.height)); footerView.image = footerImage
        composite.addSubview(footerView); composite.addSubview(sheetContent)
        sheetContent.frame = NSRect(x: 88, y: 110, width: 504, height: 344)
        try capture("wording-sheet-footer", view: composite)
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
        #expect(state.ai?.badges == "未読 1 · 確認待ち 1 · 返事待ち 1 · 失敗 1")
        #expect(descendants(content).compactMap { $0 as? AIBadgeButton }.filter { !$0.isHidden }.map(\.title) == ["未読 1", "確認待ち 1", "返事待ち 1", "失敗 1"])
        // 手入力の横スクロール欄を除き、AI本文が独立スクロールを作らないことを確認する。
        #expect(descendants(content).compactMap { $0 as? NSScrollView }.filter { !($0 is TypedEntryField) }.count == 1)
        #expect(!descendants(content).compactMap { $0 as? NSButton }.contains { $0.title.contains("AIとのやりとり") || $0.title == "既読にする" })
        #expect(marks().count == 6 && marks().allSatisfy { !$0.expanded && $0.height(for: 680) == 28 })
        let answer = try #require(marks().first { $0.title == "#1 迅雷から" })
        let confirmation = try #require(marks().first { $0.title == "#2 迅雷の確認" })
        let waiting = try #require(marks().first { $0.title == "#3 迅雷へ" })
        #expect(answer.accent == .unread && answer.accentColor == Washi.red)
        #expect(confirmation.accent == .confirmation)
        #expect(answer.statusPill == "未読" && confirmation.statusPill == "確認待ち")
        #expect(answer.date == started.addingTimeInterval(370))
        try capture("collapsed", view: content.superview!)
        try capture("unread-emphasis", view: content.superview!)
        state.previousAIUnread = 1; apply()
        var previousOpened = false
        window.onShowPreviousAI = { previousOpened = true }
        let previous = try #require(descendants(content).compactMap { $0 as? AIBadgeButton }.first { $0.title == "前の会議に返事あり" })
        previous.performClick(nil); #expect(previousOpened)
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
        #expect(descendants(answer).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "送信文: " + requests[0].displayQuestion && !$0.isHidden })
        #expect(readIDs == [requests[0].id])
        #expect(answer.expanded && answer.accent == .muted)
        #expect(answer.statusPill == nil)
        #expect(abs(answer.frame.minY - window.scrollView.contentView.bounds.minY - position) < 1)
        let answerBody = try #require(descendants(answer).compactMap { $0 as? MarkdownBodyView }.first)
        #expect(answerBody.string == body.replacingOccurrences(of: "- ", with: "•\t"))
        #expect(answerBody.isSelectable && !answerBody.isEditable)
        #expect(!state.ai!.badges.contains("未読"))
        try capture("answer-expanded", view: content.superview!)
        try capture("read-emphasis", view: content.superview!)
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
        #expect(confirmation.accent == .muted && confirmation.statusPill == nil)
        #expect(descendants(confirmation).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "?" && !$0.isHidden })
        #expect(descendants(confirmation).compactMap { $0 as? MarkdownBodyView }.contains { $0.string.hasPrefix("参加対象") })
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
        let failed = try #require(marks().first { $0.title == "#4 迅雷へ" })
        try click(failed)
        #expect(descendants(failed).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("失敗 · 接続先を確認してください") })
        #expect(descendants(failed).compactMap { $0 as? NSButton }.filter { $0.title == "取消" }.allSatisfy { $0.isHidden })
        let sheet = AIQuestionSheet(participant: "迅雷", parentNumber: 2, draft: "社内だけです", voice: "", range: "直近2発言 · 14:05:20〜14:05:30", tentative: false, canSubmit: true, confirmation: "参加対象は社内だけですか？")
        #expect(descendants(sheet.window.contentView!).compactMap { $0 as? NSButton }.contains { $0.title == "送信 ⏎" && $0.keyEquivalent == "\r" })
    }

    @Test func 声の問いは発話直下で回答には抜粋と全文を示しバッジから移動する() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID(); var history = try AIStreamHistory(meetingID: meeting)
        let request = try request(1, history: &history, root: root, question: "", voiceStart: 320)
        var conversation = AIConversation(meetingID: meeting)
        try conversation.append(request)
        try conversation.update(request.id) { try $0.beginSending(at: started.addingTimeInterval(343)); try $0.submitted() }
        _ = try conversation.receive(AIReceiveEvent(request: request, kind: .answered, recordedAt: started.addingTimeInterval(372), body: "了解しました。\nこの案をもとに、次の打ち合わせで検討しましょう。"), at: started.addingTimeInterval(373))
        var state = SessionSnapshot(ai: AIViewState(conversation: conversation), state: .recording,
            utterances: [.init(speaker: 0, start: 320, end: 325, text: "うんうん、悪くはないかな。"), .init(speaker: 0, start: 330, end: 333, text: "ありがとう。")],
            timeline: .init(startedAt: started), elapsed: 380, markdownURL: root.appendingPathComponent("meeting.md"))
        state.handoffPreview = HandoffHistory().preview(utterances: state.utterances, names: state.names, timeline: state.timeline)
        let window = TranscriptWindowController(shouldReduceMotion: { true })
        window.window!.setFrameAutosaveName("")
        window.window!.setFrame(NSRect(x: 20000, y: 20000, width: 680, height: 620), display: false)
        let content = window.window!.contentView!
        window.apply(state); content.layoutSubtreeIfNeeded()
        window.onReadAI = { id in
            try! conversation.update(id) { $0.markRead() }
            state.ai?.conversation = conversation; window.apply(state)
        }
        let rows = window.transcriptDocument.rows
        let question = try #require(rows[1] as? AIMarkRow)
        #expect(question.mark.kind == .question && question.date == started.addingTimeInterval(343))
        #expect(rows[0] is TranscriptRow && rows[2] is TranscriptRow)
        try click(question); content.layoutSubtreeIfNeeded()
        try capture("fb3-voice-anchor", view: content.superview!)
        try click(question)
        let answer = try #require(rows.compactMap { $0 as? AIMarkRow }.first { $0.mark.kind == .result })
        let toggle = try #require(descendants(answer).compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("▸ ") })
        #expect(toggle.title == "▸ #1 迅雷から · 了解しました。")
        #expect(toggle.cell?.lineBreakMode == .byTruncatingTail)
        #expect(toggle.frame.maxX <= answer.bounds.width - 80)
        try capture("fb3-answer-collapsed", view: content.superview!)
        try click(answer); content.layoutSubtreeIfNeeded()
        try capture("fb3-answer-expanded", view: content.superview!)
        // 再分割で元の開始位置が消えても、改名済みの直前の発話へ配置する。
        state.utterances[0] = .init(speaker: 0, start: 315, end: 325, text: "先ほどの案は、うんうん、悪くはないかな。")
        state.names = SpeakerNames([0: "田中"])
        window.apply(state)
        #expect(window.transcriptDocument.rows[1] === question)
        for index in 0..<25 {
            let start = Double(400 + index * 10)
            state.utterances.append(Utterance(speaker: 0, start: start, end: start + 5, text: "後続の会話 \(index)"))
        }
        let next = try self.request(2, history: &history, root: root)
        try conversation.append(next)
        try conversation.update(next.id) { try $0.beginSending(at: started.addingTimeInterval(500)); try $0.submitted() }
        _ = try conversation.receive(AIReceiveEvent(request: next, kind: .answered, recordedAt: started.addingTimeInterval(600), body: "次の回答"), at: started.addingTimeInterval(601))
        state.ai?.conversation = conversation
        window.apply(state); content.layoutSubtreeIfNeeded()
        window.scrollView.contentView.scroll(to: .zero)
        let unread = try #require(descendants(content).compactMap { $0 as? AIBadgeButton }.first { $0.kind == .unread })
        unread.performClick(nil)
        let nextAnswer = try #require(window.transcriptDocument.rows.compactMap { $0 as? AIMarkRow }.first { $0.mark.id == next.id.uuidString + "/result" })
        #expect(window.scrollView.contentView.bounds.intersects(nextAnswer.frame))
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
        #expect(!buttons.contains { $0.title.hasPrefix("AIへ") })
        #expect(buttons.filter { ["取消", "返答する"].contains($0.title) }.allSatisfy { $0.isHidden })
        #expect(descendants(content).compactMap { $0 as? NSPopUpButton }.first?.titleOfSelectedItem == "old")
        try capture("previous-meeting", view: content.superview!)
    }
}
