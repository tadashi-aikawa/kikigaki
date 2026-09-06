import Foundation
import Testing
@testable import Kikigaki
import KikigakiCore

@Suite @MainActor struct AIConversationControllerTests {
    private func prepare(_ controller: AIConversationController, _ config: ResolvedAIConfig, lines: [String] = ["[12:00:00] A: 会話"]) throws -> AIRequest {
        try controller.prepare(lines: lines, question: "質問", voiceQuestion: "", capturedAt: Date(), cutoff: 1,
            tail: nil, config: config, helper: URL(fileURLWithPath: "/tmp/helper"))
    }
    @Test func 接続情報を排他保存し状態を見て起動を待つ() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), meeting = UUID(), config = ResolvedAIConfig(config: AIConfig(), home: root)
        await fake.setStatuses(["unknown", "working", "idle"])
        let controller = try AIConversationController(meetingID: meeting, outputDirectory: root, herdr: AIHerdr(run: { try await fake.run($0, $1) }))
        let request = try prepare(controller, config)
        #expect(!FileManager.default.fileExists(atPath: request.envelope.participant.sessionPath))
        try await controller.connect(config: config, label: "会議", executable: URL(fileURLWithPath: "/tmp/codex"), arguments: [], readinessTimeout: 2)
        let bytes = try AIFileStore(root: root).read([".kikigaki-context", meeting.uuidString, "ai", "sessions", "1.json"])
        let session = try AIJSON.decode(AISessionRecord.self, from: bytes)
        #expect(session.schemaVersion == 1 && session.provider == .codex && session.connection?.paneID == "p")
        #expect(!session.token.isEmpty)
        #expect(controller.connectionStatus == .idle)
        #expect(await fake.commands.filter { $0.prefix(2) == ["agent", "get"] }.count == 3)
        try await controller.send(request, config: config)
        #expect(controller.conversation.questions[0].state == .submitted)
    }
    @Test func 期限後の再確認は同じ接続を使い再起動しない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), config = ResolvedAIConfig(config: AIConfig(), home: root)
        await fake.setStatuses(["unknown"])
        let controller = try AIConversationController(meetingID: UUID(), outputDirectory: root, herdr: AIHerdr(run: { try await fake.run($0, $1) }))
        _ = try prepare(controller, config)
        await #expect(throws: AIProcessError.timeout) {
            try await controller.connect(config: config, label: "会議", executable: URL(fileURLWithPath: "/tmp/codex"), arguments: [], readinessTimeout: 0.02)
        }
        #expect(controller.connection != nil)
        await fake.setStatuses(["idle"])
        try await controller.connect(config: config, label: "会議", executable: URL(fileURLWithPath: "/tmp/codex"), arguments: [])
        #expect(await fake.commands.filter { $0.prefix(2) == ["workspace", "create"] }.count == 1)
        #expect(await fake.commands.filter { $0.prefix(2) == ["agent", "start"] }.count == 1)
    }
    @Test func 送信試行を先に保存し遅延回答と二重回収を扱う() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID(), store = AIFileStore(root: root), fake = FakeHerdr()
        let base = [".kikigaki-context", meeting.uuidString, "ai"]
        await fake.failPrompt {
            let state = try AIJSON.decode(AIConversation.self, from: store.read(base + ["state.json"]))
            #expect(state.questions[0].state == .deliveryUnknown)
        }
        let herdr = AIHerdr(run: { try await fake.run($0, $1) })
        let controller = try AIConversationController(meetingID: meeting, outputDirectory: root, herdr: herdr)
        let config = ResolvedAIConfig(config: AIConfig(), home: root)
        let request = try prepare(controller, config)
        try await controller.connect(config: config, label: "検証", executable: URL(fileURLWithPath: "/tmp/codex"), arguments: [])
        await #expect(throws: AIProcessError.timeout) { try await controller.send(request, config: config) }
        #expect(controller.conversation.questions[0].state == .deliveryUnknown)
        var results = 0
        controller.onResult = { results += 1 }
        let event = try AIReceiveEvent(request: request, kind: .answered, recordedAt: Date(), body: "遅延回答")
        try store.write(AIJSON.encode(event), to: base + ["inbox", event.filename], replacing: false)
        controller.scan(); controller.scan()
        #expect(results == 1)
        #expect(controller.warning == nil)
        #expect(controller.conversation.questions[0].result?.body == "遅延回答")
        let next = try prepare(controller, config, lines: ["[12:00:00] A: 会話", "[12:00:01] A: 続き"])
        #expect(next.envelope.kind == .update)
        #expect(next.envelope.readStartLine == 2)
        try controller.cancel(next.id)
        let state = try AIJSON.decode(AIConversation.self, from: store.read(base + ["state.json"]))
        let recovered = try AIConversationController(meetingID: meeting, outputDirectory: root, herdr: herdr, recovered: state)
        recovered.scan()
        #expect(recovered.conversation == state)
        #expect(!recovered.canSend && recovered.connection == nil)
        #expect(throws: AIHerdrError.notReady) { try prepare(recovered, config) }
        try recovered.markRead(request.id)
        #expect(!recovered.conversation.questions[0].isUnread)
    }
    @Test func 回答は質問順でなく保存時刻順に取り込む() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID(), fake = FakeHerdr(), config = ResolvedAIConfig(config: AIConfig(), home: root)
        let controller = try AIConversationController(meetingID: meeting, outputDirectory: root, herdr: AIHerdr(run: { try await fake.run($0, $1) }))
        let first = try prepare(controller, config)
        try await controller.connect(config: config, label: "会議", executable: URL(fileURLWithPath: "/tmp/codex"), arguments: [])
        try await controller.send(first, config: config)
        try controller.cancel(first.id)
        let second = try prepare(controller, config)
        try await controller.send(second, config: config)
        let store = AIFileStore(root: root), base = [".kikigaki-context", meeting.uuidString, "ai", "inbox"]
        for (request, time) in [(first, 20.0), (second, 10.0)] {
            let event = try AIReceiveEvent(request: request, kind: .answered, recordedAt: Date(timeIntervalSince1970: time), body: "回答")
            try store.write(AIJSON.encode(event), to: base + [event.filename], replacing: false)
        }
        controller.scan()
        #expect(controller.conversation.questions[1].resultOrder! < controller.conversation.questions[0].resultOrder!)
        try controller.newGeneration()
        let third = try prepare(controller, config)
        #expect(third.envelope.participant.sessionGeneration == 2)
        #expect(third.envelope.participant.streamID != first.envelope.participant.streamID)
        #expect(third.envelope.kind == .full)
    }
    @Test func 既存の世代ファイルを上書きせず接続を公開しない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID(), fake = FakeHerdr(), config = ResolvedAIConfig(config: AIConfig(), home: root)
        let controller = try AIConversationController(meetingID: meeting, outputDirectory: root, herdr: AIHerdr(run: { try await fake.run($0, $1) }))
        _ = try prepare(controller, config)
        let store = AIFileStore(root: root), path = [".kikigaki-context", meeting.uuidString, "ai", "sessions", "1.json"]
        try store.write(Data("既存".utf8), to: path, replacing: false)
        await #expect(throws: AIError.conflict) {
            try await controller.connect(config: config, label: "会議", executable: URL(fileURLWithPath: "/tmp/codex"), arguments: [])
        }
        #expect(controller.connection == nil)
        #expect(try store.read(path) == Data("既存".utf8))
        #expect(await fake.commands.filter { $0.prefix(2) == ["agent", "start"] }.isEmpty)
    }
}
