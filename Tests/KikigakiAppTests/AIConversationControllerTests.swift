import Foundation
import Testing
@testable import Kikigaki
import KikigakiCore
import KikigakiAIIO

@Suite @MainActor struct AIConversationControllerTests {
    @MainActor private final class CancelOnObserve {
        var action: (() throws -> Void)?
        func run() throws { try action?() }
    }
    @Test(arguments: [1, 2]) func 生存確認の応答待ち中の取消を送信前に検出する(cancelAt: Int) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), hook = CancelOnObserve(), config = ResolvedAIConfig(config: AIConfig(), home: root)
        let adapter = AIHerdr(run: { args, timeout in
            if args.prefix(2) == ["agent", "get"] { try await hook.run() }
            return try await fake.run(args, timeout)
        })
        let controller = try AIConversationController(meetingID: UUID(), outputDirectory: root, herdr: adapter)
        let request = try prepare(controller, config)
        try await controller.connect(config: config, label: "test", executable: URL(fileURLWithPath: "/tmp/fake"), arguments: [])
        var observations = 0
        hook.action = { observations += 1; if observations == cancelAt { try controller.cancel(request.id) } }
        await #expect(throws: AIError.invalidTransition) { try await controller.send(request, config: config) }
        #expect(controller.conversation.questions[0].state == .cancelled)
        #expect(await fake.commands.filter { $0.prefix(2) == ["agent", "prompt"] }.isEmpty)
    }
    private func prepare(_ controller: AIConversationController, _ config: ResolvedAIConfig, lines: [String] = ["[12:00:00] A: 会話"]) throws -> AIRequest {
        try controller.prepare(lines: lines, question: "質問", voiceQuestion: "", capturedAt: Date(), cutoff: 1,
            tail: nil, config: config, helper: URL(fileURLWithPath: "/tmp/helper"))
    }
    @Test(arguments: [false, true]) func 開発用の次問は失敗や取消で送信不可でも旧問を再送せず進む(cancelled: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), config = ResolvedAIConfig(config: AIConfig(), home: root)
        let controller = try AIConversationController(meetingID: UUID(), outputDirectory: root, herdr: AIHerdr(run: { try await fake.run($0, $1) }))
        let first = try prepare(controller, config)
        if cancelled {
            try await controller.connect(config: config, label: "test", executable: URL(fileURLWithPath: "/tmp/fake"), arguments: [])
            try await controller.send(first, config: config)
            await fake.setStatuses(["working"]); try await controller.refreshConnection()
            try controller.cancel(first.id)
        } else {
            await fake.rejectNextStart()
            await #expect(throws: AIHerdrError.server("invalid_agent_name")) {
                try await controller.connect(config: config, label: "test", executable: URL(fileURLWithPath: "/tmp/fake"), arguments: [])
            }
            try controller.fail(first.id, reason: "入力前に停止しました")
        }
        #expect(!controller.canSend)
        try ReplayDebugOptions.recoverForNextQuestion(controller, preparing: true)
        #expect(controller.generation == 1)
        try ReplayDebugOptions.recoverForNextQuestion(controller, preparing: false)
        #expect(controller.generation == 2 && controller.canSend)
        let second = try prepare(controller, config)
        await fake.setStatuses(["idle"])
        try await controller.connect(config: config, label: "test", executable: URL(fileURLWithPath: "/tmp/fake"), arguments: [])
        try await controller.send(second, config: config)
        #expect(controller.conversation.questions[0].state == (cancelled ? .cancelled : .failed))
        #expect(controller.conversation.questions[1].state == .submitted)
        let starts = await fake.commands.filter { $0.prefix(2) == ["agent", "start"] }
        #expect(starts.last?[2].hasSuffix("-g2") == true)
        #expect(starts.allSatisfy { $0[2].utf8.count <= 32 })
        #expect(await fake.commands.filter { $0.prefix(2) == ["agent", "prompt"] }.count == (cancelled ? 2 : 1))
    }
    @Test func Claude背景処理の観測中は返送未確認を出さず別sessionを混ぜない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(); await fake.setProvider("claude"); await fake.setSession("main")
        let config = ResolvedAIConfig(config: AIConfig(cli: .claude), home: root)
        let controller = try AIConversationController(meetingID: UUID(), outputDirectory: root, herdr: AIHerdr(run: { try await fake.run($0, $1) }))
        let request = try prepare(controller, config)
        try await controller.connect(config: config, label: "test", executable: URL(fileURLWithPath: "/tmp/fake"), arguments: [])
        try await controller.send(request, config: config)
        let base = [".kikigaki-context", controller.meetingID.uuidString, "ai"]
        let files = AIFileStore(root: root)
        let session = try AIJSON.decode(AISessionRecord.self, from: files.read(base + ["sessions", "1.json"]))
        let now = Date()
        #expect(controller.isReturnUnconfirmed(controller.conversation.questions[0], now: now.addingTimeInterval(10)))
        for (id, running, offset) in [("main", true, 0.0), ("other", false, 1.0), ("main", false, 2.0)] {
            let payload = Data("{\"hook_event_name\":\"Stop\",\"session_id\":\"\(id)\",\"prompt_id\":\"p\",\"background_tasks\":[{\"status\":\"\(running ? "running" : "completed")\"}]}".utf8)
            let observation = try AIHookObservation(payload: payload, session: session, now: now.addingTimeInterval(offset))
            try files.write(AIJSON.encode(observation), to: base + ["inbox", observation.filename], replacing: false)
            controller.scan()
            #expect(controller.isReturnUnconfirmed(controller.conversation.questions[0], now: now.addingTimeInterval(10)) == (offset == 2))
        }
    }
    @Test func 起動直後の未検知は切断とせず入力可能になるまで待つ() async throws {
        // 実測: command指定の pane run 直後は agent get が agent_not_found を返し、初回の質問だけ失敗していた
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), config = ResolvedAIConfig(config: AIConfig(command: "/tmp/codex"), home: root)
        await fake.setStatuses(["missing", "missing", "unknown", "idle"])
        let controller = try AIConversationController(meetingID: UUID(), outputDirectory: root, herdr: AIHerdr(run: { try await fake.run($0, $1) }))
        let request = try prepare(controller, config)
        try await controller.connect(config: config, label: "会議", executable: URL(fileURLWithPath: "/tmp/codex"), arguments: [], readinessTimeout: 2)
        #expect(controller.connectionStatus == .idle)
        #expect(await fake.commands.filter { $0.prefix(2) == ["pane", "run"] }.count == 1)
        try await controller.send(request, config: config)
        #expect(controller.conversation.questions[0].state == .submitted)
        // 起動後の通常の監視では未検知は切断のまま
        await fake.setStatuses(["missing"])
        await #expect(throws: AIHerdrError.missing) { try await controller.refreshConnection() }
        #expect(controller.connectionStatus == .disconnected)
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
