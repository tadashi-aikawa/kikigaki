import Foundation
import Testing
import KikigakiCore

@Suite struct AIScheduledProtocolTests {
    @Test func 設定と旧manifestの既定を検証する() throws {
        let home = URL(fileURLWithPath: "/tmp/scheduled")
        let defaults = try #require(ResolvedConfig(config: ConfigLoader.parse(toml: "[ai]"), home: home).ai)
        #expect(defaults.autoPrompt == "" && defaults.autoIntervalMinutes == 3)
        for minutes in [1, 7, 60] {
            let config = try #require(ResolvedConfig(config: ConfigLoader.parse(toml: "[ai]\nautoPrompt = '議事録を更新'\nautoIntervalMinutes = \(minutes)"), home: home).ai)
            let restored = try AIJSON.decode(ResolvedAIConfig.self, from: AIJSON.encode(config))
            #expect(restored.autoIntervalMinutes == minutes && restored.autoPrompt == "議事録を更新")
        }
        for value in ["0", "61", "-1", "1.5", "'3'", "true"] {
            #expect(throws: (any Error).self) { try ConfigLoader.parse(toml: "[ai]\nautoIntervalMinutes = \(value)") }
        }
        #expect(throws: (any Error).self) { try ConfigLoader.parse(toml: "[ai]\nautoPrompt = 3") }
        #expect(throws: (any Error).self) { try AIConfig(autoPrompt: "a\0").validate() }
        #expect(throws: (any Error).self) { try AIConfig(autoPrompt: String(repeating: "あ", count: 11_000)).validate() }
        var old = try #require(JSONSerialization.jsonObject(with: AIJSON.encode(defaults)) as? [String: Any])
        old.removeValue(forKey: "autoPrompt"); old.removeValue(forKey: "autoIntervalMinutes")
        let restored = try AIJSON.decode(ResolvedAIConfig.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(restored.autoPrompt == "" && restored.autoIntervalMinutes == 3)
        old["autoIntervalMinutes"] = NSNull()
        #expect(throws: (any Error).self) { try AIJSON.decode(ResolvedAIConfig.self, from: JSONSerialization.data(withJSONObject: old)) }
    }

    private func request(trigger: AIParticipantContext.Trigger?) throws -> AIRequest {
        let meeting = UUID(), root = URL(fileURLWithPath: "/tmp/scheduled")
        var history = try AIStreamHistory(meetingID: meeting)
        let snapshot = try history.prepare(lines: ["[12:00:00] 佐藤: 決定しました"], outputDirectory: root)
        let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: "迅雷", cliPath: "/tmp/helper", sessionPath: root.appendingPathComponent(".kikigaki-context/\(meeting)/ai/sessions/1.json").path,
            requestToken: "test", question: "議事録を更新", capturedAt: Date(), audioCutoffSeconds: 1, trigger: trigger)
        return try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant), number: 1, snapshot: snapshot)
    }

    @Test func triggerの欠損互換と不正値を検証する() throws {
        let manual = try request(trigger: nil)
        #expect(!String(decoding: try AIJSON.encode(manual.envelope.participant), as: UTF8.self).contains("trigger"))
        #expect(try AIJSON.decode(AIRequest.self, from: AIJSON.encode(manual)).trigger == nil)
        let auto = try request(trigger: .scheduled)
        #expect(try AIJSON.decode(AIRequest.self, from: AIJSON.encode(auto)).trigger == .scheduled)
        #expect(auto.envelope.schemaVersion == 1 && auto.envelope.participant.schemaVersion == 1)
        #expect(auto.automaticLabel == " · 自動" && manual.automaticLabel.isEmpty)
        var json = try #require(JSONSerialization.jsonObject(with: AIJSON.encode(auto.envelope.participant)) as? [String: Any])
        for invalid: Any in ["manual", "unknown", 1, true, NSNull()] {
            json["trigger"] = invalid
            #expect(throws: (any Error).self) { try AIJSON.decode(AIParticipantContext.self, from: JSONSerialization.data(withJSONObject: json)) }
        }
    }

    @Test(arguments: [AIReceiveEvent.Kind.answered, .needsInput, .failed])
    func 自動answeredだけ未読にせず保存の往復でも保持する(kind: AIReceiveEvent.Kind) throws {
        for trigger: AIParticipantContext.Trigger? in [nil, .scheduled] {
            let request = try request(trigger: trigger)
            var conversation = AIConversation(meetingID: request.envelope.meetingID)
            try conversation.append(request)
            try conversation.update(request.id) { try $0.beginSending(at: Date()); try $0.submitted() }
            let event = try AIReceiveEvent(request: request, kind: kind, recordedAt: Date(), body: "結果",
                                       reason: kind == .needsInput ? "clarification" : kind == .failed ? "work_failed" : nil)
            _ = try conversation.receive(event, at: Date())
            let restored = try AIJSON.decode(AIConversation.self, from: AIJSON.encode(conversation))
            #expect(restored.questions[0].isUnread == !(trigger == .scheduled && kind == .answered))
            #expect(AIMarkdown.section(restored).contains(" (自動)") == (trigger == .scheduled))
        }
    }
}
