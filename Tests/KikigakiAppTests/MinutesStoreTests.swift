import Darwin
import Foundation
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import Kikigaki

@Suite @MainActor struct MinutesStoreTests {
    private func question(root: URL, meeting: UUID, workAllowed: Bool = true) throws -> AIQuestion {
        var history = try AIStreamHistory(meetingID: meeting)
        let snapshot = try history.prepare(lines: [], outputDirectory: root)
        let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: "迅雷", cliPath: "/tmp/helper",
            sessionPath: root.appendingPathComponent(".kikigaki-context/\(meeting.uuidString)/ai/sessions/1.json").path,
            requestToken: "test-token", question: "更新", capturedAt: Date(timeIntervalSince1970: 1), audioCutoffSeconds: 1,
            workAllowed: workAllowed)
        var q = try AIQuestion(request: AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant), number: 1))
        try q.beginSending(at: Date(timeIntervalSince1970: 1))
        return q
    }

    private func publish(_ q: AIQuestion, root: URL, path: String = "/tmp/AI.md", seconds: Double = 30) throws -> AIMinutesEvent {
        let event = try AIMinutesEvent(request: q.request, path: path, recordedAt: Date(timeIntervalSince1970: seconds))
        try AIFileStore(root: root).write(AIJSON.encode(event), to: [".kikigaki-context", q.request.envelope.meetingID.uuidString, "ai", "inbox", event.filename])
        return event
    }

    @Test func AI未使用から同じstoreを共有し古い状態の保存を拒否する() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), markdown = root.appendingPathComponent("meeting.md")
        let stores = MinutesStores(), first = try stores.store(meetingID: id, markdownURL: markdown)
        #expect(first.warning == nil && first.state.minutesPath == nil)
        try first.select("/tmp/人.md", at: Date(timeIntervalSince1970: 20))
        let second = try stores.store(meetingID: id, markdownURL: markdown)
        #expect(first === second)
        let disk = MinutesFileStore(root: root, meetingID: id), old = try disk.read()
        try second.select("/tmp/別.md", at: Date(timeIntervalSince1970: 21))
        var outdated = old; try outdated.select("/tmp/古い.md", at: Date(timeIntervalSince1970: 22)); try outdated.advanceRevision()
        #expect(throws: AIError.conflict) { try disk.save(outdated, replacing: old) }
        #expect(try disk.read().humanMinutesPath == "/tmp/別.md")
        #expect(throws: (any Error).self) { try first.select(markdown.path) }
        #expect(throws: (any Error).self) { try first.select(root.appendingPathComponent("meeting.raw.md").path) }
        // 外から正本を書き換えられていても、会議Markdownを表示・次requestの書き先へ採用しない。
        let valid = try disk.read()
        var invalid = valid; try invalid.select(markdown.path, at: Date()); try invalid.advanceRevision()
        try disk.save(invalid, replacing: valid)
        let restored = MinutesStore(meetingID: id, outputDirectory: root, markdownURL: markdown)
        #expect(restored.warning != nil && restored.state.humanMinutesPath == nil)
        try restored.select("/tmp/回復.md")
        #expect(restored.state.humanMinutesPath == "/tmp/回復.md")
    }

    @Test func 外部の新しいrevisionに人の操作を再適用し通知は書き先を変えない() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), store = MinutesStore(meetingID: id, outputDirectory: root)
        try store.select("/tmp/人.md", at: Date(timeIntervalSince1970: 20))
        let q = try question(root: root, meeting: id)
        let event = try publish(q, root: root)
        let disk = MinutesFileStore(root: root, meetingID: id), previous = try disk.read()
        var next = previous; try next.receive(event, for: q.request); try next.advanceRevision()
        try disk.save(next, replacing: previous)
        try store.select("/tmp/再指定.md", at: Date(timeIntervalSince1970: 40))
        store.scan(questions: [q])
        #expect(store.state.minutesPath == "/tmp/再指定.md" && store.state.lastEvent == event.position)
        #expect(!store.hasUnseenMinutes)
        let other = try question(root: root, meeting: id)
        _ = try publish(other, root: root, path: "/tmp/相談.md", seconds: 50)
        store.scan(questions: [q, other])
        #expect(store.state.minutesPath == "/tmp/相談.md" && store.state.humanMinutesPath == "/tmp/再指定.md")
        #expect(store.hasUnseenMinutes)
        store.isVisible = true
        #expect(!store.hasUnseenMinutes)
    }

    @Test func 古い後着と解除と再起動でも巻き戻らない() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), q = try question(root: root, meeting: id)
        let store = MinutesStore(meetingID: id, outputDirectory: root)
        try store.select(nil, at: Date(timeIntervalSince1970: 40))
        let event = try publish(q, root: root)
        store.scan(questions: [q])
        #expect(store.state.minutesPath == nil && store.state.lastEvent == event.position && !store.hasUnseenMinutes)
        let recovered = MinutesStore(meetingID: id, outputDirectory: root)
        recovered.scan(questions: [q])
        #expect(recovered.state.minutesPath == nil && recovered.state.humanMinutesPath == nil)
        #expect(!recovered.needsRecovery && !recovered.hasUnseenMinutes)
    }

    @Test(arguments: [false, true])
    func 取消や作業許可に関係なく通知だけを回収する(_ cancelled: Bool) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), store = MinutesStore(meetingID: id, outputDirectory: root)
        var q = try question(root: root, meeting: id, workAllowed: false)
        if cancelled { try q.cancel(at: Date(timeIntervalSince1970: 10)) }
        _ = try publish(q, root: root)
        store.scan(questions: [q])
        #expect(!q.contextReceived && q.result == nil)
        #expect(store.state.minutesPath == "/tmp/AI.md" && store.state.humanMinutesPath == nil)
    }

    @Test(arguments: [Data("broken".utf8), Data("{\"schema_version\":99}".utf8)])
    func 壊れた正本は通知で直さず人の指定だけで退避する(_ bytes: Data) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), disk = MinutesFileStore(root: root, meetingID: id)
        try disk.files.write(bytes, to: disk.parts)
        let q = try question(root: root, meeting: id)
        _ = try publish(q, root: root)
        let store = MinutesStore(meetingID: id, outputDirectory: root)
        store.scan(questions: [q])
        #expect(!store.needsRecovery && store.warning != nil && store.state.minutesPath == nil)
        #expect(try disk.files.read(disk.parts) == bytes)
        try store.select("/tmp/回復.md", at: Date(timeIntervalSince1970: 40))
        store.scan(questions: [q])
        #expect(store.state.minutesPath == "/tmp/回復.md" && !store.needsRecovery)
        let directory = try disk.files.directory(Array(disk.parts.dropLast()), create: false)
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("minutes.json.broken-") }
        #expect(backups.count == 1)
        #expect(try disk.files.read(Array(disk.parts.dropLast()) + backups) == bytes)
    }

    @Test func 保存失敗を残して再試行し会議ファイルへの通知は拒否する() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), markdown = root.appendingPathComponent("meeting.md")
        let q = try question(root: root, meeting: id), disk = MinutesFileStore(root: root, meetingID: id)
        _ = try publish(q, root: root)
        let target = disk.parts.reduce(root) { $0.appendingPathComponent($1) }
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: root.appendingPathComponent("absent"))
        let store = MinutesStore(meetingID: id, outputDirectory: root, markdownURL: markdown)
        store.scan(questions: [q])
        #expect(store.hasSaveFailure && !store.hasPendingEvents && store.state.minutesPath == nil)
        #expect(throws: (any Error).self) { try store.select("/tmp/人.md") }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("absent").path))
        try FileManager.default.removeItem(at: target)
        store.retrySelection(); store.scan(questions: [q])
        #expect(!store.needsRecovery && store.state.humanMinutesPath == "/tmp/人.md")
        let invalid = try question(root: root, meeting: id)
        _ = try publish(invalid, root: root, path: markdown.path, seconds: 50)
        store.scan(questions: [q, invalid])
        #expect(!store.hasPendingEvents && store.warning != nil && store.state.minutesPath == "/tmp/人.md")
        #expect(store.state.lastEvent?.eventID == invalid.request.id.uuidString + "/minutes")
        store.scan(questions: [q, invalid])
        #expect(!store.needsRecovery && store.warning == nil)
    }

    @Test func 回答済み会議の壊れた設定は登録簿から外し明示修復後に通知を回収する() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = try testDirectory(); defer { try? FileManager.default.removeItem(at: registry) }
        let fake = FakeHerdr(), config = ResolvedAIConfig(config: AIConfig(), home: root)
        let store = AIRecordStore(directory: registry, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        let id = UUID(), markdown = root.appendingPathComponent("meeting.md")
        let record = try store.begin(meetingID: id, markdownURL: markdown, config: config)
        let shared = try store.minutesStores.store(meetingID: id, markdownURL: markdown)
        #expect(record.controller.minutes === shared)
        let req = try record.controller.prepare(lines: [], question: "更新", voiceQuestion: "", capturedAt: Date(), cutoff: 0,
            tail: nil, config: config, helper: URL(fileURLWithPath: "/tmp/helper"))
        try await record.controller.connect(config: config, label: "test", executable: URL(fileURLWithPath: "/tmp/fake"), arguments: [])
        try await record.controller.send(req, config: config)
        var archive = MeetingArchive(original: .init(startedAt: Date(), duration: 1, utterances: [], names: SpeakerNames()),
            processed: nil, candidateCount: 0, markdownURL: markdown)
        #expect(store.save(&archive, for: id).succeeded)
        let files = AIFileStore(root: root), base = [".kikigaki-context", id.uuidString, "ai"]
        let reply = try AIReceiveEvent(request: req, kind: .answered, recordedAt: Date(), body: "済")
        try files.write(AIJSON.encode(reply), to: base + ["inbox", reply.filename])
        record.controller.scan()
        #expect(!record.needsRecovery)
        let before = try Data(contentsOf: markdown)
        // resultの後からminutesが来ても、次の走査で回収と登録簿更新を行う。
        try files.write(Data("broken".utf8), to: base + ["minutes.json"])
        let event = try AIMinutesEvent(request: req, path: "/tmp/議事録.md", recordedAt: Date())
        try files.write(AIJSON.encode(event), to: base + ["inbox", event.filename])
        #expect(!record.needsRecovery) // 未走査の通知は次の監視走査で判定する。
        record.controller.scan()
        #expect(!record.needsRecovery && record.controller.conversation.questions[0].state == .answered)
        #expect(try Data(contentsOf: markdown) == before)
        #expect(try AIJSON.decode([AIRegistration].self, from: AIFileStore(root: registry).read(["ai-roots.json"])).isEmpty)
        record.controller.stopWatching()
        let restored = AIRecordStore(directory: registry, makeHerdr: { throw AIHerdrError.notReady })
        restored.recover()
        #expect(restored.records[id] == nil)
        try shared.select("/tmp/人.md")
        shared.scan(questions: record.controller.conversation.questions)
        #expect(!record.needsRecovery && shared.state.lastEvent?.eventID == event.position.eventID)
        #expect(try Data(contentsOf: markdown) == before)
    }

    @Test func 起動条件の欠損と旧版を候補から外し新規だけ紐づける() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = ResolvedAIConfig(config: AIConfig(), home: root)
        let fresh = AIPreparedSession(profileSlot: config.slot, profileName: config.name, startedAt: Date(), config: config,
            token: "token", contextRoot: root, contextMeetingID: UUID(), connection: .init(workspaceID: "w", paneID: "p", provider: config.cli))
        for revision: Any? in [nil, 0, 2] {
            var json = try #require(JSONSerialization.jsonObject(with: AIJSON.encode(fresh)) as? [String: Any])
            json["launch_revision"] = revision
            let stale = try AIJSON.decode(AIPreparedSession.self, from: JSONSerialization.data(withJSONObject: json))
            var ledger = AIPreparedLedger(sessions: [stale])
            #expect(!stale.hasCurrentLaunch && ledger.available(for: config, contextRoot: root).isEmpty)
            #expect(ledger.stale(for: config, contextRoot: root).count == 1)
            #expect(throws: (any Error).self) { try ledger.bind(stale.id, to: UUID(), config: config) }
        }
        #expect(fresh.hasCurrentLaunch && AIPreparedLedger(sessions: [fresh]).available(for: config, contextRoot: root).count == 1)
    }

    @Test func 送信入口の人の書き先を固定し通知の表示対象を混ぜない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        var config = ResolvedConfig(config: try ConfigLoader.parse(toml: ""), home: root)
        config.ai = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path), home: root)
        let markdown = root.appendingPathComponent("meeting.md")
        let session = MeetingSession(testingRecordingAt: markdown, config: config, aiStore: store)
        let minutes = try store.minutesStores.store(meetingID: session.aiMeetingID, markdownURL: markdown)
        try minutes.select("/tmp/送信時.md", at: Date(timeIntervalSince1970: 10))
        let q = try question(root: root, meeting: session.aiMeetingID)
        _ = try publish(q, root: root, path: "/tmp/別AI.md", seconds: 20)
        minutes.scan(questions: [q])
        #expect(minutes.state.minutesPath == "/tmp/別AI.md")
        session.submitAI(question: "更新", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"))
        let task = try #require(session.submissionTaskForTesting)
        try minutes.select("/tmp/次回.md")
        await task.value
        let first = try #require(session.aiRecord?.controller.conversation.questions.first)
        #expect(first.request.envelope.participant.minutesPath == "/tmp/送信時.md")
        #expect(minutes.state.humanMinutesPath == "/tmp/次回.md")
        #expect(first.state == .submitted)
    }
}
