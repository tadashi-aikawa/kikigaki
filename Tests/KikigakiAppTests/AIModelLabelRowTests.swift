import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

/// AIの返事行の名前行へ出すモデル表記。並びは 名前 → AIチップ → モデル表記 → 時刻 → 所要。
@Suite @MainActor struct AIModelLabelRowTests {
    private let started = Date(timeIntervalSince1970: 1_788_759_600)
    private let label = AIModelLabel(model: "gpt-6-astra", effort: "high", directory: "minutes")

    private func request(_ number: Int, slot: Int, history: inout AIStreamHistory, root: URL) throws -> AIRequest {
        let snapshot = try history.prepare(lines: ["[14:05:20] 田中: 社内で体験会を開きます。"], outputDirectory: root)
        let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: "迅雷", cliPath: root.appendingPathComponent("helper").path,
            sessionPath: root.appendingPathComponent(".kikigaki-context/\(snapshot.meetingID.uuidString)/"
                + AIEnvelope.sessionPath(slot: slot, generation: 1)).path, requestToken: UUID().uuidString,
            question: "抜けている観点はありますか", capturedAt: started.addingTimeInterval(320), audioCutoffSeconds: 330,
            profile: "宛先\(slot)", profileSlot: slot)
        return try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant), number: number,
            voiceQuestion: "ありがとう。", snapshot: snapshot)
    }

    /// 回答済みの返事行を1つ作る。`answered` がfalseなら返事待ちのまま。
    private func row(root: URL, answered: Bool = true, labels: [Int: AIModelLabel]? = nil,
                     width: CGFloat = 600) throws -> AIReplyRow {
        let meeting = UUID(); var history = try AIStreamHistory(meetingID: meeting)
        let value = try request(1, slot: 1, history: &history, root: root)
        var conversation = AIConversation(meetingID: meeting)
        try conversation.append(value)
        try conversation.update(value.id) { try $0.beginSending(at: started); try $0.submitted() }
        if answered {
            try conversation.receive(AIReceiveEvent(request: value, kind: .answered, recordedAt: started, body: "確認しました。"),
                                     at: started.addingTimeInterval(95))
        }
        var state = AIViewState(conversation: conversation)
        state.modelLabels = labels ?? [1: label]
        let item = try #require(AITimeline.items(conversation: conversation, utterances: [],
                                                 timeline: .init(startedAt: started)).first { !$0.isSend })
        let row = AIReplyRow(item: item, state: state)
        row.frame = NSRect(x: 0, y: 0, width: width, height: row.height(for: width))
        row.layoutSubtreeIfNeeded()
        return row
    }

    private func labels(_ row: AIReplyRow) -> [NSTextField] { row.subviews.compactMap { $0 as? NSTextField } }
    private func field(_ row: AIReplyRow, _ text: String) throws -> NSTextField {
        try #require(labels(row).first { !$0.isHidden && $0.stringValue == text })
    }

    @Test func 名前とチップの右かつ時刻の左へ薄墨11ptで出す() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let row = try row(root: root)
        #expect(row.modelText == "gpt-6-astra · high · minutes")
        let model = try field(row, row.modelText)
        let name = try field(row, "迅雷")
        let time = try field(row, row.timeText)
        let duration = try field(row, row.durationText)
        #expect(model.frame.minX > name.frame.maxX)
        #expect(model.frame.maxX <= time.frame.minX)
        #expect(time.frame.maxX <= duration.frame.minX)
        #expect(model.font?.pointSize == 11 && model.textColor == Washi.muted)
        // 幅で落とした段に関係なく、全部入りはtooltipと読み上げから読める。
        #expect(model.toolTip == "gpt-6-astra · high · minutes")
        #expect((row.accessibilityLabel() ?? "").contains("gpt-6-astra · high · minutes"))
    }

    @Test func 返事待ちでも宛先のモデルを出す() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let row = try row(root: root, answered: false)
        #expect(row.isWaiting && row.timeText.isEmpty)
        #expect(row.modelText == "gpt-6-astra · high · minutes")
        let model = try field(row, row.modelText)
        let name = try field(row, "迅雷")
        #expect(model.frame.minX > name.frame.maxX)
    }

    @Test func プロファイルに値が無ければ表記ごと出さない() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let missing = try row(root: root, labels: [:])
        #expect(missing.modelText.isEmpty)
        // 枠違いの表記は引かない。会議で固定した自分の枠のものだけを読む。
        let otherSlot = try row(root: root, labels: [2: label])
        #expect(otherSlot.modelText.isEmpty)
    }

    /// 幅を削ると 末端ディレクトリ → エフォート の順に落ち、時刻と所要は最後まで残る。
    @Test func 幅が足りなければ末端ディレクトリからエフォートの順に落とす() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let row = try row(root: root)
        var seen: [String] = []
        for width in stride(from: CGFloat(600), through: 200, by: -1) {
            row.frame = NSRect(x: 0, y: 0, width: width, height: row.height(for: width))
            row.layoutSubtreeIfNeeded()
            if seen.last != row.modelText { seen.append(row.modelText) }
            // 時刻と所要を押し出さない。折り返しもしない。
            let time = try field(row, row.timeText)
            let duration = try field(row, row.durationText)
            #expect(time.frame.maxX <= duration.frame.minX)
            // 420ptが利用者に出せる下限。それより狭い枠では時刻の幅そのものが入らない。
            if width >= 420 { #expect(duration.frame.maxX <= width - 20) }
            if !row.modelText.isEmpty {
                let model = try field(row, row.modelText)
                #expect(model.frame.maxX <= time.frame.minX)
                #expect(model.frame.minY == time.frame.minY + 1)
            }
        }
        // 落ちる順は末端ディレクトリ→エフォート→表記ごと。飛ばしも戻りもしない。
        #expect(seen == label.stages + [""])
    }

    /// 失敗の帯にも宛先のモデルを出す。ただし見出しと理由の場所を先に残す。
    @Test func 失敗の帯では見出しと理由の右へ出す() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID(); var history = try AIStreamHistory(meetingID: meeting)
        let value = try request(1, slot: 1, history: &history, root: root)
        var conversation = AIConversation(meetingID: meeting)
        try conversation.append(value)
        try conversation.update(value.id) { try $0.beginSending(at: started); try $0.submitted() }
        try conversation.receive(AIReceiveEvent(request: value, kind: .failed, recordedAt: started,
            body: "更新済み: A / 未更新: B", reason: "write denied"), at: started.addingTimeInterval(95))
        var state = AIViewState(conversation: conversation)
        state.modelLabels = [1: label]
        let item = try #require(AITimeline.items(conversation: conversation, utterances: [],
                                                 timeline: .init(startedAt: started)).first { !$0.isSend })
        let row = AIReplyRow(item: item, state: state)
        row.frame = NSRect(x: 0, y: 0, width: 600, height: row.height(for: 600))
        row.layoutSubtreeIfNeeded()
        #expect(row.isFailure && row.modelText == "gpt-6-astra · high · minutes")
        let model = try field(row, row.modelText)
        let failure = try field(row, row.failureText)
        let time = try field(row, row.timeText)
        #expect(failure.frame.maxX <= model.frame.minX && model.frame.maxX <= time.frame.minX)
        // 理由を読めることが先。見出しと理由の場所は表記に譲らない。
        #expect(failure.frame.width >= 180)
    }

    /// 3宛先が同時に並ぶ混雑した会議を420ptで開いても、名前行は1行に収まる。
    @Test func 三宛先の混雑画面を420ptで開いても名前行が重ならない() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        for slot in 1...3 {
            var history = try AIStreamHistory(meetingID: meeting)
            let value = try request(slot, slot: slot, history: &history, root: root)
            try conversation.append(value)
            try conversation.update(value.id) { try $0.beginSending(at: started); try $0.submitted() }
            try conversation.receive(AIReceiveEvent(request: value, kind: .answered, recordedAt: started, body: "確認しました。"),
                                     at: started.addingTimeInterval(95))
        }
        var state = AIViewState(conversation: conversation)
        state.modelLabels = [1: label, 2: AIModelLabel(model: "claude", effort: "max", directory: "owlery"),
                             3: AIModelLabel(model: "gpt-6-astra", directory: "kikigaki")]
        let items = AITimeline.items(conversation: conversation, utterances: [], timeline: .init(startedAt: started))
            .filter { !$0.isSend }
        #expect(items.count == 3)
        for item in items {
            let row = AIReplyRow(item: item, state: state)
            row.frame = NSRect(x: 0, y: 0, width: 420, height: row.height(for: 420))
            row.layoutSubtreeIfNeeded()
            let time = try field(row, row.timeText)
            #expect(!row.timeText.isEmpty && !row.durationText.isEmpty)
            guard !row.modelText.isEmpty else { continue }
            let model = try field(row, row.modelText)
            // 名前行は1行。段を増やさず、時刻の手前で必ず終わる。
            #expect(model.frame.maxX <= time.frame.minX && model.frame.height == 16)
            #expect(label.stages.contains(row.modelText) || row.modelText == state.modelLabels[2]?.text
                    || row.modelText == state.modelLabels[3]?.text)
        }
    }
}
