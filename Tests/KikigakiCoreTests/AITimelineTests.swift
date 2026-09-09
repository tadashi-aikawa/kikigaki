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
        // 送信の行のすぐ下に返事が来る場合は、同じ文が2回続くので引用を落とす。
        #expect(items.filter { !$0.isSend }.allSatisfy { $0.question.isEmpty })
        #expect(items.allSatisfy { $0.notes.contains("1発言") || !$0.isSend })
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
        // どの依頼で返したかを番号で結ぶ。「返答済み」だけでは往復を追えない。
        #expect(confirmation.notes.contains("#2で返答"))
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

        let reply = try #require(AITimeline.items(conversation: conversation, utterances: [], timeline: timeline,
                                                  generation: { _ in 2 }).first { !$0.isSend })
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
        #expect(try #require(items.first { $0.number == 1 }).notes.contains("1発言"))
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
        #expect(prepared.notes == ["2発言", "作業許可なし", "暫定末尾を含む", "送信準備中"])
        #expect(prepared.date == Date(timeIntervalSince1970: 30))   // 未送信は固定した確定時刻で置く
    }

    @Test func 送信と返事の間に発話が入るときだけ引用を残す() throws {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let value = try request(in: meeting, number: 1, question: "入力した問い")
        try send(&conversation, value, at: 20)
        try answer(&conversation, value, at: 60)
        // 送信は10秒の発話の後、返事は50秒の発話の後になり、間に発話が挟まる。
        let apart = AITimeline.items(conversation: conversation, utterances: [voice("先", at: 10), voice("後", at: 50)],
                                     timeline: timeline)
        #expect(apart.map(\.slot) == [0, 1])
        #expect(try #require(apart.last).question == "入力した問い")
        // 発話が挟まらなければ何への返事かは直上で読めるので引用は要らない。
        let adjacent = AITimeline.items(conversation: conversation, utterances: [voice("先", at: 10)], timeline: timeline)
        #expect(adjacent.map(\.slot) == [0, 0])
        #expect(try #require(adjacent.last).question.isEmpty)
    }

    @Test(arguments: [true, false]) func 失敗と取消で終わった返答は返答済みと数えず送り直せる(byFailure: Bool) throws {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let ask = try request(in: meeting, number: 1, anchor: 10)
        try send(&conversation, ask, at: 30)
        try answer(&conversation, ask, at: 31, kind: .needsInput, body: "社外の方も含みますか", reason: "clarification")
        let parent = try #require(conversation.questions.first)
        let first = try request(in: meeting, number: 2, question: "社内だけです", parent: parent)
        try send(&conversation, first, at: 40)
        func confirmation(_ conversation: AIConversation) throws -> AITimeline.Item {
            try #require(AITimeline.items(conversation: conversation, utterances: [voice("対象", at: 10)], timeline: timeline)
                .first { $0.number == 1 && !$0.isSend })
        }
        // 返答を送った直後は返答済み。確認待ちの導線を畳む。
        #expect(try confirmation(conversation).needsAnswer == false)

        if byFailure {
            try answer(&conversation, first, at: 41, kind: .failed, body: "送信できませんでした", reason: "send_failed")
        } else {
            try conversation.update(first.id) { try $0.cancel(at: Date(timeIntervalSince1970: 41)) }
        }
        // 送り直せる状態に戻るので「返答する」も件数も戻る。注記も消す。
        #expect(try confirmation(conversation).needsAnswer)
        #expect(try confirmation(conversation).notes.allSatisfy { !$0.contains("で返答") })
        #expect(!AIQuestion.isAnswered(conversation.questions[0], in: conversation.questions))

        let resent = try request(in: meeting, number: 3, question: "社内だけです", parent: conversation.questions[0])
        try send(&conversation, resent, at: 50)
        #expect(conversation.questions[0].answeredByRequestID == resent.id)
        #expect(try AIJSON.decode(AIConversation.self, from: AIJSON.encode(conversation)) == conversation)
        #expect(try confirmation(conversation).notes == ["#3で返答"])
        let items = AITimeline.items(conversation: conversation, utterances: [voice("対象", at: 10)], timeline: timeline)
        #expect(items.filter { $0.number == 3 }.map(\.kind) == [.sendRow, .reply(.waiting)])
    }

    @Test func 会話がなければ何も返さない() {
        #expect(AITimeline.items(conversation: nil, utterances: [voice("発話", at: 1)], timeline: timeline).isEmpty)
    }

    @Test func 同時刻の返事はrequest番号ではなく記録順で並べる() throws {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let first = try request(in: meeting, number: 1, question: "先の問い")
        let second = try request(in: meeting, number: 2, question: "後の問い")
        try send(&conversation, first, at: 30)
        try send(&conversation, second, at: 31)
        // 記録は#2が先。同じ到着時刻でも取り込んだ順を保つ。
        try answer(&conversation, second, at: 40)
        try answer(&conversation, first, at: 40)
        let replies = AITimeline.items(conversation: conversation, utterances: [], timeline: timeline).filter { !$0.isSend }
        #expect(replies.map(\.number) == [2, 1])
    }

    @Test func 送信前の失敗は同着の返事より先に置き送信時刻を表示する() throws {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let failed = try request(in: meeting, number: 1, question: "起動前に失敗")
        try conversation.append(failed)
        try conversation.update(failed.id) { try $0.failBeforeSending("接続が切れています") }
        let answered = try request(in: meeting, number: 2, question: "問い")
        try send(&conversation, answered, at: 20)
        try answer(&conversation, answered, at: 30)
        let items = AITimeline.items(conversation: conversation, utterances: [], timeline: timeline).filter { !$0.isSend }
        #expect(items.map(\.number) == [1, 2])
        // 送信前失敗は到着時刻を持たないので、固定した確定時刻で置く。
        #expect(items[0].date == Date(timeIntervalSince1970: 30))
    }

    @Test func 日時が単調でない発話列でも間の発話を飛び越えない() throws {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let value = try request(in: meeting, number: 1, question: "問い")
        try send(&conversation, value, at: 30)
        // 手入力の併合や一時停止で、表示上の日時は必ずしも増えていかない。
        let utterances = [voice("10秒", at: 10), voice("40秒", at: 40), voice("20秒", at: 20)]
        let send = try #require(AITimeline.items(conversation: conversation, utterances: utterances, timeline: timeline).first)
        #expect(send.slot == 0)   // 40秒の手前。最後の一致で探すと20秒の後ろへ飛んでしまう
    }

    @Test func 停止後に届いた返事は時計が飛んでも末尾へ置く() throws {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let value = try request(in: meeting, number: 1, question: "問い")
        try send(&conversation, value, at: 30)
        try answer(&conversation, value, at: 60)
        let typed = try Utterance(typedText: "後から見える投稿", at: 20, postedAt: Date(timeIntervalSince1970: 500))
        let utterances = [voice("10秒", at: 10), typed]
        let ended = Date(timeIntervalSince1970: 50)
        let without = try #require(AITimeline.items(conversation: conversation, utterances: utterances, timeline: timeline)
            .first { !$0.isSend })
        #expect(without.slot == 0)
        let after = try #require(AITimeline.items(conversation: conversation, utterances: utterances, timeline: timeline,
                                                  endedAt: ended).first { !$0.isSend })
        #expect(after.slot == 1)
    }

    @Test func 取消後に届いた失敗も朱の帯にし注記を併記する() throws {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let value = try request(in: meeting, number: 1, question: "問い")
        try send(&conversation, value, at: 30)
        try conversation.update(value.id) { try $0.cancel(at: Date(timeIntervalSince1970: 33)) }
        try answer(&conversation, value, at: 40, kind: .failed, body: "接続が切れました", reason: "send_failed")
        let item = try #require(AITimeline.items(conversation: conversation, utterances: [], timeline: timeline)
            .first { !$0.isSend })
        // 取消後の結果は状態がcancelledのまま残るので、結果の種類も見ないと返事に化ける。
        #expect(item.kind == .failure(reason: "接続が切れました"))
        #expect(item.notes == ["取消後の返事"])
    }

    @Test func 複数の返事待ちは送信時刻の順に末尾へ並べる() throws {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let first = try request(in: meeting, number: 1, question: "先")
        let second = try request(in: meeting, number: 2, question: "後")
        // 番号は追加順だが、送信の試行は後の番号が先という並びを作る。
        try send(&conversation, first, at: 40)
        try send(&conversation, second, at: 20)
        let waiting = AITimeline.items(conversation: conversation, utterances: [voice("発話", at: 5)], timeline: timeline)
            .filter { $0.kind == .reply(.waiting) }
        #expect(waiting.map(\.number) == [2, 1])
        #expect(waiting.allSatisfy { $0.anchor == .tail && $0.slot == 0 })
    }

    @Test func 同じ発話へ複数の声の送信が付いても番号順を保つ() throws {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let first = try request(in: meeting, number: 1, anchor: 10)
        let second = try request(in: meeting, number: 2, anchor: 12)
        try send(&conversation, first, at: 30)
        try send(&conversation, second, at: 40)
        // 元の開始位置が消えても、その位置以下の最も近い先行発話へ付け直す。
        let utterances = [voice("先行の発話", at: 8), voice("後続の発話", at: 60)]
        let sends = AITimeline.items(conversation: conversation, utterances: utterances, timeline: timeline).filter(\.isSend)
        #expect(sends.map(\.anchor) == [.afterUtterance(0), .afterUtterance(0)])
        #expect(sends.map(\.number) == [1, 2])
    }

    @Test func 発話と同時刻のAIは発話の後ろへ置く() throws {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let value = try request(in: meeting, number: 1, question: "問い")
        try send(&conversation, value, at: 10)
        let item = try #require(AITimeline.items(conversation: conversation, utterances: [voice("同時刻の発話", at: 10)],
                                                 timeline: timeline).first)
        #expect(item.slot == 0)
    }

    @Test(arguments: [1, 2]) func 旧接続の注記は現在の世代より小さいときだけ付ける(generation: Int) throws {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let value = try request(in: meeting, number: 1, question: "問い", generation: 1)
        try send(&conversation, value, at: 30)
        try answer(&conversation, value, at: 40)
        let reply = try #require(AITimeline.items(conversation: conversation, utterances: [], timeline: timeline,
                                                  generation: { _ in generation }).first { !$0.isSend })
        #expect(reply.notes.contains("旧接続からの返事") == (generation == 2))
    }

    @Test func 返事待ちの注記は接続の観測から作り対象範囲も持つ() throws {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let value = try request(in: meeting, number: 1, question: "問い",
                                lines: ["[00:00:10] 話者A: 一行目", "[00:00:20] 話者A: 二行目"])
        try send(&conversation, value, at: 30)
        func notes(_ connection: AIConnectionStatus, unconfirmed: Set<UUID> = []) throws -> [String] {
            try #require(AITimeline.items(conversation: conversation, utterances: [], timeline: timeline,
                                          connection: { _ in connection }, unconfirmed: unconfirmed).first { !$0.isSend }).notes
        }
        let blocked = try notes(.blocked), disconnected = try notes(.disconnected)
        let idle = try notes(.idle), unconfirmed = try notes(.idle, unconfirmed: [value.id])
        #expect(blocked == ["ペインで確認してください"])
        #expect(disconnected == ["接続が切れています"])
        #expect(idle.isEmpty)
        #expect(unconfirmed == ["返送未確認"])
        let send = try #require(AITimeline.items(conversation: conversation, utterances: [], timeline: timeline).first)
        #expect(send.timeRange?.start == "00:00:10" && send.timeRange?.end == "00:00:20")
    }
}
