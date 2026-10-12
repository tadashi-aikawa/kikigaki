import Foundation
import Testing
@testable import KikigakiCore

@Suite struct AIResolutionTests {
    private let now = Date(timeIntervalSince1970: 1000)
    private func request(_ conversation: AIConversation, meeting: UUID? = nil) throws -> AIRequest {
        var history = try AIStreamHistory(meetingID: meeting ?? conversation.meetingID)
        let root = URL(fileURLWithPath: "/tmp/resolution-tests")
        let snapshot = try history.prepare(lines: ["[13:19:40] タダシ: うん、その案で進めよう"], outputDirectory: root)
        let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: "迅雷", cliPath: "/tmp/helper", sessionPath: root.appendingPathComponent(".kikigaki-context/\(snapshot.meetingID)/ai/sessions/1.json").path,
            requestToken: "token", question: "続き", capturedAt: now, audioCutoffSeconds: 1,
            unansweredQuestions: conversation.unansweredQuestions)
        return try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant), number: conversation.questions.count + 1)
    }
    private func fixture() throws -> (AIConversation, AIRequest, AIRequest) {
        var state = AIConversation(meetingID: UUID())
        let parent = try request(state)
        try state.append(parent)
        try state.update(parent.id) { try $0.beginSending(at: now) }
        try state.receive(AIReceiveEvent(request: parent, kind: .needsInput, recordedAt: now,
            body: "この案で進めてよいですか", reason: "clarification"), at: now)
        let sender = try request(state)
        try state.append(sender)
        try state.update(sender.id) { try $0.beginSending(at: now) }
        return (state, parent, sender)
    }
    private func event(_ sender: AIRequest, _ parent: AIRequest) throws -> AIResolutionEvent {
        try AIResolutionEvent(request: sender, questionRequestID: parent.id,
            evidence: AIAnswerEvidence(speaker: "タダシ", time: "13:19:40", quote: "うん、その案で進めよう"), recordedAt: now)
    }
    @Test func 根拠が届くまで残り受信と再受信と復元で同じ結果になる() throws {
        var (state, parent, sender) = try fixture()
        #expect(state.unansweredQuestions.count == 1)
        #expect(sender.envelope.participant.unansweredQuestions.first?.body == "この案で進めてよいですか")
        let value = try event(sender, parent)
        #expect(try AIInbox.decodeResolution(AIJSON.encode(value), filename: value.filename, for: sender) == value)
        #expect(try state.receive(value))
        #expect(!(try state.receive(value)))
        #expect(state.unansweredQuestions.isEmpty)
        let restored = try AIJSON.decode(AIConversation.self, from: AIJSON.encode(state))
        #expect(restored == state)
        #expect(AIMarkdown.section(restored).contains("声で返答済み"))
        #expect(AIMarkdown.section(restored).contains("答え: タダシ 13:19:40「うん、その案で進めよう」"))
    }
    @Test func 別会議と未回答でない確認とファイル名違いを拒否する() throws {
        var (state, parent, sender) = try fixture()
        let value = try event(sender, parent)
        let foreign = try request(state, meeting: UUID())
        #expect(throws: AIError.mismatch) { try value.validate(for: foreign) }
        #expect(throws: AIError.mismatch) { try event(sender, sender) }
        #expect(throws: AIError.mismatch) { try AIInbox.decodeResolution(AIJSON.encode(value), filename: "wrong.json", for: sender) }
        try state.resolveManually(parent.id, at: now)
        #expect(throws: AIError.invalidTransition) { try state.receive(value) }
        #expect(AIMarkdown.section(state).contains("確認: 返答済み"))
        #expect(!AIMarkdown.section(state).contains("答え:"))
    }
    @Test func 旧保存物は未回答のまま復元する() throws {
        let (state, _, _) = try fixture()
        // JSONの解析はFoundationのJSONSerializationで行う。欠損した旧キーを再現する。
        var object = try #require(JSONSerialization.jsonObject(with: AIJSON.encode(state)) as? [String: Any])
        var questions = try #require(object["questions"] as? [[String: Any]])
        for index in questions.indices {
            questions[index].removeValue(forKey: "resolution")
            var request = try #require(questions[index]["request"] as? [String: Any])
            var envelope = try #require(request["envelope"] as? [String: Any])
            var participant = try #require(envelope["participant"] as? [String: Any])
            participant.removeValue(forKey: "unanswered_questions")
            envelope["participant"] = participant; request["envelope"] = envelope; questions[index]["request"] = request
        }
        object["questions"] = questions
        let restored = try AIJSON.decode(AIConversation.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.unansweredQuestions.count == 1)
        #expect(restored.questions.allSatisfy { $0.resolution == nil && $0.request.envelope.participant.unansweredQuestions.isEmpty })
    }
    @Test func 根拠の時刻と引用を検証し長い引用は省略する() throws {
        for time in ["24:00:00", "13:99:00", "13:19", "[13:19:40]"] {
            #expect(throws: (any Error).self) { try AIAnswerEvidence(speaker: "タダシ", time: time, quote: "はい") }
        }
        #expect(throws: (any Error).self) { try AIAnswerEvidence(speaker: "タダシ", time: "13:19:40", quote: "\n") }
        let evidence = try AIAnswerEvidence(speaker: "タダシ", time: "13:19:40", quote: String(repeating: "声", count: 81))
        #expect(evidence.answerLine.hasSuffix("…」"))
    }
}
