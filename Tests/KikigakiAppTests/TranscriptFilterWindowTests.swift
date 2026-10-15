import AppKit
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import Kikigaki

extension AppKitTests {
@Suite(.timeLimit(.minutes(1))) @MainActor struct TranscriptFilterWindowTests {
    private let started = Date(timeIntervalSince1970: 1_788_759_600)

    private func controller(_ state: SessionSnapshot) -> TranscriptWindowController {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = TranscriptWindowController(shouldReduceMotion: { true })
        controller.window!.setFrameAutosaveName("")
        controller.window!.setFrame(NSRect(x: 20000, y: 20000, width: 680, height: 620), display: false)
        controller.apply(state)
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        return controller
    }

    private func state(_ speakers: [Int?]) -> SessionSnapshot {
        var state = SessionSnapshot(state: .recording,
            utterances: speakers.enumerated().map { index, speaker in
                Utterance(speaker: speaker, start: Double(index) * 6, end: Double(index) * 6 + 5, text: "発言\(index)")
            },
            timeline: MeetingTimeline(startedAt: started), names: SpeakerNames([0: "田中", 1: "佐藤"]))
        state.markdownURL = URL(fileURLWithPath: "/tmp/kikigaki-filter.md")
        return state
    }

    /// 表示中の行を、発言は本文、線は件数の文で並べる。
    private func displayed(_ controller: TranscriptWindowController) -> [String] {
        controller.transcriptDocument.rows.compactMap { row in
            if let gap = row as? TranscriptFilterGapRow { return gap.text }
            if let row = row as? TranscriptRow { return row.utterance?.text }
            if let row = row as? AIReplyRow { return "AI返事#\(row.item.number)" }
            if let row = row as? AISendLineRow { return "AI送信#\(row.item.number)" }
            return nil
        }
    }

    @Test func 選んだ話者の行だけを出し_間の行を件数つきの線へ畳む() {
        let controller = controller(state([1, 0, 1, 1, 0, nil]))
        #expect(controller.filterBar.isHidden)
        controller.setFilter([.speaker(0)])
        #expect(displayed(controller) == ["ほかの発言 1件", "発言1", "ほかの発言 2件", "発言4", "ほかの発言 1件"])
        #expect(!controller.filterBar.isHidden)
        #expect(controller.filterBar.chips.map(\.label.stringValue) == ["田中"])
        #expect(controller.filterButton.toolTip == "話者で絞り込み中")
        // 表示専用。会話の本文そのものは変えない。
        #expect(controller.snapshot.utterances.count == 6)
        let chip = controller.filterBar.chips[0]
        chip.layoutSubtreeIfNeeded()
        #expect(chip.label.frame.width >= ceil(("田中" as NSString).size(withAttributes: [.font: chip.label.font!]).width))
        try? capture("filter-gaps", view: controller.window!.contentView!.superview!)
    }

    @Test func 線を押すとその区間を開き_開いた行を線のあった位置から並べる() throws {
        let controller = controller(state([0, 1, 1, 0]))
        controller.setFilter([.speaker(0)])
        let gap = try #require(controller.transcriptDocument.rows.compactMap { $0 as? TranscriptFilterGapRow }.first)
        let y = gap.frame.minY - controller.scrollView.contentView.bounds.minY
        gap.performClick(nil)
        #expect(displayed(controller) == ["発言0", "発言1", "発言2", "発言3"])
        let opened = try #require(controller.transcriptDocument.rows.compactMap { $0 as? TranscriptRow }.first { $0.utterance?.text == "発言1" })
        #expect(opened.frame.minY - controller.scrollView.contentView.bounds.minY == y)
    }

    @Test func 開いた後に届いた行は新しい線へ畳み_絞り込みを変えると開いた区間を閉じる() throws {
        var state = state([0, 1])
        let controller = controller(state)
        controller.setFilter([.speaker(0)])
        try #require(controller.transcriptDocument.rows.compactMap { $0 as? TranscriptFilterGapRow }.first).performClick(nil)
        state.utterances.append(Utterance(speaker: 1, start: 30, end: 35, text: "発言2"))
        controller.apply(state)
        #expect(displayed(controller) == ["発言0", "発言1", "ほかの発言 1件"])
        controller.setFilter([.speaker(0), .typed])
        #expect(displayed(controller) == ["発言0", "ほかの発言 2件"])
    }

    private func capture(_ name: String, view: NSView) throws {
        guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] else { return }
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
    }

