import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

/// 複数プロファイルの行とシートを検証する。検証は常に動き、
/// 画像の書き出しだけ `KIKIGAKI_UI_CAPTURE` を渡したときに行う。
@Suite @MainActor struct AIProfileReviewTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func capture(_ name: String, _ view: NSView, to output: String) throws {
        let window = view.window
        let wasVisible = window?.isVisible == true
        if !wasVisible { window?.setFrameOrigin(NSPoint(x: 20000, y: 20000)); window?.orderFront(nil) }
        defer { if !wasVisible { window?.orderOut(nil) } }
        view.layoutSubtreeIfNeeded()
        let rendered = window?.contentView?.superview ?? view
        rendered.layoutSubtreeIfNeeded(); rendered.displayIfNeeded()
        let bitmap = try #require(rendered.bitmapImageRepForCachingDisplay(in: rendered.bounds))
        rendered.cacheDisplay(in: rendered.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
    }
    private let started = Date(timeIntervalSince1970: 1_788_759_600)

    private func request(_ number: Int, slot: Int, profile: String, participant: String,
                         history: inout AIStreamHistory, root: URL, question: String,
                         trigger: AIParticipantContext.Trigger? = nil) throws -> AIRequest {
        let snapshot = try history.prepare(lines: [
            "[14:05:20] 田中: 社内で体験会を開きます。",
            "[14:05:30] 松村: 抜けている観点はありますか。",
            "[14:06:10] 田中: 会場は本社の大会議室にしましょう。",
        ], outputDirectory: root)
        let session = root.appendingPathComponent(".kikigaki-context/\(snapshot.meetingID.uuidString)/"
            + AIEnvelope.sessionPath(slot: slot, generation: 1)).path
        let participantContext = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: participant, cliPath: root.appendingPathComponent("helper").path,
            sessionPath: session, requestToken: UUID().uuidString,
            question: question, capturedAt: started.addingTimeInterval(Double(320 + number * 12)), audioCutoffSeconds: 330,
            trigger: trigger, profile: profile, profileSlot: slot)
        return try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participantContext), number: number,
            voiceQuestion: "うんうん、悪くはないかな。", snapshot: snapshot)
    }

    /// 印が何本も積んだ混雑した会議。2つのプロファイルの宛名が混ざる。
    private func crowded(root: URL) throws -> AIConversation {
        let meeting = UUID()
        var minutes = try AIStreamHistory(meetingID: meeting)
        var advice = try AIStreamHistory(meetingID: meeting)
        var conversation = AIConversation(meetingID: meeting)
        func send(_ request: AIRequest, at offset: Double) throws {
            try conversation.append(request)
            try conversation.update(request.id) { try $0.beginSending(at: started.addingTimeInterval(offset)); try $0.submitted() }
        }
        let auto1 = try request(1, slot: 1, profile: "議事録", participant: "迅雷", history: &minutes, root: root,
            question: "会議の決定事項と担当・期限をMarkdown議事録へ更新してください", trigger: .scheduled)
        try send(auto1, at: 330)
        _ = try conversation.receive(AIReceiveEvent(request: auto1, kind: .answered, recordedAt: started.addingTimeInterval(340),
            body: "決定事項を3件追記しました。"), at: started.addingTimeInterval(340))

        let ask = try request(2, slot: 2, profile: "相談", participant: "ネオ", history: &advice, root: root,
            question: "この進め方で抜けている観点はありますか")
        try send(ask, at: 352)
        _ = try conversation.receive(AIReceiveEvent(request: ask, kind: .answered, recordedAt: started.addingTimeInterval(360),
            body: "会場の収容人数と配信の可否が未確認です。"), at: started.addingTimeInterval(360))

        let auto2 = try request(3, slot: 1, profile: "議事録", participant: "迅雷", history: &minutes, root: root,
            question: "会議の決定事項と担当・期限をMarkdown議事録へ更新してください", trigger: .scheduled)
        try send(auto2, at: 364)
        _ = try conversation.receive(AIReceiveEvent(request: auto2, kind: .needsInput, recordedAt: started.addingTimeInterval(370),
            body: "会場名は「本社大会議室」で確定でしょうか？", reason: "clarification"), at: started.addingTimeInterval(370))

        let ask2 = try request(4, slot: 2, profile: "相談", participant: "ネオ", history: &advice, root: root,
            question: "配信の準備にどれくらいかかりますか")
        try send(ask2, at: 376)
        _ = try conversation.receive(AIReceiveEvent(request: ask2, kind: .failed, recordedAt: started.addingTimeInterval(380),
            body: "接続先の権限が不足しています。", reason: "permission"), at: started.addingTimeInterval(380))

        let waiting = try request(5, slot: 1, profile: "議事録", participant: "迅雷", history: &minutes, root: root,
            question: "決まった会場をそのまま反映してください")
        try send(waiting, at: 388)
        return conversation
    }

    @Test func 混雑した会議とシートを幅ごとに撮る() throws {
        // 撮影は環境変数がある時だけだが、検証は常に走らせる。
        let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"]
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let conversation = try crowded(root: root)
        let profiles = [(slot: 1, name: "議事録"), (slot: 2, name: "相談")]
        var ai = AIViewState(conversation: conversation, participant: "迅雷", connection: .idle)
        ai.profiles = profiles; ai.selectedSlot = 1
        var state = SessionSnapshot(ai: ai, state: .recording, utterances: [
            .init(speaker: 0, start: 320, end: 324, text: "社内で体験会を開きます。"),
            .init(speaker: 1, start: 330, end: 335, text: "抜けている観点はありますか。"),
            .init(speaker: 0, start: 370, end: 376, text: "会場は本社の大会議室にしましょう。"),
        ], timeline: .init(startedAt: started), elapsed: 400, markdownURL: root.appendingPathComponent("meeting.md"))
        state.handoffPreview = HandoffHistory().preview(utterances: state.utterances, names: state.names, timeline: state.timeline)
        state.aiSchedule = AIScheduleViewState(schedule: nil, warning: nil, destination: "議事録")

        for width in [600, 900] {
            let window = TranscriptWindowController(shouldReduceMotion: { true })
            window.window!.setFrameAutosaveName("")
            window.window!.setFrame(NSRect(x: 20000, y: 20000, width: CGFloat(width), height: 700), display: false)
            window.apply(state)
            let content = window.window!.contentView!
            content.layoutSubtreeIfNeeded()
            // 宛名で見分けられること。行はrequestごとの宛名を出し、選択中の宛先に依存しない。
            let sends = window.transcriptDocument.rows.compactMap { $0 as? AISendLineRow }
            let typed = window.transcriptDocument.rows.compactMap { $0 as? AITypedSendRow }
            let replies = window.transcriptDocument.rows.compactMap { $0 as? AIReplyRow }
            #expect(sends.contains { $0.displayText.hasPrefix("└ 迅雷へ") } || typed.contains { $0.addressText == "迅雷へ" })
            #expect(sends.contains { $0.displayText.hasPrefix("└ ネオへ") } || typed.contains { $0.addressText == "ネオへ" })
            #expect(Set(replies.map(\.item.participantName)) == ["迅雷", "ネオ"])
            let waiting = try #require(replies.first { $0.isWaiting })
            #expect(waiting.pillStyle == nil && waiting.statusPill.isHidden)
            let cancel = try #require(descendants(waiting).compactMap { $0 as? AIActionButton }.first { $0.title == "取消" })
            #expect(!cancel.isHidden && cancel.isEnabled)
            var cancelled = false; waiting.onCancel = { cancelled = true }
            cancel.performClick(nil); #expect(cancelled)
            // 送信の行と返事の行は同じrequestを指す。
            let requests = Set(conversation.questions.map(\.request.id))
            let rows = window.transcriptDocument.rows.compactMap { $0 as? (any AITimelineRowView) }
            #expect(!rows.isEmpty && rows.allSatisfy { requests.contains($0.item.requestID) })
            if let output { try capture("profiles-crowded-\(width)", content.superview!, to: output) }
            if width == 600, let output {
                let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
                let targets = descendants(content).compactMap { $0 as? HoverButton }
                    .filter { $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor }
                for (index, button) in targets.enumerated() {
                    button.mouseEntered(with: event)
                    try capture("hover-\(index)-\(type(of: button))-600", content, to: output)
                    button.mouseExited(with: event)
                }
            }
        }

        // 「議事録」には準備済みセッションがある想定。
        let items: [AIDestinationPicker.Item] = [
            .init(slot: 1, name: "議事録",
                  prepared: [.init(id: UUID(), label: "Kikigaki 議事録抽出 · 13:05起動")]),
            .init(slot: 2, name: "相談")]
        let ask = AIQuestionSheet(participant: "迅雷", parentNumber: nil, draft: "この段取りで抜けはありますか",
            voice: "", range: "対象: 3〜7行(14:05:20〜14:06:16) · 送信時に確定", tentative: false, canSubmit: true)
        ask.updateDestinations(items, selected: 1, participant: "迅雷")
        if let output { try capture("profiles-sheet-ask", ask.window.contentView!, to: output) }

        // 返事待ちで送信できない状態。無効の部品は面を足さず色を抜く。
        let busy = AIQuestionSheet(participant: "ネオ", parentNumber: nil, draft: "", voice: "空欄なら声の末尾を送ります",
            range: "追加の確定行なし · 送信時点で範囲を確定", tentative: false, canSubmit: false)
        busy.updateDestinations(items, selected: 2, participant: "ネオ")
        if let output { try capture("profiles-sheet-busy", busy.window.contentView!, to: output) }

        // 失敗の再送は宛先を固定する。選択欄を出さず、選び直しても取消の宛先が動かない。
        let resend = AIQuestionSheet(participant: "ネオ", parentNumber: nil, draft: "担当と期限を確定してください",
            voice: "", range: "対象: 3発言", tentative: false, canSubmit: true, fixedSlot: 2)
        resend.updateDestinations(items, selected: 1, participant: "議事録")
        #expect(resend.owningSlot == 2)
        #expect(!descendants(resend.window.contentView!).contains { $0 is AIDestinationPicker && !$0.isHidden })
        let resendTitle = try #require(descendants(resend.window.contentView!).compactMap { $0 as? NSTextField }.first)
        #expect(resendTitle.stringValue == "ネオへ")
        let resendSend = try #require(descendants(resend.window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "送信" })
        resendSend.performClick(nil)
        #expect(resend.owningSlot == 2)   // 送信後も取消の宛先は元のまま
        if let output { try capture("profiles-sheet-resend", resend.window.contentView!, to: output) }

        let schedule = AIScheduleSheet(prompt: "会議の決定事項と担当・期限をMarkdown議事録へ更新してください",
            minutes: 3, workAllowed: true, sendFinal: true, participant: "迅雷")
        schedule.updateDestinations(items, selected: 1, participant: "迅雷")
        if let output { try capture("profiles-sheet-schedule", schedule.window.contentView!, to: output) }

        // 送信を始めた後。宛先は選び直せない。無効の部品は面を足さず色を抜く。
        let locked = AIQuestionSheet(participant: "議事録", parentNumber: nil, draft: "この段取りで抜けはありますか",
            voice: "", range: "対象: 3〜7行(14:05:20〜14:06:16) · 送信時に確定", tentative: false, canSubmit: true)
        locked.updateDestinations(items, selected: 1, participant: "議事録")
        let send = try #require(descendants(locked.window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "送信" })
        send.performClick(nil)
        locked.update(progress: "AIの入力準備を確認中。初回設定はherdrで確認してください", canSubmit: false)
        if let output { try capture("profiles-sheet-sending", locked.window.contentView!, to: output) }

        // プロファイルが1つで準備済みも無い会議では、宛先の行そのものを出さない。
        let single = AIQuestionSheet(participant: "迅雷", parentNumber: nil, draft: "", voice: "",
            range: "追加の確定行なし", tentative: false, canSubmit: true)
        single.updateDestinations([.init(slot: 1, name: "迅雷")], selected: 1, participant: "迅雷")
        if let output { try capture("profiles-sheet-single", single.window.contentView!, to: output) }
    }
}
