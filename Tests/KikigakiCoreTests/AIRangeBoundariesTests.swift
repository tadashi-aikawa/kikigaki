import Foundation
import Testing
import KikigakiCore

@Suite struct AIRangeBoundariesTests {
    private let utterances = (0..<10).map { Utterance(speaker: 0, start: Double($0 * 10), end: Double($0 * 10 + 4), text: "発話\($0)") }
    private func question(_ history: inout AIStreamHistory, number: Int, lines: Int,
                          kind: AIReceiveEvent.Kind? = nil) throws -> AIQuestion {
        let root = URL(fileURLWithPath: "/tmp/range-test")
        let snapshot = try history.prepare(lines: (0..<lines).map { "[00:00:00] 手入力: \($0)" }, outputDirectory: root)
        let p = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: history.sessionGeneration,
            participantName: "議事録", cliPath: "/tmp/helper",
            sessionPath: root.appendingPathComponent(".kikigaki-context/\(history.meetingID)/ai/sessions/\(history.sessionGeneration).json").path,
            requestToken: "test", question: "更新", capturedAt: Date(), audioCutoffSeconds: Double(max(0, lines * 10 - 5)), trigger: .scheduled)
        let request = try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: p), number: number,
                                    voiceQuestion: "", snapshot: snapshot)
        var q = try AIQuestion(request: request)
        try q.beginSending(at: Date()); try q.submitted()
        if let kind {
            try q.receive(AIReceiveEvent(request: request, kind: kind, recordedAt: Date(), body: kind == .accept ? nil : "返事"), at: Date(), order: number)
            try history.acknowledge(snapshotID: snapshot.id, streamID: history.streamID, sessionGeneration: history.sessionGeneration)
        }
        return q
    }

    @Test func 手入力を含む受領行数を二つの境界へ写す() throws {
        var h = try AIStreamHistory(meetingID: UUID())
        let answered = try question(&h, number: 1, lines: 2, kind: .answered)
        let accepted = try question(&h, number: 2, lines: 4, kind: .accept)
        let unreceived = try question(&h, number: 3, lines: 6)
        #expect(AIRangeBoundaries.resolve(history: h, questions: [answered, accepted, unreceived], utterances: utterances) == .init(answered: 1, accepted: 3))
    }

    @Test func 同じ境界は返事済み一本で空範囲には出さない() throws {
        var h = try AIStreamHistory(meetingID: UUID())
        let answered = try question(&h, number: 1, lines: 2, kind: .answered)
        let accepted = try question(&h, number: 2, lines: 2, kind: .accept)
        #expect(AIRangeBoundaries.resolve(history: h, questions: [answered, accepted], utterances: utterances) == .init(answered: 1))
        let empty = try question(&h, number: 3, lines: 0, kind: .answered)
        #expect(AIRangeBoundaries.resolve(history: h, questions: [empty], utterances: utterances) == .init())
    }

    @Test func 別streamと旧世代と取消の受領を混ぜない() throws {
        let meeting = UUID()
        var h = try AIStreamHistory(meetingID: meeting)
        var other = try AIStreamHistory(meetingID: meeting)
        let foreign = try question(&other, number: 1, lines: 8, kind: .answered)
        var cancelled = try question(&h, number: 2, lines: 3, kind: .accept)
        try cancelled.cancel(at: Date())
        #expect(AIRangeBoundaries.resolve(history: h, questions: [foreign, cancelled], utterances: utterances) == .init())
        let next = try AIStreamHistory(meetingID: meeting, sessionGeneration: 2)
        #expect(AIRangeBoundaries.resolve(history: next, questions: [cancelled], utterances: utterances) == .init())
    }

    @Test func 再分割と相槌省略でも受領した音声位置までを指す() throws {
        var history = try AIStreamHistory(meetingID: UUID())
        let answered = try question(&history, number: 1, lines: 4, kind: .answered)
        let accepted = try question(&history, number: 2, lines: 6, kind: .accept)
        let questions = [answered, accepted]
        func rows(_ starts: [Double]) -> [Utterance] {
            starts.map { Utterance(speaker: 0, start: $0, end: $0 + 3, text: "発話") }
        }
        // cutoffは35秒と55秒。停止時の分割数が増えても、送った範囲の末尾を保つ。
        #expect(AIRangeBoundaries.resolve(history: history, questions: questions,
            utterances: rows([0, 10, 20, 25, 30, 40, 50, 60])) == .init(answered: 4, accepted: 6))
        // 相槌の省略で行数が減っても消えず、残った発話の同じ音声位置へ写す。
        #expect(AIRangeBoundaries.resolve(history: history, questions: questions,
            utterances: rows([0, 30, 50, 60])) == .init(answered: 1, accepted: 2))
        let typed = try Utterance(typedText: "境界上の手入力", at: 55, postedAt: Date())
        #expect(AIRangeBoundaries.resolve(history: history, questions: questions,
            utterances: rows([0, 30, 50]) + [typed]) == .init(answered: 1, accepted: 3))
    }
}
