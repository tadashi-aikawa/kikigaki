import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

/// AIの返事行のモデル表記。名前行には出さず、本文の下のフッターへ2つの塊で置く。
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

    @Test func 名前行から外して本文の下へ2つの塊で置く() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let row = try row(root: root)
        #expect(row.modelText == "gpt-6-astra · high · minutes")
        // 名前行には出さない。名前・時刻・所要のどれもモデル名を含まない。
        #expect(!labels(row).contains { $0.stringValue.contains("gpt-6-astra") })
        let footer = row.modelFooter
        let name = try field(row, "迅雷")
        #expect(!footer.isHidden && footer.frame.minY > name.frame.maxY)
        // 本文と同じ左端に揃え、1行ぶんの高さだけ使う。折り返さない。
        #expect(footer.frame.minX == AIRowMetrics.bodyX && footer.frame.height == AIModelFooter.height)
        let stage = try #require(footer.stage)
        #expect(stage.model == "gpt-6-astra · high" && stage.directory == "minutes")
        // 全部入りは名前とフッターのtooltip、読み上げから読める。
        #expect(name.toolTip == "gpt-6-astra · high · minutes" && footer.toolTip == "gpt-6-astra · high · minutes")
        #expect((row.accessibilityLabel() ?? "").contains("gpt-6-astra · high · minutes"))
    }

    /// 2つの塊はそれぞれアイコンを持ち、間を12pt空ける。中黒1つぶんより広い。
    @Test func 塊ごとにアイコンを付けて12pt離す() {
        let full = AIModelLabel.Stage(model: "gpt-6-astra · high", directory: "minutes")
        let dropped = AIModelLabel.Stage(model: "gpt-6-astra · high")
        #expect(AIModelFooter.gap == 12)
        #expect(AIModelFooter.width(of: full)
                == AIModelFooter.modelWidth(full.model) + 12 + AIModelFooter.placeWidth("minutes"))
        #expect(AIModelFooter.width(of: dropped) == AIModelFooter.modelWidth(dropped.model))
        // 塊ごとにアイコンぶんの場所を先頭へ確保する。どちらも文字だけの幅より広い。
        func text(_ value: String) -> CGFloat {
            ceil((value as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width)
        }
        #expect(AIModelFooter.placeWidth("minutes") >= text("minutes") + 11)
        #expect(AIModelFooter.modelWidth("gpt-6-astra") >= text("gpt-6-astra") + 11)
    }

    @Test func 返事待ちでは進行文とバーの下へ出す() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let row = try row(root: root, answered: false)
        #expect(row.isWaiting && row.timeText.isEmpty)
        #expect(row.modelText == "gpt-6-astra · high · minutes")
        #expect(row.modelFooter.frame.minY >= row.progressView.frame.maxY)
        #expect(row.modelFooter.frame.maxY <= row.frame.height)
    }

    @Test func プロファイルに値が無ければ表記ごと出さず行も高くしない() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let missing = try row(root: root, labels: [:])
        #expect(missing.modelText.isEmpty && missing.modelFooter.isHidden)
        // 枠違いの表記は引かない。会議で固定した自分の枠のものだけを読む。
        let otherSlot = try row(root: root, labels: [2: label])
        #expect(otherSlot.modelText.isEmpty)
        // 行が高くなるのはフッターを出す行だけで、その分はちょうど1段。
        let shown = try row(root: root)
        #expect(shown.height(for: 600) == missing.height(for: 600) + AIModelFooter.height)
    }

    /// 幅を削ると 作業場所の塊 → エフォート の順に落ちる。行の高さは変わらない。
    @Test func 幅が足りなければ作業場所の塊からエフォートの順に落とす() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let row = try row(root: root)
        let height = row.height(for: 600)
        var seen: [String] = []
        for width in stride(from: CGFloat(600), through: 200, by: -1) {
            row.frame = NSRect(x: 0, y: 0, width: width, height: row.height(for: width))
            row.layoutSubtreeIfNeeded()
            if seen.last != row.modelText { seen.append(row.modelText) }
            let footer = row.modelFooter
            // 折り返さず、本文の幅に収める。段を落としても行の高さは動かない。
            #expect(footer.frame.height == AIModelFooter.height && row.height(for: width) == height)
            if let stage = footer.stage {
                #expect(AIModelFooter.width(of: stage) <= AIRowMetrics.bodyWidth(width))
            }
        }
        // 420ptは利用者に出せる下限。そこでは全部入りが残る。
        row.frame = NSRect(x: 0, y: 0, width: 420, height: row.height(for: 420))
        row.layoutSubtreeIfNeeded()
        #expect(row.modelText == "gpt-6-astra · high · minutes")
        // 落ちる順は作業場所の塊→エフォート。飛ばしも戻りもしない。
        #expect(seen == label.stages.map(\.text))
    }

    /// 失敗の帯は見出しだけの1行なので、段を足さない。
    @Test func 失敗の帯には出さない() throws {
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
        #expect(row.isFailure && row.modelText.isEmpty && row.modelFooter.isHidden)
        // 帯は見出しと理由へ幅を全部使える。
        let failure = try field(row, row.failureText)
        let time = try field(row, row.timeText)
        #expect(failure.frame.maxX <= time.frame.minX && failure.frame.width >= 180)
        // 読み上げには全部入りを残す。
        #expect((row.accessibilityLabel() ?? "").contains("gpt-6-astra · high · minutes"))
    }

    /// 3宛先が同時に並ぶ混雑した会議を420ptで開いても、行ごとに自分の宛先の表記を出す。
    @Test func 三宛先の混雑画面を420ptで開いても行ごとに自分の宛先を出す() throws {
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
        var seen: [String] = []
        for item in items {
            let row = AIReplyRow(item: item, state: state)
            row.frame = NSRect(x: 0, y: 0, width: 420, height: row.height(for: 420))
            row.layoutSubtreeIfNeeded()
            #expect(!row.timeText.isEmpty && !row.durationText.isEmpty)
            // 名前行は宛先が増えても変わらない。表記は各行のフッターが持つ。
            #expect(!labels(row).contains { $0.stringValue.contains("gpt-6-astra") })
            seen.append(row.modelText)
        }
        #expect(seen == ["gpt-6-astra · high · minutes", "claude · max · owlery", "gpt-6-astra · kikigaki"])
    }
}
