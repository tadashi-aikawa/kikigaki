import AppKit
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import Kikigaki

@Suite @MainActor struct AIViewTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func capture(_ name: String, view: NSView) throws {
        guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] else { return }
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
    }
    private let started = Date(timeIntervalSince1970: 1_788_759_600)
    @Test func AIの画像は非同期で反映され未指定や取得失敗は紫のイニシャルになる() async throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID(); var history = try AIStreamHistory(meetingID: meeting)
        let first = try request(1, history: &history, root: root)
        var conversation = AIConversation(meetingID: meeting)
        try conversation.append(first)
        try conversation.update(first.id) { try $0.beginSending(at: started.addingTimeInterval(330)); try $0.submitted() }
        _ = try conversation.receive(AIReceiveEvent(request: first, kind: .answered, recordedAt: started.addingTimeInterval(331),
            body: "確認しました。\n\n- 会場は本社会議室です\n- 受付は9時30分に始めます"), at: started.addingTimeInterval(332))
        let imagePath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/kikigaki.icns").path
        var ai = AIViewState(conversation: conversation)
        ai.selectedSlot = 2
        ai.avatarSources = [1: imagePath, 2: root.appendingPathComponent("missing.png").path]
        var state = SessionSnapshot(ai: ai, state: .recording,
            utterances: [.init(speaker: 0, start: 310, end: 312, text: "会場と受付の時間を確認しましょう。"),
                         try .init(typedText: "案内には会場の地図も添えます。", at: 315,
                                   postedAt: started.addingTimeInterval(315))],
            timeline: MeetingTimeline(startedAt: started), elapsed: 350, markdownURL: root.appendingPathComponent("meeting.md"))
        let window = TranscriptWindowController(shouldReduceMotion: { true })
        window.aiRead.isActive = { false }
        window.window!.setFrameAutosaveName("")
        window.window!.setContentSize(NSSize(width: 900, height: 750))
        let content = window.window!.contentView!
        window.apply(state); content.layoutSubtreeIfNeeded()
        let row = try #require(window.transcriptDocument.rows.compactMap { $0 as? AIReplyRow }.first)
        let avatar = try #require(descendants(row).compactMap { $0 as? AvatarView }.first)
        for _ in 0..<100 where avatar.image == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(avatar.image != nil)
        try capture("feedback-avatar-900", view: content.superview!)
        state.ai?.avatarSources[1] = nil
        window.apply(state)
        #expect(avatar.image == nil && avatar.initial == "迅")
        #expect(avatar.accent?.background == Washi.ai.background)
        try capture("feedback-initial-900", view: content.superview!)
        state.ai?.avatarSources[1] = root.appendingPathComponent("missing.png").path
        window.apply(state)
        try await Task.sleep(for: .milliseconds(50))
        #expect(avatar.image == nil && avatar.initial == "迅")
    }
    private func request(_ number: Int, history: inout AIStreamHistory, root: URL, question: String = "抜けている観点はありますか",
                         voiceStart: Double? = nil, parent: UUID? = nil, name: String = "迅雷",
                         trigger: AIParticipantContext.Trigger? = nil) throws -> AIRequest {
        let snapshot = try history.prepare(lines: ["[14:05:20] 田中: 社内で体験会を開きます。", "[14:05:30] 松村: 抜けている観点はありますか。"], outputDirectory: root)
        let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: name, cliPath: root.appendingPathComponent("helper").path,
            sessionPath: root.appendingPathComponent(".kikigaki-context/\(snapshot.meetingID.uuidString)/ai/sessions/1.json").path, requestToken: UUID().uuidString,
            question: question, capturedAt: started.addingTimeInterval(Double(320 + number * 5)), audioCutoffSeconds: 330,
            inReplyToRequestID: parent, inReplyToEventID: parent.map { "\($0.uuidString)/result" }, trigger: trigger)
        return try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant), number: number,
            voiceQuestion: "うんうん、悪くはないかな。ありがとう。", snapshot: snapshot, voiceUtteranceStart: voiceStart)
    }

    @Test func 宛名と親番号で送信と返事を人の発話と同じ行として並べる() throws {
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
        // 問い欄からの送信は人側の行。「手入力」は会話へ残る投稿の名前なので流用しない。
        let sends = window.transcriptDocument.rows.compactMap { $0 as? AITypedSendRow }
        #expect(sends.count == 2)
        #expect(sends.allSatisfy { $0.displayName == "AIへ送信" && $0.addressText == "迅雷へ" })
        #expect(sends[1].noteText.hasPrefix("#1への返答 · "))
        #expect(sends.allSatisfy { $0.noteText.contains("発言") })
        #expect(!descendants(content).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "手入力" })
        let replies = window.transcriptDocument.rows.compactMap { $0 as? AIReplyRow }
        #expect(replies.map(\.item.kind) == [.reply(.needsInput), .reply(.answered)])
        // 展開が既定なので、返事本文は開かずに見える。
        #expect(replies.allSatisfy { row in descendants(row).compactMap { $0 as? MarkdownBodyView }.contains { !$0.isHidden } })
        // 送信の行の直下に返事が来るので、同じ文を2回出さないため引用は落とす。
        #expect(replies.allSatisfy { $0.quoteButton.isHidden })
        try capture("timeline-wording", view: content.superview!)
        let sheet = AIQuestionSheet(participant: "迅雷", parentNumber: nil, draft: "次の案内も整えてください", voice: "", range: "直近1発言", tentative: false, canSubmit: true)
        #expect(descendants(sheet.window.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "迅雷へ" })
    }

    @Test func 展開既定のまま可視化で既読にし件数と行の同一性を保つ() throws {
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
        window.aiRead.isActive = { true }
        window.window!.setFrameAutosaveName("")
        window.window!.setFrame(NSRect(x: 20000, y: 20000, width: 680, height: 900), display: false)
        let content = window.window!.contentView!
        func apply() { state.ai?.conversation = conversation; window.apply(state); content.layoutSubtreeIfNeeded() }
        func replies() -> [AIReplyRow] { window.transcriptDocument.rows.compactMap { $0 as? AIReplyRow } }
        apply()
        #expect(state.ai?.badges == "未読 1 · 確認待ち 1 · 返事待ち 1 · 失敗 1")
        #expect(descendants(content).compactMap { $0 as? AIBadgeButton }.filter { !$0.isHidden }.map(\.title) == ["未読 1", "確認待ち 1", "返事待ち 1", "失敗 1"])
        // 手入力の横スクロール欄を除き、AI本文が独立スクロールを作らないことを確認する。
        #expect(descendants(content).compactMap { $0 as? NSScrollView }.filter { !($0 is TypedEntryField) }.count == 1)
        // 畳む操作と「ペインを開く」は行から消し、接続の操作はフッターへ集める。
        #expect(!descendants(content).compactMap { $0 as? NSButton }.contains { $0.title.hasPrefix("▸") || $0.title.hasPrefix("▾") })
        let pane = try #require(descendants(content).compactMap { $0 as? AIActionButton }.first { $0.title == "ペインを開く" })
        #expect(!pane.isHidden && pane.superview?.superview !== window.transcriptDocument)
        let answer = try #require(replies().first { $0.item.requestID == requests[0].id })
        let confirmation = try #require(replies().first { $0.item.requestID == requests[1].id })
        let waiting = try #require(replies().first { $0.item.requestID == requests[2].id })
        let failed = try #require(replies().first { $0.item.requestID == requests[3].id })
        #expect(answer.accent == Washi.red && answer.pillStyle == .unread)
        #expect(confirmation.accent == Washi.gold && confirmation.pillStyle == .confirmation)
        #expect(waiting.isWaiting && waiting.pillStyle == .waiting && waiting.item.date == nil)
        #expect(failed.isFailure && failed.failureText.hasSuffix("接続先を確認してください") && failed.height(for: 680) == 34)
        #expect(answer.item.date == started.addingTimeInterval(370))
        // 実画面で直した3件の回帰。実物の表題と可視性で見る。
        #expect(answer.statusPill.title == "未読" && answer.statusPill.isEnabled && !answer.statusPill.isHidden)
        #expect(confirmation.statusPill.title == "確認待ち" && !confirmation.statusPill.isEnabled)
        #expect(waiting.statusPill.title == "返事待ち" && !waiting.statusPill.isEnabled)
        #expect(!descendants(content).compactMap { $0 as? AIStatusPill }.contains { $0.title == "Button" })
        #expect(!failed.timeText.isEmpty && failed.statusPill.isHidden)   // 送信前の失敗は未読にならない
        #expect(!waiting.chipVisible && waiting.timeText.isEmpty)
        #expect(answer.chipVisible && answer.chipText == "AI" && !answer.timeText.isEmpty)
        // 返事待ちは末尾。声ではない送信なので細い1行にはしない。
        #expect(window.transcriptDocument.rows.last(where: { $0 is AIReplyRow }) === waiting || waiting.frame.minY > answer.frame.minY)
        try capture("timeline-states", view: content.superview!)
        state.previousAIUnread = 1; apply()
        var previousOpened = false
        window.onShowPreviousAI = { previousOpened = true }
        let previous = try #require(descendants(content).compactMap { $0 as? AIBadgeButton }.first { $0.title == "前の会議に返事あり" })
        previous.performClick(nil); #expect(previousOpened)
        let footer = try #require(descendants(content).compactMap { $0 as? NSTextField }.first { $0.stringValue == "AIへ渡す会話" }?.superview?.superview)
        try capture("timeline-footer", view: footer)
        var readIDs: [UUID] = []
        window.onReadAI = { id in
            readIDs.append(id)
            try! conversation.update(id) { $0.markRead() }
            apply()
        }
        // 可視域へ入っただけでは既読にしない。1秒留まってから既読にする。
        window.scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, answer.frame.minY - 20)))
        content.layoutSubtreeIfNeeded()
        let now = AIReadWatcher.now
        window.aiRead.evaluate(now: now)
        #expect(readIDs.isEmpty)
        window.aiRead.evaluate(now: now + 0.5)
        #expect(readIDs.isEmpty)
        // 途中でウィンドウを見ていない状態を挟んだら、続きではなく0から数え直す。
        window.aiRead.isActive = { false }
        window.aiRead.evaluate(now: now + 0.6)
        window.aiRead.isActive = { true }
        window.aiRead.evaluate(now: now + 0.7)
        window.aiRead.evaluate(now: now + 1.2)
        #expect(readIDs.isEmpty)
        window.aiRead.evaluate(now: now + 1.75)
        // 画面の上から順に既読にする。返事待ちと失敗は既読の対象にしない。
        #expect(readIDs.first == requests[0].id)
        #expect(!readIDs.contains(requests[2].id) && !readIDs.contains(requests[3].id))
        #expect(answer.accent == nil && answer.pillStyle == nil)
        #expect(!state.ai!.badges.contains("未読"))
        let readCount = readIDs.count
        // 既読と改名だけの更新でも同じ行ビューを使い続ける。
        state.names = SpeakerNames([0: "相川", 1: "松村"])
        state.utterances.append(Utterance(speaker: 1, start: 380, end: 385, text: "担当者は明日決めましょう。"))
        apply()
        #expect(replies().contains { $0 === answer } && readIDs.count == readCount)
        var replied: UUID?
        window.onAskAI = { replied = $0 }
        let reply = try #require(descendants(confirmation).compactMap { $0 as? NSButton }.first { $0.title == "返答する" })
        #expect(!reply.isHidden); reply.performClick(nil)
        #expect(replied == requests[1].id)
        // 確認待ちの帯は返答されるまで残す。既読では消さない。
        confirmation.onRead?()
        apply()
        #expect(confirmation.item.needsAnswer && confirmation.accent == Washi.gold)
        #expect(confirmation.pillStyle == .confirmation && !confirmation.item.isUnread)
        var cancelled: UUID?
        window.onCancelAI = { cancelled = $0 }
        let cancel = try #require(descendants(waiting).compactMap { $0 as? NSButton }.first { $0.title == "取消" })
        #expect(!cancel.isHidden); cancel.performClick(nil); #expect(cancelled == requests[2].id)
        let retry = try #require(descendants(failed).compactMap { $0 as? NSButton }.first { $0.title == "再送" })
        #expect(!retry.isHidden)
        let sends = window.transcriptDocument.rows.compactMap { $0 as? AITypedSendRow }
        #expect(sends.count == 4 && sends.allSatisfy { $0.noteText.contains("2発言") })
        state.state = .idle; apply()
        try capture("timeline-idle", view: content.superview!)
    }

    @Test func 声の送信は発話直下の細い1行にしバッジから移動する() throws {
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
        window.aiRead.isActive = { true }
        window.window!.setFrameAutosaveName("")
        window.window!.setFrame(NSRect(x: 20000, y: 20000, width: 680, height: 620), display: false)
        let content = window.window!.contentView!
        window.apply(state); content.layoutSubtreeIfNeeded()
        window.onReadAI = { id in
            try! conversation.update(id) { $0.markRead() }
            state.ai?.conversation = conversation; window.apply(state)
        }
        let rows = window.transcriptDocument.rows
        let send = try #require(rows[1] as? AISendLineRow)
        #expect(rows[0] is TranscriptRow && rows[2] is TranscriptRow)
        // 時刻は人の発話と同じ粒度。秒はtooltipへ。
        let clock = DateFormatter(); clock.locale = Locale(identifier: "en_US_POSIX"); clock.dateFormat = "HH:mm"
        #expect(send.displayText == "└ 迅雷へ送信 · 2発言 · " + clock.string(from: started.addingTimeInterval(343)))
        // 取消の有無で高さが変わらない。結果の到着で行が縮むと末尾の画面が動く。
        #expect(send.height(for: 680) == 26)
        let answer = try #require(rows.compactMap { $0 as? AIReplyRow }.first)
        // 声の送信は発話そのものが送信文なので、返事へ引用を重ねない。
        #expect(answer.item.question.isEmpty && answer.quoteButton.isHidden)
        #expect(answer.chipText == "AI")
        try capture("timeline-voice-anchor", view: content.superview!)
        answer.onRead?(); content.layoutSubtreeIfNeeded()
        // 再分割で元の開始位置が消えても、改名済みの直前の発話へ配置する。
        state.utterances[0] = .init(speaker: 0, start: 315, end: 325, text: "先ほどの案は、うんうん、悪くはないかな。")
        state.names = SpeakerNames([0: "田中"])
        window.apply(state)
        #expect(window.transcriptDocument.rows[1] === send)
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
        let nextAnswer = try #require(window.transcriptDocument.rows.compactMap { $0 as? AIReplyRow }.first { $0.item.rowID == next.id.uuidString + "/reply" })
        #expect(window.scrollView.contentView.bounds.intersects(nextAnswer.frame))
    }

    @Test(arguments: [false, true]) func AIの行追加と返事到着も末尾追従し検索中だけ止める(searching: Bool) throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID(); var history = try AIStreamHistory(meetingID: meeting)
        let first = try request(1, history: &history, root: root)
        var conversation = AIConversation(meetingID: meeting)
        var state = SessionSnapshot(ai: AIViewState(conversation: conversation), state: .recording,
            utterances: (0..<40).map { Utterance(speaker: 0, start: Double($0 * 5), end: Double($0 * 5 + 2), text: "会議の発言 \($0)") },
            timeline: MeetingTimeline(startedAt: started), elapsed: 400, markdownURL: root.appendingPathComponent("meeting.md"))
        let window = TranscriptWindowController(shouldReduceMotion: { true })
        window.window!.setFrameAutosaveName("")
        window.window!.setContentSize(NSSize(width: 900, height: 700))
        let content = window.window!.contentView!
        window.apply(state); content.layoutSubtreeIfNeeded()
        let document = window.transcriptDocument
        document.reflow(anchor: .init(candidates: [], y: 0, atBottom: true))
        if searching { window.showSearch(nil); content.layoutSubtreeIfNeeded() }
        let before = window.scrollView.contentView.bounds.minY
        try conversation.append(first)
        try conversation.update(first.id) { try $0.beginSending(at: started.addingTimeInterval(330)); try $0.submitted() }
        state.ai?.conversation = conversation
        window.apply(state); content.layoutSubtreeIfNeeded()
        #expect(searching ? abs(window.scrollView.contentView.bounds.minY - before) < 1 : document.anchor().atBottom)
        _ = try conversation.receive(AIReceiveEvent(request: first, kind: .answered,
            recordedAt: started.addingTimeInterval(401), body: String(repeating: "長い返事です。\n\n", count: 12)), at: started.addingTimeInterval(402))
        state.ai?.conversation = conversation
        window.apply(state); content.layoutSubtreeIfNeeded()
        #expect(searching ? abs(window.scrollView.contentView.bounds.minY - before) < 1 : document.anchor().atBottom)
        #expect(document.followsBottom == !searching)
        try capture(searching ? "feedback-search-900" : "feedback-follow-900", view: content.superview!)
    }

    @Test func 末尾追従せず上を読んでいる間は到着でスクロールも既読にもしない() throws {
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
        window.aiRead.isActive = { true }
        window.window!.setFrameAutosaveName("")
        let content = window.window!.contentView!
        window.apply(state); content.layoutSubtreeIfNeeded()
        window.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
        let before = window.scrollView.contentView.bounds.minY
        _ = try conversation.receive(AIReceiveEvent(request: first, kind: .needsInput, recordedAt: started.addingTimeInterval(401), body: "社内だけですか？", reason: "clarification"), at: started.addingTimeInterval(402))
        state.ai?.conversation = conversation; window.apply(state); content.layoutSubtreeIfNeeded()
        let row = try #require(window.transcriptDocument.rows.compactMap { $0 as? AIReplyRow }.first)
        #expect(row.accent == Washi.gold && row.pillStyle == .confirmation)
        #expect(abs(window.scrollView.contentView.bounds.minY - before) < 1)
        // 上を読んでいる間は画面に入らないので既読にならない。
        var read: [UUID] = []
        window.onReadAI = { read.append($0) }
        window.scrollView.contentView.scroll(to: .zero); content.layoutSubtreeIfNeeded()
        let now = AIReadWatcher.now
        window.aiRead.evaluate(now: now); window.aiRead.evaluate(now: now + 2)
        #expect(read.isEmpty)
        // 判定は行と可視域の重なり。上端が上へ抜けた長い返事も「読んでいる」と見なす。
        window.scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, row.frame.midY)))
        content.layoutSubtreeIfNeeded()
        #expect(window.scrollView.contentView.bounds.intersects(row.frame))
        window.aiRead.evaluate(now: now + 3); window.aiRead.evaluate(now: now + 5)
        #expect(read == [first.id])
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
        #expect(row.accent == nil && row.noteText.contains("#2で返答"))
        // 返答したあとも本文が問いであることの印は残す。
        #expect(descendants(row).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "?" && !$0.isHidden })
    }

    @Test func 返送された失敗は未読になり印と可視化で既読にできる() throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID(); var history = try AIStreamHistory(meetingID: meeting)
        let request = try request(1, history: &history, root: root, question: "議事録を直して")
        var conversation = AIConversation(meetingID: meeting)
        try conversation.append(request)
        try conversation.update(request.id) { try $0.beginSending(at: started.addingTimeInterval(330)); try $0.submitted() }
        _ = try conversation.receive(AIReceiveEvent(request: request, kind: .failed, recordedAt: started.addingTimeInterval(340),
                                                    body: "一部の更新に失敗しました\n\n- 更新済み: A\n- 未更新: B", reason: "write_failed"),
                                     at: started.addingTimeInterval(341))
        var state = SessionSnapshot(ai: AIViewState(conversation: conversation), state: .recording,
            utterances: [.init(speaker: 0, start: 320, end: 322, text: "議事録の担当を決めましょう。")],
            timeline: .init(startedAt: started), elapsed: 350, markdownURL: root.appendingPathComponent("meeting.md"))
        let window = TranscriptWindowController(shouldReduceMotion: { true })
        window.aiRead.isActive = { true }
        window.window!.setFrameAutosaveName("")
        window.window!.setFrame(NSRect(x: 20000, y: 20000, width: 680, height: 700), display: false)
        let content = window.window!.contentView!
        window.apply(state); content.layoutSubtreeIfNeeded()
        let failed = try #require(window.transcriptDocument.rows.compactMap { $0 as? AIReplyRow }.first)
        // 返送された失敗はCoreが未読にする。印から既読にでき、可視化の対象にもなる。
        #expect(failed.isFailure && failed.item.isUnread && failed.pillStyle == .unread)
        // 送信できなかった失敗とは言い方を分け、本文は画面から全部読める。
        #expect(failed.isReturnedFailure && failed.failureText.hasPrefix("迅雷から失敗の報告"))
        let detail = try #require(descendants(failed).compactMap { $0 as? MarkdownBodyView }.first)
        #expect(!detail.isHidden && detail.string.contains("未更新: B"))
        #expect(failed.height(for: 680) > 34 && detail.frame.maxY <= failed.height(for: 680))
        #expect(!failed.statusPill.isHidden && failed.statusPill.title == "未読" && failed.statusPill.isEnabled)
        #expect(state.ai?.badges.contains("未読 1") == true)
        var resent: UUID?
        window.onResendAI = { resent = $0 }
        let retry = try #require(descendants(failed).compactMap { $0 as? NSButton }.first { $0.title == "再送" })
        retry.performClick(nil)
        // 再送は新規の問いではなく、元requestを渡して依頼を戻す。
        #expect(resent == request.id)
        var read: [UUID] = []
        window.onReadAI = { id in
            read.append(id)
            try! conversation.update(id) { $0.markRead() }
            state.ai?.conversation = conversation; window.apply(state); content.layoutSubtreeIfNeeded()
        }
        let now = AIReadWatcher.now
        window.aiRead.evaluate(now: now); window.aiRead.evaluate(now: now + 1.2)
        #expect(read == [request.id])
        #expect(failed.statusPill.isHidden && state.ai?.badges.contains("未読") != true)
    }

    @Test func 送達不明は考え中を出さず送信の行から取り消せる() throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID(); var history = try AIStreamHistory(meetingID: meeting)
        let voice = try request(1, history: &history, root: root, question: "", voiceStart: 320)
        let typed = try request(2, history: &history, root: root, question: "担当を確定してください")
        var conversation = AIConversation(meetingID: meeting)
        for value in [voice, typed] {
            try conversation.append(value)
            // 送信を試みたまま応答が失われた状態。isAwaitingResult は残る。
            try conversation.update(value.id) { try $0.beginSending(at: started.addingTimeInterval(330)) }
        }
        let state = SessionSnapshot(ai: AIViewState(conversation: conversation), state: .recording,
            utterances: [.init(speaker: 0, start: 320, end: 322, text: "担当を決めましょう。")],
            timeline: .init(startedAt: started), elapsed: 350, markdownURL: root.appendingPathComponent("meeting.md"))
        let window = TranscriptWindowController(shouldReduceMotion: { true })
        window.window!.setFrameAutosaveName("")
        window.window!.setFrame(NSRect(x: 20000, y: 20000, width: 680, height: 700), display: false)
        let content = window.window!.contentView!
        window.apply(state); content.layoutSubtreeIfNeeded()
        // 成否が分からないので「考え中…」は出さない。取消はこの行にしか置けない。
        #expect(window.transcriptDocument.rows.compactMap { $0 as? AIReplyRow }.isEmpty)
        var cancelled: [UUID] = []
        window.onCancelAI = { cancelled.append($0) }
        let line = try #require(window.transcriptDocument.rows.compactMap { $0 as? AISendLineRow }.first)
        let row = try #require(window.transcriptDocument.rows.compactMap { $0 as? AITypedSendRow }.first)
        for view in [line as NSView, row as NSView] {
            let cancel = try #require(descendants(view).compactMap { $0 as? NSButton }.first { $0.title == "取消" })
            #expect(!cancel.isHidden); cancel.performClick(nil)
        }
        #expect(cancelled == [voice.id, typed.id])
        #expect(line.displayText.contains("送達不明") && row.noteText.contains("送達不明"))
        // 取消の有無で行の高さを変えない。結果が届いて取消が消えると末尾の画面が動く。
        let heights = (line.height(for: 680), row.height(for: 680))
        try conversation.update(voice.id) { try $0.submitted() }
        try conversation.update(typed.id) { try $0.submitted() }
        var next = state; next.ai?.conversation = conversation
        window.apply(next); content.layoutSubtreeIfNeeded()
        #expect((line.height(for: 680), row.height(for: 680)) == heights)
        #expect(window.transcriptDocument.rows.compactMap { $0 as? AIReplyRow }.allSatisfy { $0.isWaiting })
    }

    @Test func 引用は押して全文へ伸び待機から返事へ同じビューで変わる() throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID(); var history = try AIStreamHistory(meetingID: meeting)
        let long = "会場の広さと参加者の人数、機材の予備、当日の受付担当、案内文の送付先をまとめて確認してください"
        let request = try request(1, history: &history, root: root, question: long)
        var conversation = AIConversation(meetingID: meeting)
        try conversation.append(request)
        try conversation.update(request.id) { try $0.beginSending(at: started.addingTimeInterval(330)); try $0.submitted() }
        // 送信の行と返事の行の間に発話が入る並びにする。隣接していると引用は落ちる。
        var state = SessionSnapshot(ai: AIViewState(conversation: conversation), state: .recording,
            utterances: [.init(speaker: 0, start: 320, end: 322, text: "確認したいことがあります。"),
                         .init(speaker: 0, start: 340, end: 342, text: "その間に別の話をします。")],
            timeline: .init(startedAt: started), elapsed: 350, markdownURL: root.appendingPathComponent("meeting.md"))
        let window = TranscriptWindowController(shouldReduceMotion: { true })
        window.window!.setFrameAutosaveName("")
        window.window!.setFrame(NSRect(x: 20000, y: 20000, width: 520, height: 700), display: false)
        let content = window.window!.contentView!
        window.apply(state); content.layoutSubtreeIfNeeded()
        let row = try #require(window.transcriptDocument.rows.compactMap { $0 as? AIReplyRow }.first)
        #expect(row.isWaiting && !row.quoteButton.isHidden && row.quoteButton.text == long)
        let collapsed = row.frame.height
        row.quoteButton.performClick(nil); content.layoutSubtreeIfNeeded()
        #expect(row.quoteButton.expanded && row.frame.height > collapsed)
        // 返事が届いても同じビューのまま。引用の開閉も失わない。
        _ = try conversation.receive(AIReceiveEvent(request: request, kind: .answered, recordedAt: started.addingTimeInterval(360),
                                                    body: "確認しました。\n\n- 会場は30名まで\n- 受付は鈴木さん"), at: started.addingTimeInterval(361))
        state.ai?.conversation = conversation; window.apply(state); content.layoutSubtreeIfNeeded()
        let after = try #require(window.transcriptDocument.rows.compactMap { $0 as? AIReplyRow }.first)
        #expect(after === row && !after.isWaiting && after.quoteButton.expanded)
        #expect(descendants(row).compactMap { $0 as? MarkdownBodyView }.contains { !$0.isHidden && $0.string.hasPrefix("確認しました。") })
        #expect(after.chipVisible && !after.timeText.isEmpty)
        row.quoteButton.performClick(nil); content.layoutSubtreeIfNeeded()
        #expect(!row.quoteButton.expanded)
    }

    /// 5状態と混雑した会議を実寸で撮る。fixtureは実際の出力の形に合わせ、
    /// 空行入りのMarkdownと長い返事、自動送信の積み重なりを含める。
    @Test func 通常と混雑した会議の5状態を実寸で撮る() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID(); var history = try AIStreamHistory(meetingID: meeting)
        var conversation = AIConversation(meetingID: meeting)
        var utterances: [Utterance] = []
        var number = 0
        func speak(_ speaker: Int, _ text: String, at start: Double) {
            utterances.append(Utterance(speaker: speaker, start: start, end: start + 4, text: text))
        }
        func ask(question: String, voiceStart: Double?, at seconds: Double, parent: UUID? = nil,
                 trigger: AIParticipantContext.Trigger? = nil, lines: Int) throws -> AIRequest {
            number += 1
            let context = try history.prepare(lines: (0..<lines).map { "[14:0\($0 % 9):00] 佐藤: 会議の発言 \($0)" },
                                              outputDirectory: root)
            let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
                participantName: "迅雷", cliPath: root.appendingPathComponent("helper").path,
                sessionPath: root.appendingPathComponent(".kikigaki-context/\(meeting.uuidString)/ai/sessions/1.json").path,
                requestToken: UUID().uuidString, question: question, capturedAt: started.addingTimeInterval(seconds),
                audioCutoffSeconds: seconds, inReplyToRequestID: parent, inReplyToEventID: parent.map { "\($0.uuidString)/result" },
                trigger: trigger)
            let request = try AIRequest(envelope: AIEnvelope(snapshot: context, participant: participant), number: number,
                voiceQuestion: "この進め方で抜けはありますか。", snapshot: context, voiceUtteranceStart: voiceStart)
            try conversation.append(request)
            return request
        }
        func send(_ request: AIRequest, at seconds: Double) throws {
            try conversation.update(request.id) {
                try $0.beginSending(at: started.addingTimeInterval(seconds)); try $0.submitted()
            }
        }
        func reply(_ request: AIRequest, at seconds: Double, kind: AIReceiveEvent.Kind = .answered,
                   body: String, reason: String? = nil) throws {
            let date = started.addingTimeInterval(seconds)
            _ = try conversation.receive(AIReceiveEvent(request: request, kind: kind, recordedAt: date, body: body, reason: reason), at: date)
        }
        let minutes = """
        議事録を更新しました。変更点は次のとおりです。

        - **決定事項** に「体験会は9月20日」を追記
        - 担当へ佐藤さん(案内)と鈴木さん(会場)を割り当て

        次の論点は会場の広さです。
        """
        speak(0, "説明を十分、体験を二十分に分けますか。", at: 320)
        speak(1, "最後に質問の時間も五分あると安心ですね。", at: 332)
        let auto = try ask(question: "会議の決定事項と担当・期限をMarkdown議事録へ更新してください", voiceStart: nil,
                           at: 342, trigger: .scheduled, lines: 12)
        try send(auto, at: 342); try reply(auto, at: 348, body: minutes)
        speak(0, "AIに聞きたいです。この進め方で抜けはありますか。", at: 380)
        let voice = try ask(question: "", voiceStart: 380, at: 384, lines: 4)
        try send(voice, at: 384)
        try reply(voice, at: 391, body: """
        抜けは二点あります。

        1. 機材トラブル時の代替手順が決まっていません
        2. 参加者への事前案内の締切が決まっていません

        どちらも当日の朝では間に合わない項目です。先に決めておくことをおすすめします。
        """)
        speak(2, "代替手順は当日の朝に確認しましょう。", at: 432)
        let typed = try ask(question: "参加者の人数と会場の広さを確認してください", voiceStart: nil, at: 466, lines: 6)
        try send(typed, at: 466)
        try reply(typed, at: 470, kind: .needsInput, body: "参加者は社内の方だけですか。社外の方も含みますか。人数の見積もりが変わります。", reason: "clarification")
        speak(1, "案内の締切は今週の金曜でどうでしょう。", at: 478)
        let waiting = try ask(question: "締切を議事録へ反映してください", voiceStart: nil, at: 484, lines: 8)
        try send(waiting, at: 484)
        speak(0, "では金曜までに私が案内を用意します。", at: 500)
        let failed = try ask(question: "担当と期限を確定してください", voiceStart: 500, at: 506, lines: 3)
        try conversation.update(failed.id) { try $0.failBeforeSending("接続が切れています") }
        // 4枡目を埋めて、人の色とAIの色が見分けられるかを1枚で確かめる。
        speak(3, "会場の予約はこちらで進めておきます。", at: 512)
        // 送達不明も出して、フッターのピル5種が同時に立つ状態にする。
        let unknown = try ask(question: "会場の予約状況を確認してください", voiceStart: nil, at: 516, lines: 5)
        try conversation.update(unknown.id) { try $0.beginSending(at: started.addingTimeInterval(516)) }

        var state = SessionSnapshot(ai: AIViewState(conversation: conversation, connection: .working), state: .recording,
            utterances: utterances, timeline: MeetingTimeline(startedAt: started),
            names: SpeakerNames([0: "佐藤", 1: "鈴木", 2: "田中", 3: "松村"]), elapsed: 520,
            markdownURL: root.appendingPathComponent("meeting.md"))
        state.handoffPreview = HandoffHistory().preview(utterances: state.utterances, names: state.names, timeline: state.timeline)
        let window = TranscriptWindowController(shouldReduceMotion: { true })
        window.aiRead.isActive = { false }
        window.window!.setFrameAutosaveName("")
        let content = window.window!.contentView!
        func shoot(_ name: String, width: CGFloat) throws {
            window.window!.setFrame(NSRect(x: 20000, y: 20000, width: width, height: 900), display: false)
            window.apply(state); content.layoutSubtreeIfNeeded()
            let chrome = content.bounds.height - window.scrollView.contentSize.height
            let rowsHeight = window.transcriptDocument.rows.reduce(CGFloat(24)) { $0 + $1.frame.height }
            window.window!.setContentSize(NSSize(width: width, height: min(3000, ceil(rowsHeight + chrome))))
            content.layoutSubtreeIfNeeded()
            window.transcriptDocument.reflow(anchor: .init(candidates: [], y: 0, atBottom: false))
            content.layoutSubtreeIfNeeded()
            try capture(name, view: content.superview!)
        }
        try shoot("timeline-normal-600", width: 600)
        // ピル5種が同時に立つ600幅で、右の時間範囲と接していないかを見る。
        #expect(state.ai?.badges == "未読 1 · 確認待ち 1 · 返事待ち 1 · 送達不明 1 · 失敗 1")
        let footer = try #require(descendants(content).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "AIへ渡す会話" }?.superview?.superview)
        try capture("timeline-badges-600", view: footer)
        try shoot("timeline-normal-900", width: 900)
        #expect(window.transcriptDocument.rows.compactMap { $0 as? AIReplyRow }.count == 5)
        // 4枡が埋まった会議。AIの色が4人目の話者と同色に見えないことを実画面で確かめる。
        #expect(Set(utterances.compactMap(\.speaker)) == [0, 1, 2, 3])

        // 混雑: 自動送信が積み重なり、印が何本も並ぶ長い会議。
        for index in 0..<4 {
            let start = Double(540 + index * 60)
            speak(index % 3, "続きの議論をもう少し詰めましょう。 \(index)", at: start)
            let extra = try ask(question: "会議の決定事項と担当・期限をMarkdown議事録へ更新してください", voiceStart: nil,
                                at: start + 20, trigger: .scheduled, lines: 12 + index * 7)
            try send(extra, at: start + 20)
            try reply(extra, at: start + 26, body: "議事録を更新しました。決定事項へ「案内は9月12日(金)まで」を追記し、備考へ機材確認を足しました。")
        }
        state.utterances = utterances
        state.ai?.conversation = conversation
        state.elapsed = 820
        try shoot("timeline-busy-600", width: 600)
        try shoot("timeline-busy-900", width: 900)
        // 声と自動だけが細い1行。問い欄からの送信は文字があるので人側の行になる。
        #expect(window.transcriptDocument.rows.compactMap { $0 as? AISendLineRow }.count == 6)
    }

    @Test func 旧会議も展開既定で印から既読にでき新規送信の操作は出さない() async throws {
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
        let window = AIPastMeetingsWindow(store: store, current: { UUID() })
        window.window!.setFrameAutosaveName("")
        window.window!.setFrame(NSRect(x: 20000, y: 20000, width: 620, height: 700), display: false)
        window.aiRead.isActive = { true }
        window.update()
        let content = window.window!.contentView!; content.layoutSubtreeIfNeeded()
        let answer = try #require(descendants(content).compactMap { $0 as? AIReplyRow }.first)
        #expect(answer.accent == Washi.red && answer.pillStyle == .unread)
        // 発話を持たないので、声でない送信も日時順の人側の行として並ぶ。
        #expect(descendants(content).compactMap { $0 as? AITypedSendRow }.count == 1)
        // 旧会議も可視化で既読になる。印の直呼びではなく本番の配線を通す。
        let now = AIReadWatcher.now
        window.aiRead.evaluate(now: now)
        #expect(record.controller.conversation.questions[0].isUnread)
        window.aiRead.evaluate(now: now + 1.2)
        content.layoutSubtreeIfNeeded()
        #expect(!record.controller.conversation.questions[0].isUnread)
        let after = try #require(descendants(content).compactMap { $0 as? AIReplyRow }.first)
        #expect(after.accent == nil && after.pillStyle == nil)
        window.update()
        let buttons = descendants(content).compactMap { $0 as? NSButton }
        #expect(!buttons.contains { $0.title.hasPrefix("AIへ") && $0.title != "AIへ送信" })
        #expect(buttons.filter { ["取消", "返答する", "再送"].contains($0.title) }.allSatisfy { $0.isHidden })
        #expect(buttons.contains { $0.title == "ペインを開く" && !$0.isHidden })
        #expect(descendants(content).compactMap { $0 as? NSPopUpButton }.first?.titleOfSelectedItem == "old")
        try capture("timeline-previous-meeting", view: content.superview!)
    }
}
