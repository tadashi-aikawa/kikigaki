import Foundation
import Testing
@testable import KikigakiCore

@Suite struct MinutesTests {
    private func request(meeting: UUID = UUID(), path: String? = nil) throws -> AIRequest {
        var history = try AIStreamHistory(meetingID: meeting)
        let snapshot = try history.prepare(lines: ["[12:00:00] A: 議事録を更新"], outputDirectory: URL(fileURLWithPath: "/tmp"))
        let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: "迅雷", cliPath: "/tmp/helper", sessionPath: "/tmp/.kikigaki-context/\(meeting.uuidString)/ai/sessions/1.json",
            requestToken: "test-token", question: "更新", capturedAt: Date(timeIntervalSince1970: 1), audioCutoffSeconds: 1, minutesPath: path)
        return try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant), number: 1)
    }

    @Test(arguments: ["", "a.md", "~/a.md", "file:///a.md", "/a//b.md", "/a/./b.md", "/a/../b.md", "/a.md/",
                      "/.kikigaki-context/a.md", "/a/.kikigaki-context/b.md", "/a/.KIKIGAKI-CONTEXT/b.md", "/a/.Kikigaki-Context/b.md", "/a.txt", "/a\nb.md", "/a\0.md", "/a\u{2028}.md", "/a\u{200D}.md"])
    func 不正なパスを固定契約で拒否する(_ path: String) {
        #expect(throws: (any Error).self) { try MinutesPath.validate(path) }
    }

    @Test func 日本語と空白と1024バイト境界を保持する() throws {
        for path in ["/tmp/定例 会議.MD", "/tmp/quote'\"$().md", "/a/.kikigaki-context-other/b.md"] { try MinutesPath.validate(path) }
        let maximum = "/" + String(repeating: "a", count: 1020) + ".md"
        #expect(maximum.utf8.count == 1024)
        try MinutesPath.validate(maximum)
        #expect(throws: AIError.tooLarge) { try MinutesPath.validate("/a" + maximum) }
    }

    @Test func envelopeは人のパスを保持し欠損だけを未指定にする() throws {
        let new = try request(path: "/tmp/人の議事録.md")
        #expect(try AIJSON.decode(AIRequest.self, from: AIJSON.encode(new)) == new)
        let old = try request()
        let bytes = try AIJSON.encode(old.envelope.participant)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("minutes_path"))
        #expect(try AIJSON.decode(AIParticipantContext.self, from: bytes).minutesPath == nil)
        for value: Any in [NSNull(), 1, true, "relative.md"] {
            var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            json["minutes_path"] = value
            let invalid = try JSONSerialization.data(withJSONObject: json)
            #expect(throws: (any Error).self) { try AIJSON.decode(AIParticipantContext.self, from: invalid) }
        }
    }

    @Test func 通知は固定requestへ対応し時刻以外で同一性を見る() throws {
        let req = try request()
        let event = try AIMinutesEvent(request: req, path: "/tmp/AI.md", recordedAt: Date(timeIntervalSince1970: 10))
        let retry = try AIMinutesEvent(request: req, path: "/tmp/AI.md", recordedAt: Date(timeIntervalSince1970: 20))
        #expect(event.sameContent(as: retry))
        #expect(!event.sameContent(as: try AIMinutesEvent(request: req, path: "/tmp/ai.md", recordedAt: event.recordedAt)))
        #expect(try AIInbox.decodeMinutes(AIJSON.encode(event), filename: event.filename, for: req) == event)
        #expect(throws: AIError.mismatch) { try event.validate(for: request()) }
        #expect(throws: AIError.mismatch) { try AIInbox.decodeMinutes(AIJSON.encode(event), filename: req.id.uuidString + ".result.json", for: req) }
        #expect(throws: AIError.tooLarge) { try AIInbox.decodeMinutes(Data(repeating: 0, count: AILimits.eventBytes + 1), filename: event.filename, for: req) }
        for (key, value): (String, Any) in [("schema_version", 2), ("kind", "answered"), ("snapshot_id", UUID().uuidString),
                                          ("session_generation", 2), ("minutes_path", NSNull())] {
            var json = try #require(JSONSerialization.jsonObject(with: AIJSON.encode(event)) as? [String: Any])
            json[key] = value
            let invalid = try JSONSerialization.data(withJSONObject: json)
            #expect(throws: (any Error).self) { try AIInbox.decodeMinutes(invalid, filename: event.filename, for: req) }
        }
    }

    @Test func 古い後着通知と解除で巻き戻らずAI通知は書き先へ伝播しない() throws {
        let req = try request(), meeting = req.envelope.meetingID
        var state = MinutesState(meetingID: meeting)
        try state.select("/tmp/人.md", at: Date(timeIntervalSince1970: 20))
        let old = try AIMinutesEvent(request: req, path: "/tmp/古い.md", recordedAt: Date(timeIntervalSince1970: 10))
        #expect(try state.receive(old, for: req))
        #expect(state.minutesPath == "/tmp/人.md" && state.humanMinutesPath == "/tmp/人.md")
        let other = try request(meeting: meeting)
        let fresh = try AIMinutesEvent(request: other, path: "/tmp/相談.md", recordedAt: Date(timeIntervalSince1970: 30))
        try state.receive(fresh, for: other)
        #expect(state.minutesPath == "/tmp/相談.md" && state.humanMinutesPath == "/tmp/人.md")
        try state.select(nil, at: Date(timeIntervalSince1970: 40))
        #expect(try state.receive(old, for: req) == false)
        #expect(state.minutesPath == nil && state.humanMinutesPath == nil && state.targetChangedAt == Date(timeIntervalSince1970: 40))
        try state.advanceRevision()
        #expect(try AIJSON.decode(MinutesState.self, from: AIJSON.encode(state)) == state)
    }

    @Test func 同時刻はID順で到達点を1件だけ保持する() throws {
        let first = try request(), second = try request(meeting: first.envelope.meetingID)
        let date = Date(timeIntervalSince1970: 10)
        let pairs = try [first, second].map { (try AIMinutesEvent(request: $0, path: "/tmp/\($0.id).md", recordedAt: date), $0) }
            .sorted { $0.0.position < $1.0.position }
        var state = MinutesState(meetingID: first.envelope.meetingID)
        try state.receive(pairs[1].0, for: pairs[1].1)
        #expect(try state.receive(pairs[0].0, for: pairs[0].1) == false)
        #expect(state.lastEvent == pairs[1].0.position)
        #expect(state.minutesPath == pairs[1].0.minutesPath && state.humanMinutesPath == nil)
    }

    @Test func 壊れた状態と未知版を空状態へ読み替えない() throws {
        let state = MinutesState(meetingID: UUID())
        for (key, value): (String, Any) in [("schema_version", 2), ("revision", -1), ("minutes_path", "/tmp/a.md"), ("last_event", NSNull())] {
            var json = try #require(JSONSerialization.jsonObject(with: AIJSON.encode(state)) as? [String: Any])
            json[key] = value
            let invalid = try JSONSerialization.data(withJSONObject: json)
            #expect(throws: (any Error).self) { try AIJSON.decode(MinutesState.self, from: invalid) }
        }
    }
}
