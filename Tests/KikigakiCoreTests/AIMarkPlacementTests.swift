import Foundation
import Testing
import KikigakiCore

@Suite struct AIMarkPlacementTests {
    private func request(typed: Bool, anchor: Double?) throws -> AIRequest {
        let root = URL(fileURLWithPath: "/tmp/mark-placement"), meeting = UUID()
        var history = try AIStreamHistory(meetingID: meeting)
        let snapshot = try history.prepare(lines: ["[00:00:10] 話者A: 問い"], outputDirectory: root)
        let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: "迅雷", cliPath: "/tmp/helper", sessionPath: root.appendingPathComponent(".kikigaki-context/\(meeting)/ai/sessions/1.json").path,
            requestToken: "test", question: typed ? "入力した問い" : "", capturedAt: Date(timeIntervalSince1970: 30), audioCutoffSeconds: 30)
        return try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant), number: 1,
            voiceQuestion: "問いと暫定末尾", snapshot: snapshot, voiceUtteranceStart: anchor)
    }
    @Test(arguments: [false, true], [false, true]) func 声の印は対象直下へ置き再分割後も時刻列を変えない(typed: Bool, merged: Bool) throws {
        let request = try request(typed: typed, anchor: 10)
        var conversation = AIConversation(meetingID: request.envelope.meetingID)
        try conversation.append(request); try conversation.update(request.id) { try $0.beginSending(at: Date(timeIntervalSince1970: 30)); try $0.submitted() }
        _ = try conversation.receive(AIReceiveEvent(request: request, kind: .answered, recordedAt: Date(timeIntervalSince1970: 40), body: "回答"), at: Date(timeIntervalSince1970: 41))
        let utterances = [Utterance(speaker: 0, start: merged ? 5 : 10, end: 15, text: "問い"), Utterance(speaker: 0, start: 20, end: 25, text: "後続の発言")]
        #expect(request.voiceAnchorIndex(in: utterances) == (typed ? nil : 0))
        let meeting = MeetingMarkdown.Meeting(startedAt: Date(timeIntervalSince1970: 0), duration: 50, utterances: utterances, names: SpeakerNames([0: "改名後"]), ai: conversation)
        let lines = MeetingMarkdown.render(meeting, timeZone: TimeZone(secondsFromGMT: 0)!).components(separatedBy: "\n")
        let questionLine = try #require(lines.firstIndex { $0.contains("改名後: 問い") })
        let laterLine = try #require(lines.firstIndex { $0.contains("後続の発言") })
        let mark = try #require(lines.firstIndex { $0.contains("AIへ質問 Q1") })
        #expect(mark == (typed ? laterLine : questionLine) + 1)
        #expect(lines[mark].contains("[00:00:30]"))
        #expect(try #require(lines.firstIndex { $0.contains("[00:00:41] AI回答 Q1") }) > laterLine)
        #expect(try AIJSON.decode(AIRequest.self, from: AIJSON.encode(request)).voiceUtteranceStart == (typed ? nil : 10))
    }
    @Test func 旧requestと対象なしは時刻へ戻り不正な位置を拒否する() throws {
        let value = try request(typed: false, anchor: 10)
        var json = try #require(JSONSerialization.jsonObject(with: AIJSON.encode(value)) as? [String: Any])
        json.removeValue(forKey: "voiceUtteranceStart")
        let old = try AIJSON.decode(AIRequest.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.voiceAnchorIndex(in: [.init(speaker: 0, start: 0, end: 1, text: "発話")]) == nil)
        #expect(value.voiceAnchorIndex(in: []) == nil)
        #expect(value.voiceAnchorIndex(in: [.init(speaker: 0, start: 20, end: 25, text: "後続だけ")]) == nil)
        for invalid in [-1.0, .infinity, 31] {
            #expect(throws: AIError.self) { try request(typed: false, anchor: invalid) }
        }
    }
}
