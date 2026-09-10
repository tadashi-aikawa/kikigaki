import Foundation
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import Kikigaki

@Suite @MainActor struct MinutesRevisionTests {
    private func question(root: URL, meeting: UUID, generation: Int) throws -> AIQuestion {
        var history = try AIStreamHistory(meetingID: meeting, sessionGeneration: generation)
        let snapshot = try history.prepare(lines: [], outputDirectory: root)
        let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: generation,
            participantName: "迅雷", cliPath: "/tmp/helper", sessionPath: root.appendingPathComponent(".kikigaki-context/\(meeting)/ai/sessions/\(generation).json").path,
            requestToken: "test", question: "更新", capturedAt: Date(), audioCutoffSeconds: 0)
        var question = try AIQuestion(request: AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant), number: 1))
        try question.beginSending(at: Date()); return question
    }

    @Test func 設定破損だけでは回収登録せず未適用通知を区別する() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID(), disk = MinutesFileStore(root: root, meetingID: meeting)
        try disk.files.write(Data("broken".utf8), to: disk.parts)
        let store = MinutesStore(meetingID: meeting, outputDirectory: root)
        store.scan(questions: [])
        #expect(store.warning != nil && store.hasSaveFailure && !store.needsRecovery)
        let q = try question(root: root, meeting: meeting, generation: 2)
        let event = try AIMinutesEvent(request: q.request, path: "/tmp/第二世代.md", recordedAt: Date())
        let inbox = Array(disk.parts.dropLast()) + ["inbox", event.filename]
        try disk.files.write(AIJSON.encode(event), to: inbox)
        store.scan(questions: [q]); #expect(!store.needsRecovery)
        try FileManager.default.removeItem(at: disk.parts.reduce(root) { $0.appendingPathComponent($1) })
        store.scan(questions: [q]); #expect(!store.needsRecovery && store.state.minutesPath == "/tmp/第二世代.md")
        try disk.files.write(Data("invalid event".utf8), to: inbox)
        store.scan(questions: [q]); #expect(store.needsRecovery)
    }

    @Test func 競合で操作を最新状態へ再適用し無変更走査では通知しない() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID(), disk = MinutesFileStore(root: root, meetingID: meeting)
        let store = MinutesStore(meetingID: meeting, outputDirectory: root)
        var attempts = 0, changes = 0
        store.onChange = { changes += 1 }
        store.beforeSave = {
            attempts += 1
            if attempts == 1 {
                let previous = try disk.read()
                var next = previous; try next.select("/tmp/先行.md", at: Date(timeIntervalSince1970: 10)); try next.advanceRevision()
                try disk.save(next, replacing: previous)
            }
        }
        try store.select("/tmp/人.md", at: Date(timeIntervalSince1970: 20))
        #expect(attempts == 2 && store.state.revision == 2 && store.state.humanMinutesPath == "/tmp/人.md")
        let before = changes
        store.scan(questions: []); store.scan(questions: [])
        #expect(changes == before)
    }

    @Test func 保存再試行は現在時刻を採り直す() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MinutesStore(meetingID: UUID(), outputDirectory: root)
        store.beforeSave = { throw AIError.unsafeFile }
        #expect(throws: AIError.unsafeFile) { try store.select("/tmp/人.md", at: Date(timeIntervalSince1970: 1)) }
        store.scan(questions: [])
        #expect(store.warning?.contains("再試行") == true)
        store.beforeSave = nil
        let now = Date(); store.retrySelection()
        #expect(try #require(store.state.targetChangedAt) >= now)
    }

    @Test func 未来版と負値とadoptの版ガードを検証する() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = ResolvedAIConfig(config: AIConfig(), home: root)
        let controller = try testAIController(meetingID: UUID(), outputDirectory: root, herdr: AIHerdr(run: { _, _ in throw AIHerdrError.notReady }))
        for revision in [-1, 0, 2] {
            let prepared = AIPreparedSession(profileSlot: config.slot, profileName: config.name, startedAt: Date(), config: config,
                token: "test", contextRoot: root, contextMeetingID: UUID(), connection: .init(workspaceID: "w", paneID: "p", provider: config.cli), launchRevision: revision)
            if revision < 0 { #expect(throws: (any Error).self) { try prepared.validate() } }
            await #expect(throws: AIError.mismatch) { try await controller.adopt(prepared, config: config) }
        }
    }

    @Test func store取得失敗では送信を始めず受信箱欠損は警告する() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let records = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        var config = ResolvedConfig(config: try ConfigLoader.parse(toml: ""), home: root)
        config.ai = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path), home: root)
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config, aiStore: records)
        _ = try records.minutesStores.store(meetingID: session.aiMeetingID, markdownURL: root.appendingPathComponent("other.md"))
        session.submitAI(question: "更新", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"))
        #expect(session.submissionTaskForTesting == nil && session.snapshot.ai?.warning != nil)
        #expect(await fake.commands.isEmpty)
        let controller = try testAIController(meetingID: UUID(), outputDirectory: root, herdr: AIHerdr(run: { try await fake.run($0, $1) }))
        let req = try controller.prepare(lines: [], question: "更新", voiceQuestion: "", capturedAt: Date(), cutoff: 0, tail: nil,
            config: config.ai!, helper: URL(fileURLWithPath: "/bin/echo"))
        try await controller.connect(config: config.ai!, label: "test", executable: URL(fileURLWithPath: "/bin/echo"), arguments: [])
        try await controller.send(req, config: config.ai!)
        let inbox = try AIFileStore(root: root).directory([".kikigaki-context", controller.meetingID.uuidString, "ai", "inbox"])
        try FileManager.default.removeItem(at: inbox)
        controller.scan(); #expect(controller.warning == "受信箱のイベントを検証できません")
    }

    @Test func minutesは回答未読と自動送信待ちを変えない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), records = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        var config = ResolvedConfig(config: try ConfigLoader.parse(toml: ""), home: root)
        config.ai = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path), home: root)
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config, aiStore: records)
        try session.startAISchedule(options: .init(prompt: "更新", sendFinal: false), helper: URL(fileURLWithPath: "/bin/echo"))
        defer { session.stopAISchedule() }
        session.submitAI(question: "更新", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"))
        await session.submissionTaskForTesting?.value
        let controller = try #require(session.aiRecord?.controller), request = try #require(controller.conversation.questions.first?.request)
        let files = AIFileStore(root: root), inbox = [".kikigaki-context", session.aiMeetingID.uuidString, "ai", "inbox"]
        let event = try AIMinutesEvent(request: request, path: "/tmp/通知.md", recordedAt: Date())
        let scheduled = session.snapshot.aiSchedule
        try files.write(AIJSON.encode(event), to: inbox + [event.filename]); controller.scan()
        #expect(controller.conversation.questions[0].state == .submitted && !controller.conversation.questions[0].isUnread)
        #expect(session.snapshot.aiSchedule.nextFire == scheduled.nextFire && session.snapshot.aiSchedule.active == scheduled.active)
        let reply = try AIReceiveEvent(request: request, kind: .answered, recordedAt: Date(), body: "回答")
        try files.write(AIJSON.encode(reply), to: inbox + [reply.filename]); controller.scan()
        #expect(controller.conversation.questions[0].isUnread)
        controller.scan(); #expect(controller.conversation.questions[0].isUnread)
        #expect(session.snapshot.aiSchedule.active == scheduled.active)
    }
}
