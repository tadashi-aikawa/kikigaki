import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

/// 複数プロファイルの見た目を撮る。`KIKIGAKI_UI_CAPTURE` を渡したときだけ動く。
@Suite @MainActor struct AIProfileReviewTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func capture(_ name: String, _ view: NSView, to output: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
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
        guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] else { return }
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
            let titles = descendants(content).compactMap { $0 as? NSButton }.map(\.title)
            // 宛名で見分けられること。番号は会議内の通しのまま。
            #expect(titles.contains { $0.contains("#1 迅雷へ") } && titles.contains { $0.contains("#2 ネオへ") })
            #expect(titles.contains { $0.contains("#4 ネオから") || $0.contains("#4 ネオ") })
            try capture("profiles-crowded-\(width)", content.superview!, to: output)
        }

        // 「議事録」には準備済みセッションがある想定。
        let items: [AIDestinationPicker.Item] = [.init(slot: 1, name: "議事録", prepared: "13:05"),
                                                 .init(slot: 2, name: "相談", prepared: nil)]
        let ask = AIQuestionSheet(participant: "迅雷", parentNumber: nil, draft: "この段取りで抜けはありますか",
            voice: "", range: "対象: 3〜7行(14:05:20〜14:06:16) · 送信時に確定", tentative: false, canSubmit: true)
        ask.updateDestinations(items, selected: 1, participant: "迅雷")
        try capture("profiles-sheet-ask", ask.window.contentView!, to: output)

        // 返事待ちで送信できない状態。無効の部品は面を足さず色を抜く。
        let busy = AIQuestionSheet(participant: "ネオ", parentNumber: nil, draft: "", voice: "空欄なら声の末尾を送ります",
            range: "追加の確定行なし · 送信時点で範囲を確定", tentative: false, canSubmit: false)
        busy.updateDestinations(items, selected: 2, participant: "ネオ")
        try capture("profiles-sheet-busy", busy.window.contentView!, to: output)

        let schedule = AIScheduleSheet(prompt: "会議の決定事項と担当・期限をMarkdown議事録へ更新してください",
            minutes: 3, workAllowed: true, sendFinal: true, participant: "迅雷")
        schedule.updateDestinations(items, selected: 1, participant: "迅雷")
        try capture("profiles-sheet-schedule", schedule.window.contentView!, to: output)

        // プロファイルが1つで準備済みも無い会議では、宛先の行そのものを出さない。
        let single = AIQuestionSheet(participant: "迅雷", parentNumber: nil, draft: "", voice: "",
            range: "追加の確定行なし", tentative: false, canSubmit: true)
        single.updateDestinations([.init(slot: 1, name: "迅雷", prepared: nil)], selected: 1, participant: "迅雷")
        try capture("profiles-sheet-single", single.window.contentView!, to: output)
    }
}
