import Foundation
import Testing
import KikigakiCore

@Suite struct AITimelineTests {
    private let root = URL(fileURLWithPath: "/tmp/ai-timeline")
    private let timeline = MeetingTimeline(startedAt: Date(timeIntervalSince1970: 0))

    private func request(in meeting: UUID, number: Int, question: String = "", anchor: Double? = nil,
                         name: String = "迅雷", generation: Int = 1, workAllowed: Bool = true,
                         tail: AITentativeTail? = nil, trigger: AIParticipantContext.Trigger? = nil,
                         parent: AIQuestion? = nil, lines: [String] = ["[00:00:10] 話者A: 元の会話"]) throws -> AIRequest {
        var history = try AIStreamHistory(meetingID: meeting, sessionGeneration: generation)
        let snapshot = try history.prepare(lines: lines, outputDirectory: root)
        let participant = AIParticipantContext(streamID: snapshot.streamID, requestID: UUID(), sessionGeneration: generation,
            participantName: name, cliPath: "/tmp/helper",
            sessionPath: root.appendingPathComponent(".kikigaki-context/\(meeting)/ai/sessions/\(generation).json").path,
            requestToken: "test", question: question, capturedAt: Date(timeIntervalSince1970: 30),
            audioCutoffSeconds: 60, tentativeTail: tail,
            inReplyToRequestID: parent?.request.id, inReplyToEventID: parent?.result?.eventID,
            workAllowed: workAllowed, trigger: trigger)
        return try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant), number: number,
                             voiceQuestion: "声の問い", snapshot: snapshot, voiceUtteranceStart: anchor)
    }

    private func send(_ conversation: inout AIConversation, _ request: AIRequest, at seconds: Double) throws {
        try conversation.append(request)
        try conversation.update(request.id) {
            try $0.beginSending(at: Date(timeIntervalSince1970: seconds)); try $0.submitted()
        }
    }

    private func answer(_ conversation: inout AIConversation, _ request: AIRequest, at seconds: Double,
                        kind: AIReceiveEvent.Kind = .answered, body: String = "返事", reason: String? = nil) throws {
        let date = Date(timeIntervalSince1970: seconds)
        try conversation.receive(AIReceiveEvent(request: request, kind: kind, recordedAt: date, body: body, reason: reason), at: date)
    }

    private func voice(_ text: String, at start: Double) -> Utterance {
        Utterance(speaker: 0, start: start, end: start + 2, text: text)
    }

    @Test func 送信の形は声と手動入力と自動で分かれ引用は手動入力だけに付く() throws {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let voiceRequest = try request(in: meeting, number: 1, anchor: 10)
        try send(&conversation, voiceRequest, at: 30)
        try answer(&conversation, voiceRequest, at: 31)
        let typedRequest = try request(in: meeting, number: 2, question: "入力した問い")
        try send(&conversation, typedRequest, at: 40)
        try answer(&conversation, typedRequest, at: 41)
        let autoRequest = try request(in: meeting, number: 3, question: "議事録を更新して", trigger: .scheduled)
        try send(&conversation, autoRequest, at: 50)
        try answer(&conversation, autoRequest, at: 51)

        let items = AITimeline.items(conversation: conversation, utterances: [voice("元の会話", at: 10)], timeline: timeline)
        let sends = items.filter(\.isSend)
        #expect(sends.map(\.kind) == [.sendLine(automatic: false), .sendRow, .sendLine(automatic: true)])
        #expect(sends[0].anchor == .afterUtterance(0))
        #expect(sends[1].anchor == .at(Date(timeIntervalSince1970: 40)))
        #expect(sends[2].anchor == .at(Date(timeIntervalSince1970: 50)))
        #expect(sends.map(\.automatic) == [false, false, true])
        #expect(sends[1].question == "入力した問い")
        // 引用は手動入力の返事だけへ添える。声は発話そのもの、自動は毎回同じ定型文になる。
        #expect(items.filter { !$0.isSend }.map(\.question) == ["", "入力した問い", ""])
        #expect(items.allSatisfy { $0.notes.contains("対象: 1発言") || !$0.isSend })
    }

    @Test func 確認への返答は人側の行にし親番号を持つ() throws {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let first = try request(in: meeting, number: 1, anchor: 10)
        try send(&conversation, first, at: 30)
        try answer(&conversation, first, at: 31, kind: .needsInput, body: "社外の方も含みますか", reason: "clarification")
        let parent = try #require(conversation.questions.first)
        let reply = try request(in: meeting, number: 2, question: "社内だけです", parent: parent)
        try send(&conversation, reply, at: 40)

        let items = AITimeline.items(conversation: conversation, utterances: [voice("元の会話", at: 10)], timeline: timeline)
        let confirmation = try #require(items.first { $0.number == 1 && !$0.isSend })
        #expect(confirmation.kind == .reply(.needsInput))
        #expect(confirmation.needsAnswer == false)      // 返答済みなので確認待ちの導線は畳む
        #expect(confirmation.notes.contains("返答済み"))
        let answerSend = try #require(items.first { $0.number == 2 && $0.isSend })
        #expect(answerSend.kind == .sendRow)
        #expect(answerSend.parentNumber == 1)
        #expect(try #require(items.first { $0.number == 2 && !$0.isSend }).kind == .reply(.waiting))
    }

    @Test func 声の送信は対象の直下へ置き再分割で発話が消えたら日時順へ落ちる() throws {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let value = try request(in: meeting, number: 1, anchor: 10)
        try send(&conversation, value, at: 30)
        let utterances = [voice("先の発話", at: 5), voice("対象の発話", at: 10), voice("後の発話", at: 45)]
        let attached = AITimeline.items(conversation: conversation, utterances: utterances, timeline: timeline)
        #expect(attached[0].anchor == .afterUtterance(1))
        #expect(attached[0].slot == 1)

        // 対象より後の発話しか残らなければアンカーを解決できず、送信時刻の位置へ戻す。
        let later = [voice("後の発話", at: 45)]
        let fallen = AITimeline.items(conversation: conversation, utterances: later, timeline: timeline)
        #expect(fallen[0].anchor == .at(Date(timeIntervalSince1970: 30)))
        #expect(fallen[0].slot == -1)
    }

    @Test func 返事待ちは常に末尾へ置き到着で到着時刻の位置へ移る() throws {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let value = try request(in: meeting, number: 1, anchor: 10)
        try send(&conversation, value, at: 30)
        let utterances = [voice("対象の発話", at: 10), voice("後の発話", at: 45), voice("さらに後", at: 80)]

        let waiting = try #require(AITimeline.items(conversation: conversation, utterances: utterances, timeline: timeline)
            .first { !$0.isSend })
        #expect(waiting.kind == .reply(.waiting))
        // 送信時刻は30秒で発話の間だが、待ち行は末尾へ置く。発話が増えても上へ跳ねない。
        #expect(waiting.anchor == .tail)
        #expect(waiting.slot == 2)
        #expect(waiting.date == nil)

        try answer(&conversation, value, at: 50)
        let arrived = try #require(AITimeline.items(conversation: conversation, utterances: utterances, timeline: timeline)
            .first { !$0.isSend })
        #expect(arrived.kind == .reply(.answered))
        #expect(arrived.anchor == .at(Date(timeIntervalSince1970: 50)))
        #expect(arrived.slot == 1)
        #expect(arrived.date == Date(timeIntervalSince1970: 50))
        #expect(arrived.rowID == waiting.rowID)   // 同じ行を使い回すので到着で生まれ直さない
    }

    @Test func 同じ日時では送信を先にしrequest番号で決める() throws {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let first = try request(in: meeting, number: 1, question: "先の問い")
        try send(&conversation, first, at: 30)
        try answer(&conversation, first, at: 30)
        let second = try request(in: meeting, number: 2, question: "後の問い")
        try send(&conversation, second, at: 30)
        try answer(&conversation, second, at: 30)

        let items = AITimeline.items(conversation: conversation, utterances: [voice("発話", at: 10)], timeline: timeline)
        #expect(items.map { "\($0.number)\($0.isSend ? "送" : "返")" } == ["1送", "2送", "1返", "2返"])
        #expect(items.allSatisfy { $0.slot == 0 })
    }

    @Test func 発話ゼロでも日時順に並べ声の送信も細い1行のまま残る() throws {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let value = try request(in: meeting, number: 1, anchor: 10)
        try send(&conversation, value, at: 30)
        try answer(&conversation, value, at: 35)

        let items = AITimeline.items(conversation: conversation, utterances: [], timeline: timeline)
        #expect(items.map(\.kind) == [.sendLine(automatic: false), .reply(.answered)])
        #expect(items.map(\.anchor) == [.at(Date(timeIntervalSince1970: 30)), .at(Date(timeIntervalSince1970: 35))])
        #expect(items.allSatisfy { $0.slot == -1 })
    }

    @Test func 宛名はrequestごとに読み会議の既定値へ依存しない() throws {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let minutes = try request(in: meeting, number: 1, question: "議事録", name: "迅雷")
        try send(&conversation, minutes, at: 30)
        try answer(&conversation, minutes, at: 31)
        let advice = try request(in: meeting, number: 2, question: "相談", name: "ミネルヴァ")
        try send(&conversation, advice, at: 40)

        let items = AITimeline.items(conversation: conversation, utterances: [], timeline: timeline)
        #expect(items.filter { $0.number == 1 }.allSatisfy { $0.participantName == "迅雷" })
        #expect(items.filter { $0.number == 2 }.allSatisfy { $0.participantName == "ミネルヴァ" })
    }

    @Test func 旧世代の返事と取消後の返事に注記を付ける() throws {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let value = try request(in: meeting, number: 1, question: "問い", generation: 1)
        try send(&conversation, value, at: 30)
        try conversation.update(value.id) { try $0.cancel(at: Date(timeIntervalSince1970: 33)) }
        try answer(&conversation, value, at: 35)

        let reply = try #require(AITimeline.items(conversation: conversation, utterances: [], timeline: timeline, generation: 2)
            .first { !$0.isSend })
        #expect(reply.notes == ["取消後の返事", "旧接続からの返事"])
        #expect(reply.body == "返事")
    }

    @Test func 失敗は朱の帯へ落とし送達不明は送信の注記に留める() throws {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let unsent = try request(in: meeting, number: 1, question: "起動前に失敗")
        try conversation.append(unsent)
        try conversation.update(unsent.id) { try $0.failBeforeSending("接続が切れています") }
        let unknown = try request(in: meeting, number: 2, question: "送達不明")
        try conversation.append(unknown)
        try conversation.update(unknown.id) { try $0.beginSending(at: Date(timeIntervalSince1970: 40)) }
        let returned = try request(in: meeting, number: 3, question: "返送された失敗")
        try send(&conversation, returned, at: 50)
        try answer(&conversation, returned, at: 51, kind: .failed, body: "読めませんでした\n詳細", reason: "read_failed")

        let items = AITimeline.items(conversation: conversation, utterances: [], timeline: timeline)
        #expect(items.first { $0.number == 1 && !$0.isSend }?.kind == .failure(reason: "接続が切れています"))
        #expect(items.first { $0.number == 3 && !$0.isSend }?.kind == .failure(reason: "読めませんでした"))
        // 成否が分からないので「考え中…」は出さず、送信の行の注記だけにする。
        #expect(!items.contains { $0.number == 2 && !$0.isSend })
        #expect(try #require(items.first { $0.number == 2 }).notes.contains("送達不明"))
        #expect(try #require(items.first { $0.number == 1 }).notes.contains("対象: 1発言"))
        #expect(items.filter { !$0.isSend }.allSatisfy { $0.rowID.hasSuffix("/reply") })
        #expect(items.filter(\.isSend).allSatisfy { $0.rowID.hasSuffix("/send") })
    }

    @Test func 送信の注記は作業許可と暫定末尾と対象件数を持つ() throws {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let tail = AITentativeTail(text: "言いかけ", startSeconds: 40, endSeconds: 50)
        let value = try request(in: meeting, number: 1, question: "問い", workAllowed: false, tail: tail,
                                lines: ["[00:00:10] 話者A: 一行目", "[00:00:20] 話者A: 二行目"])
        try conversation.append(value)
        let prepared = try #require(AITimeline.items(conversation: conversation, utterances: [], timeline: timeline).first)
        #expect(prepared.notes == ["対象: 2発言", "作業許可なし", "暫定末尾を含む", "送信準備中"])
        #expect(prepared.date == Date(timeIntervalSince1970: 30))   // 未送信は固定した確定時刻で置く
    }

    @Test func 会話がなければ何も返さない() {
        #expect(AITimeline.items(conversation: nil, utterances: [voice("発話", at: 1)], timeline: timeline).isEmpty)
    }
}
