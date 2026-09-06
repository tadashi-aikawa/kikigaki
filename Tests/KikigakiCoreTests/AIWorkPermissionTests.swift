import Foundation
import Testing
import KikigakiCore

@Suite struct AIWorkPermissionTests {
    @Test func 作業許可の既定は有効で設定と旧会議の互換を保つ() throws {
        let home = URL(fileURLWithPath: "/tmp/work-permission")
        let defaults = ResolvedConfig(config: try ConfigLoader.parse(toml: "[ai]"), home: home)
        #expect(defaults.ai?.allowWork == true)
        let disabled = ResolvedConfig(config: try ConfigLoader.parse(toml: "[ai]\nallowWork = false"), home: home)
        #expect(disabled.ai?.allowWork == false)
        let config = try #require(disabled.ai)
        #expect(try AIJSON.decode(ResolvedAIConfig.self, from: AIJSON.encode(config)).allowWork == false)
        var old = try #require(JSONSerialization.jsonObject(with: AIJSON.encode(config)) as? [String: Any])
        old.removeValue(forKey: "allowWork")
        #expect(try AIJSON.decode(ResolvedAIConfig.self, from: JSONSerialization.data(withJSONObject: old)).allowWork)
        #expect(throws: (any Error).self) { try ConfigLoader.parse(toml: "[ai]\nallowWork = \"false\"") }
    }
    @Test(arguments: [false, true]) func envelopeとMarkdownへ質問ごとの作業許可を固定する(allowed: Bool) throws {
        let root = URL(fileURLWithPath: "/tmp/work-permission"), meeting = UUID()
        var history = try AIStreamHistory(meetingID: meeting)
        let snapshot = try history.prepare(lines: ["[12:00:00] 話者A: ファイルへ追記して"], outputDirectory: root)
        let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: "迅雷", cliPath: "/tmp/helper", sessionPath: root.appendingPathComponent(".kikigaki-context/\(meeting.uuidString)/ai/sessions/1.json").path,
            requestToken: "test", question: "", capturedAt: Date(), audioCutoffSeconds: 1, workAllowed: allowed)
        let envelope = try AIEnvelope(snapshot: snapshot, participant: participant)
        let request = try AIRequest(envelope: envelope, number: 1, voiceQuestion: "ファイルへ追記して", snapshot: snapshot)
        let data = try AIJSON.encode(envelope)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["participant"] as? [String: Any])?["work_allowed"] as? Bool == allowed)
        #expect(try AIJSON.decode(AIEnvelope.self, from: data).participant.workAllowed == allowed)
        #expect(try envelope.prompt(extraPrompt: "").contains("\"work_allowed\" : \(allowed)"))
        var conversation = AIConversation(meetingID: meeting)
        try conversation.append(request)
        #expect(AIMarkdown.section(conversation).contains("- 作業許可: " + (allowed ? "あり" : "なし")))
    }
    @Test func 旧participantは許可ありで読み不正な型は拒否する() throws {
        let value = AIParticipantContext(streamID: UUID(), requestID: UUID(), sessionGeneration: 1,
            participantName: "迅雷", cliPath: "/tmp/helper", sessionPath: "/tmp/session", requestToken: "test",
            question: "質問", capturedAt: Date(), audioCutoffSeconds: 0)
        var json = try #require(JSONSerialization.jsonObject(with: AIJSON.encode(value)) as? [String: Any])
        json.removeValue(forKey: "work_allowed")
        #expect(try AIJSON.decode(AIParticipantContext.self, from: JSONSerialization.data(withJSONObject: json)).workAllowed)
        for invalid: Any in ["false", 0, 1, NSNull()] {
            json["work_allowed"] = invalid
            #expect(throws: (any Error).self) { try AIJSON.decode(AIParticipantContext.self, from: JSONSerialization.data(withJSONObject: json)) }
        }
    }
}
