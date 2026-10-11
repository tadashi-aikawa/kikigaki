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
        return MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
                              aiStore: store, recordedSamples: 16_000, diarizationEnabled: diarization)
    }
    private func start(_ session: MeetingSession) throws {
        try session.startAISchedule(options: .init(prompt: "議事録を更新", interval: 3600, sendFinal: false),
                                    helper: URL(fileURLWithPath: "/bin/echo"))
    }
    private func publish(_ session: MeetingSession, diarization: Bool, text: String = "しおりを挟んで",
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
    func 速報の確定合図から今すぐ送るの本番経路へ接続し高精度訂正で二重送信しない(diarization: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), session = session(root, fake: fake, diarization: diarization)
        defer { session.stopAISchedule() }
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        try start(session)
        #expect(session.snapshot.canFireAutomatic)
        publish(session, diarization: diarization, final: 0)
        #expect(session.aiRecord == nil && sounds.isEmpty)
        publish(session, diarization: diarization)
        await session.submissionTaskForTesting?.value
        let request = try #require(session.aiRecord?.controller.conversation.questions.first?.request)
        #expect(request.trigger == .scheduled && request.envelope.participant.question == "議事録を更新")
        let transcript = try String(contentsOfFile: request.envelope.transcriptPath, encoding: .utf8)
        #expect(transcript.contains("しおりを挟んで"))
        #expect(await fake.commands.filter { $0.prefix(2) == ["agent", "prompt"] }.count == 1)
        #expect(sounds == [true])
        publish(session, diarization: diarization, text: "栞をはさんで。", accurate: 1)
        #expect(session.aiRecord?.controller.conversation.questions.count == 1 && sounds == [true])
    }
    @Test(arguments: [false, true])
    func 非稼働と空配列は送信も音も出さない(disabled: Bool) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root, fake: FakeHerdr(), phrases: disabled ? [] : nil)
        defer { session.stopAISchedule() }
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        if disabled { try start(session) }
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
    @Test func 無効条件はメニューと同じで低い音だけ鳴らす() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root, fake: FakeHerdr())
        defer { session.stopAISchedule() }
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        try start(session)
        session.beginAIDraft()
        #expect(!session.snapshot.canFireAutomatic)
        publish(session, diarization: true)
        #expect(session.aiRecord == nil && sounds == [false])
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
    @Test func 差分なしの合図は今すぐ送るの判定を通して低い音を鳴らす() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), session = session(root, fake: fake)
        defer { session.stopAISchedule() }
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        session.setScheduleTranscriptForTesting("しおりを挟んで")
        try start(session)
        await session.submissionTaskForTesting?.value
        let controller = try #require(session.aiRecord?.controller)
        let request = try #require(controller.conversation.questions.last?.request)
        let event = try AIReceiveEvent(request: request, kind: .answered, recordedAt: Date(), body: "更新しました")
        try AIFileStore(root: root).write(AIJSON.encode(event), to: [".kikigaki-context", session.aiMeetingID.uuidString,
            "ai", "inbox", request.id.uuidString + ".result.json"], replacing: false)
        controller.scan()
        #expect(session.snapshot.canFireAutomatic)
        session.publishForTesting(tokens: [.init(text: "しおりを挟んで", phraseId: -1, start: 0, end: 0)],
                                  speakers: [nil], elapsed: 1, finalCount: 1, accurateFinalCount: 0)
        #expect(sounds == [false])
        #expect(controller.conversation.questions.count == 1)
        #expect(await fake.commands.filter { $0.prefix(2) == ["agent", "prompt"] }.count == 1)
    }
}