    @Test func 狭い幅では札を折り返し_ヘッダーのボタンを押し出さない() throws {
        var state = state([0, 1, 2, 3, 0, 1])
        state.names = SpeakerNames([0: "田中", 1: "佐藤", 2: "とても長い名前の参加者さん", 3: "鈴木"])
        let controller = controller(state)
        for width in [420, 680] {
            controller.window!.setContentSize(NSSize(width: width, height: 620))
            controller.setFilter([.speaker(0), .speaker(1), .speaker(2), .speaker(3)])
            let content = controller.window!.contentView!
            content.layoutSubtreeIfNeeded()
            let chips = controller.filterBar.chips
            #expect(chips.allSatisfy { $0.frame.maxX <= controller.filterBar.bounds.width - 16 })
            #expect(controller.filterButton.frame.width == 32)
            if width == 420 { #expect(Set(chips.map(\.frame.minY)).count > 1) }
            try capture("filter-\(width)", view: content.superview!)
            controller.setFilter([])
        }
        controller.filterPressed()
        try capture("filter-popover", view: try #require(controller.filterPopover).contentView)
        controller.filterPopover?.close()
    }

    @Test func 札の外すボタンで外し_最後の1人を外すと絞り込みが解ける() throws {
        let controller = controller(state([0, 1, 2]))
        controller.setFilter([.speaker(0), .speaker(1)])
        #expect(controller.filterBar.chips.map(\.label.stringValue) == ["田中", "佐藤"])
        controller.filterBar.chips[0].remove.performClick(nil)
        #expect(controller.filterSelection == [.speaker(1)])
        #expect(displayed(controller) == ["ほかの発言 1件", "発言1", "ほかの発言 1件"])
        controller.filterBar.chips[0].remove.performClick(nil)
        #expect(controller.filterSelection.isEmpty)
        #expect(controller.filterBar.isHidden)
        #expect(displayed(controller) == ["発言0", "発言1", "発言2"])
    }

    @Test func 絞り込みのボタンから相手を複数選べる() throws {
        var state = state([0, 1])
        state.utterances.append(try Utterance(typedText: "メモ", at: 20, postedAt: started.addingTimeInterval(20)))
        let controller = controller(state)
        controller.filterPressed()
        let popover = try #require(controller.filterPopover)
        #expect(popover.checkboxes.map(\.title) == ["田中", "佐藤", "手入力"])
        // 行と同じアバターを添える。
        #expect(popover.checkboxes[0].avatar.slot == 0 && popover.checkboxes[0].avatar.initial == "田")
        #expect(popover.checkboxes[2].avatar.typed)
        popover.checkboxes[2].button.performClick(nil)
        // 名前を押しても標準のチェックボックスの文字と同じく切り替わる。
        popover.checkboxes[1].perform(Selector(("clicked")))
        #expect(controller.filterSelection == [.typed, .speaker(1)])
        #expect(displayed(controller) == ["ほかの発言 1件", "発言1", "メモ"])
        popover.checkboxes[1].button.performClick(nil)
        #expect(controller.filterSelection == [.typed])
        popover.close()
    }

    @Test func 会議が変わると解除から始める() {
        var state = state([0, 1])
        let controller = controller(state)
        controller.setFilter([.speaker(1)])
        state.timeline = MeetingTimeline(startedAt: started.addingTimeInterval(3600))
        controller.apply(state)
        #expect(controller.filterSelection.isEmpty)
        #expect(controller.filterBar.isHidden)
        #expect(displayed(controller) == ["発言0", "発言1"])
    }

    @Test func 聞き取り中の行は絞り込み中は出さない() {
        var state = state([0])
        state.tentativeText = "聞き取り中の文"
        let controller = controller(state)
        #expect(controller.transcriptDocument.rows.contains { ($0 as? TranscriptRow)?.tentative == true })
        controller.setFilter([.speaker(0)])
        #expect(!controller.transcriptDocument.rows.contains { ($0 as? TranscriptRow)?.tentative == true })
    }

    @Test func 検索で畳んだ行の一致へ移るとその区間を開く() {
        var state = state([0, 1, 0])
        state.utterances[1].text = "予算の話"
        let controller = controller(state)
        controller.setFilter([.speaker(0)])
        controller.showSearch(nil)
        controller.searchField.stringValue = "予算"
        controller.refreshSearch(reset: true, reveal: true)
        #expect(displayed(controller) == ["発言0", "予算の話", "発言2"])
        controller.closeSearch(nil)
    }

    @Test func 畳んだ行に付く範囲の印は出さない() {
        let controller = controller(state([0, 1, 0]))
        let rows = controller.transcriptDocument.rows.compactMap { $0 as? TranscriptRow }
        controller.setFilter([.speaker(0)])
        controller.transcriptDocument.setRangeBoundaries(AIRangeBoundaries(answered: 1, accepted: 2), utteranceRows: rows)
        #expect(controller.transcriptDocument.rangeMarkers.map(\.view.answered) == [false])
    }

    @Test func AIの宛先を選ぶとその宛先への送信と返事を出す() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID(); var history = try AIStreamHistory(meetingID: meeting)
        let snapshot = try history.prepare(lines: ["[14:05:20] 田中: 社内で体験会を開きます。"], outputDirectory: root)
        let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: "迅雷", cliPath: root.appendingPathComponent("helper").path,
            sessionPath: root.appendingPathComponent(".kikigaki-context/\(snapshot.meetingID.uuidString)/"
                + AIEnvelope.sessionPath(slot: 1, generation: 1)).path, requestToken: UUID().uuidString,
            question: "抜けている観点はありますか", capturedAt: started.addingTimeInterval(8), audioCutoffSeconds: 8,
            profile: "宛先", profileSlot: 1)
        let request = try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant), number: 1,
            voiceQuestion: "ありがとう。", snapshot: snapshot)
        var conversation = AIConversation(meetingID: meeting)
        try conversation.append(request)
        try conversation.update(request.id) { try $0.beginSending(at: started.addingTimeInterval(8)); try $0.submitted() }
        _ = try conversation.receive(AIReceiveEvent(request: request, kind: .answered, recordedAt: started.addingTimeInterval(9),
            body: "確認しました。"), at: started.addingTimeInterval(9))
        var state = state([0, 1, 0])
        state.ai = AIViewState(conversation: conversation)
        state.elapsed = 20
        let controller = controller(state)
        controller.filterPressed()
        let popover = try #require(controller.filterPopover)
        #expect(popover.checkboxes.map(\.title) == ["田中", "佐藤", "迅雷(AI)"])
        #expect(popover.checkboxes[2].avatar.accent != nil && popover.checkboxes[2].avatar.initial == "迅")
        popover.close()
        controller.setFilter([.ai("迅雷")])
        let shown = displayed(controller)
        #expect(shown.contains("AI返事#1"))
        #expect(!shown.contains("発言0") && !shown.contains("発言1") && !shown.contains("発言2"))
        #expect(controller.filterBar.chips.map(\.label.stringValue) == ["迅雷"])
        #expect(controller.filterBar.chips[0].avatar.accent != nil)
    }
}
}
