import Foundation
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import Kikigaki

@Suite(.timeLimit(.minutes(1))) @MainActor struct AutoSendPhraseAppTests {
    private func session(_ root: URL, fake: FakeHerdr, diarization: Bool = true,
                         phrases: [String]? = nil) -> MeetingSession {
        var config = ResolvedConfig(config: KikigakiConfig(autoSendPhrases: phrases), home: root)
        config.ai = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path), home: root)
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
                                     aiStore: store, recordedSamples: 16_000, diarizationEnabled: diarization)
        session.automaticHelper = URL(fileURLWithPath: "/bin/echo")
        return session
    }
    private func start(_ session: MeetingSession) throws {
        try session.startAISchedule(options: .init(prompt: "議事録を更新", interval: 3600, sendFinal: false),
                                    helper: URL(fileURLWithPath: "/bin/echo"))
    }
    private func publish(_ session: MeetingSession, diarization: Bool, text: String = "アバンティ",
                         start: Double = 0, end: Double = 1, final: Int = 1, accurate: Int = 0) {
        let tokens = [TimedToken(text: text, phraseId: accurate == 0 ? -1 : 1, start: start, end: end)]
        if diarization {
            session.publishForTesting(tokens: tokens, speakers: [0], elapsed: end,
                                      finalCount: final, accurateFinalCount: accurate)
        } else {
            session.publishUndiarizedForTesting(.init(tokens: tokens, finalCount: final, accurateFinalCount: accurate), elapsed: end)
        }
    }
    @Test(arguments: [true, false])
    func 速報の確定合図から手動送信の本番経路へ接続し高精度訂正で二重送信しない(diarization: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), session = session(root, fake: fake, diarization: diarization)
        defer { session.stopAISchedule() }
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        try start(session)
        session.updateManualDraft("手動の下書き", slot: 1)
        let nextFire = session.snapshot.aiSchedule.nextFire
        #expect(session.snapshot.canFireAutomatic)
        publish(session, diarization: diarization, final: 0)
        #expect(session.aiRecord == nil && sounds.isEmpty)
        publish(session, diarization: diarization)
        // MainActorを譲る前、確定待ちや接続開始より先に受付音を返す。
        #expect(sounds == [true])
        #expect(session.aiRecord == nil)
        await session.submissionTaskForTesting?.value
        let request = try #require(session.aiRecord?.controller.conversation.questions.first?.request)
        #expect(request.trigger == nil && request.envelope.participant.question == "手動の下書き")
        #expect(session.snapshot.aiSchedule.nextFire == nextFire)
        let transcript = try String(contentsOfFile: request.envelope.transcriptPath, encoding: .utf8)
        #expect(transcript.contains("アバンティ"))
        #expect(await fake.commands.filter { $0.prefix(2) == ["agent", "prompt"] }.count == 1)
        #expect(sounds == [true])
        publish(session, diarization: diarization, text: "アヴァンティ。", accurate: 1)
        #expect(session.aiRecord?.controller.conversation.questions.count == 1 && sounds == [true])
    }
    @Test(arguments: [false, true])
    func 指定しないと空配列は送信も音も出さない(disabled: Bool) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root, fake: FakeHerdr(), phrases: disabled ? [] : nil)
        defer { session.stopAISchedule() }
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        if disabled { try start(session) } else { session.setMeetingManualDestination(slot: nil) }
        publish(session, diarization: true)
        #expect(session.aiRecord == nil && sounds.isEmpty)
    }
    @Test func 設定の再読込は次の会議から反映する() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root, fake: FakeHerdr())
        defer { session.stopAISchedule() }
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        try start(session)
        var updated = ResolvedConfig(config: KikigakiConfig(autoSendPhrases: []), home: root)
        updated.ai = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path), home: root)
        session.update(config: updated)
        publish(session, diarization: true)
        await session.submissionTaskForTesting?.value
        #expect(sounds == [true])
        session.stopAISchedule()
        session.beginNextMeetingForTesting(recording: true)
        try start(session)
        publish(session, diarization: true, start: 4, end: 5)
        #expect(sounds == [true])
    }
    @Test func 手動シートから同じ宛先へ送信中は低い音だけ鳴らす() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root, fake: FakeHerdr())
        defer { session.stopAISchedule() }
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        try start(session)
        session.beginAIDraft()
        session.submitAI(question: "手動シートから", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"))
        #expect(!session.snapshot.canFireAutomatic)
        publish(session, diarization: true)
        #expect(sounds == [false])
        await session.submissionTaskForTesting?.value
        #expect(session.aiRecord?.controller.conversation.questions.count == 1)
        #expect(session.fireAIScheduleNow() == .skipped(.unavailable))
    }
    @Test(arguments: [false, true])
    func 準備中と返事待ちは追加送信せず低い音を鳴らす(awaiting: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root, fake: FakeHerdr())
        defer { session.stopAISchedule() }
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        session.setScheduleTranscriptForTesting("会議を始めます")
        try start(session)
        if awaiting { await session.submissionTaskForTesting?.value }
        #expect(!session.snapshot.canFireAutomatic)
        publish(session, diarization: true)
        await session.submissionTaskForTesting?.value
        #expect(session.aiRecord?.controller.conversation.questions.count == 1)
        #expect(sounds == [false])
    }
    @Test func 差分なしでも手動送信し今すぐ自動送信の判定を使わない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), session = session(root, fake: fake)
        defer { session.stopAISchedule() }
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        session.setScheduleTranscriptForTesting("アバンティ")
        try start(session)
        await session.submissionTaskForTesting?.value
        let controller = try #require(session.aiRecord?.controller)
        let request = try #require(controller.conversation.questions.last?.request)
        let event = try AIReceiveEvent(request: request, kind: .answered, recordedAt: Date(), body: "更新しました")
        try AIFileStore(root: root).write(AIJSON.encode(event), to: [".kikigaki-context", session.aiMeetingID.uuidString,
            "ai", "inbox", request.id.uuidString + ".result.json"], replacing: false)
        controller.scan()
        #expect(session.snapshot.canFireAutomatic)
        session.publishForTesting(tokens: [.init(text: "アバンティ", phraseId: -1, start: 0, end: 0)],
                                  speakers: [nil], elapsed: 1, finalCount: 1, accurateFinalCount: 0)
        await session.submissionTaskForTesting?.value
        #expect(sounds == [true])
        #expect(controller.conversation.questions.count == 2)
        #expect(controller.conversation.questions.last?.request.trigger == nil)
        #expect(await fake.commands.filter { $0.prefix(2) == ["agent", "prompt"] }.count == 2)
    }

    @Test func 自動非稼働でも設定の手動プロンプトで送信する() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var config = ResolvedConfig(config: KikigakiConfig(), home: root)
        config.ai = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path, autoPrompt: "設定の手動文面"), home: root)
        let fake = FakeHerdr()
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config, aiStore: store, recordedSamples: 16_000)
        session.automaticHelper = URL(fileURLWithPath: "/bin/echo")
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        publish(session, diarization: true)
        await session.submissionTaskForTesting?.value
        let request = try #require(session.aiRecord?.controller.conversation.questions.first?.request)
        #expect(!session.snapshot.aiSchedule.active)
        #expect(request.trigger == nil && request.envelope.participant.question == "設定の手動文面")
        #expect(sounds == [true])
    }

    @Test func 受付後の接続失敗は高い音の後に低い音を返す() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var config = ResolvedConfig(config: KikigakiConfig(), home: root)
        config.ai = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path), home: root)
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { _, _ in throw CancellationError() }) })
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config, aiStore: store, recordedSamples: 16_000)
        session.automaticHelper = URL(fileURLWithPath: "/bin/echo")
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        publish(session, diarization: true)
        #expect(sounds == [true])
        await session.submissionTaskForTesting?.value
        #expect(sounds == [true, false])
    }

    @Test func 送信の入口で議事録の確認に失敗したら低い音だけ鳴らす() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root, fake: FakeHerdr())
        // 同じ会議IDに別の書き先がある場合、本番の入口は非同期処理を始めず拒否する。
        let store = try #require(session.aiStoreForTesting)
        _ = try store.minutesStores.store(meetingID: session.aiMeetingID, markdownURL: root.appendingPathComponent("another.md"))
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        publish(session, diarization: true)
        #expect(sounds == [false])
        #expect(session.submissionTaskForTesting == nil && session.aiRecord == nil)
    }

    @Test func 停止後は合図が届いても送信も音も出さない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root, fake: FakeHerdr())
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        await session.stop()
        publish(session, diarization: true)
        #expect(session.aiRecord == nil && sounds.isEmpty)
    }
}
