import Foundation
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import Kikigaki

extension AppKitTests {
@Suite(.timeLimit(.minutes(1))) @MainActor struct AutoSendPhraseAppTests {
    private func session(_ root: URL, fake: FakeHerdr, diarization: Bool = true,
                         phrases: [String]? = nil, profiles: [AIConfig]? = nil) -> MeetingSession {
        var config = ResolvedConfig(config: KikigakiConfig(autoSendPhrases: phrases), home: root)
        config.ai = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path), home: root)
        if let profiles {
            config.aiProfiles = profiles.enumerated().map { index, profile in
                ResolvedAIConfig(config: profile, home: root, slot: index + 1)
            }
        }
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
                                     aiStore: store, recordedSamples: 16_000, diarizationEnabled: diarization)
        session.automaticHelper = URL(fileURLWithPath: "/bin/echo")
        return session
    }
    @Test(arguments: [1, 2, 3], [true, false])
    func 通知は初期宛先と切替先の専用合図か共通合図の設定表記を使う(slot: Int, diarization: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root, fake: FakeHerdr(), diarization: diarization, phrases: ["ｱﾊﾞﾝﾃｨ"], profiles: [
            AIConfig(name: "議事録", command: "/bin/echo", cwd: root.path, autoSendPhrases: ["ＡＶＡＮＴＩ"]),
            AIConfig(name: "相談", command: "/bin/echo", cwd: root.path, autoSendPhrases: ["ｱｳﾞｧﾝﾃｨ"]),
            AIConfig(name: "共通", command: "/bin/echo", cwd: root.path)
        ])
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        var notifications: [VoiceCueFeedback] = []; session.notifyVoiceCue = { notifications.append($0) }
        if slot != 1 { session.setMeetingManualDestination(slot: slot) }
        let recognized = ["AVANTI", "アヴァンティ", "アバンティ"][slot - 1]
        let configured = ["ＡＶＡＮＴＩ", "ｱｳﾞｧﾝﾃｨ", "ｱﾊﾞﾝﾃｨ"][slot - 1]
        let destination = ["議事録", "相談", "共通"][slot - 1]
        publish(session, diarization: diarization, text: recognized)
        await session.pendingUndiarizedDrawForTesting?.value
        #expect(notifications == [.accepted(destination: destination, phrase: configured, appendix: false)])
        #expect(notifications.first?.body == "\(destination)へ送りました（\(configured)）")
        await session.submissionTaskForTesting(slot: slot)?.value
        #expect(session.aiRecord?.controller.conversation.questions.first?.request.envelope.participant.profileSlot == slot)
        #expect(sounds == [true] && notifications.count == 1)
    }
    @Test(arguments: [true, false])
    func 手動宛先の専用合図だけが着火し共通と別宛先の合図は効かない(diarization: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root, fake: FakeHerdr(), diarization: diarization, phrases: ["共通の合図"], profiles: [
            AIConfig(name: "議事録", command: "/bin/echo", cwd: root.path, autoSendPhrases: ["最新に更新してください"]),
            AIConfig(name: "相談", command: "/bin/echo", cwd: root.path, autoSendPhrases: ["相談してください"])
        ])
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        publish(session, diarization: diarization, text: "共通の合図。相談してください", end: 0.3)
        await session.pendingUndiarizedDrawForTesting?.value
        #expect(sounds.isEmpty && session.submissionTaskForTesting == nil)
        publish(session, diarization: diarization, text: "最新に更新してください", start: 0.4, end: 1)
        await session.pendingUndiarizedDrawForTesting?.value
        #expect(sounds == [true])
        await session.submissionTaskForTesting?.value
        #expect(session.aiRecord?.controller.conversation.questions.first?.request.envelope.participant.profileSlot == 1)
    }
    @Test(arguments: [nil, ["共通の合図"]] as [[String]?])
    func 手動宛先の切替で共通へ戻り空配列と指定しないは無効になる(phrases: [String]?) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root, fake: FakeHerdr(), phrases: phrases, profiles: [
            AIConfig(name: "専用", command: "/bin/echo", cwd: root.path, autoSendPhrases: ["最新に更新してください"]),
            AIConfig(name: "共通", command: "/bin/echo", cwd: root.path),
            AIConfig(name: "無効", command: "/bin/echo", cwd: root.path, autoSendPhrases: [])
        ])
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        let phrase = phrases?.first ?? "アバンティ"
        session.setMeetingManualDestination(slot: 3)
        publish(session, diarization: true, text: "無効の確認。" + phrase)
        #expect(sounds.isEmpty && session.submissionTaskForTesting == nil)
        session.setMeetingManualDestination(slot: 1)
        publish(session, diarization: true, text: phrase)
        session.setMeetingManualDestination(slot: 2)
        publish(session, diarization: true, text: phrase)
        #expect(sounds.isEmpty) // 切替前の判定済みの行は再試行しない。
        publish(session, diarization: true, text: "最新に更新してください", start: 0.3, end: 0.5)
        #expect(sounds.isEmpty)
        publish(session, diarization: true, text: phrase, start: 0.6, end: 1)
        await session.submissionTaskForTesting?.value
        #expect(sounds == [true])
        #expect(session.aiRecord?.controller.conversation.questions.first?.request.envelope.participant.profileSlot == 2)
        session.setMeetingManualDestination(slot: 3)
        publish(session, diarization: true, text: phrase, start: 6, end: 7)
        session.setMeetingManualDestination(slot: nil)
        publish(session, diarization: true, text: phrase, start: 8, end: 9)
        #expect(sounds == [true])
    }
    @Test func 手動実行の成功で合図が替わり設定再読込は次の会議へ持ち越す() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let profiles = [
            AIConfig(name: "旧宛先", command: "/bin/echo", cwd: root.path, autoSendPhrases: ["旧合図"]),
            AIConfig(name: "新宛先", command: "/bin/echo", cwd: root.path, autoSendPhrases: ["新合図"])
        ]
        let session = session(root, fake: FakeHerdr(), profiles: profiles)
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        var notifications: [VoiceCueFeedback] = []; session.notifyVoiceCue = { notifications.append($0) }
        session.setScheduleTranscriptForTesting("会議を始めます")
        session.submitAI(question: "依頼", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"),
                         profile: session.meetingAIProfiles[1], updateManualDestination: true)
        #expect(session.meetingManualAI?.slot == 1)
        await session.submissionTaskForTesting?.value
        #expect(session.meetingManualAI?.slot == 2)
        var updatedProfiles = profiles
        updatedProfiles[1].autoSendPhrases = []
        let updated = ResolvedConfig(config: KikigakiConfig(ai: AIProfileList(updatedProfiles)), home: root)
        session.update(config: updated)
        publish(session, diarization: true, text: "旧合図", start: 0.2, end: 0.4)
        #expect(sounds.isEmpty)
        publish(session, diarization: true, text: "新合図", start: 0.5, end: 1)
        await session.submissionTaskForTesting?.value
        #expect(sounds == [true])
        #expect(session.aiRecord?.controller.conversation.questions.first?.appendices.count == 1)
        #expect(notifications == [.accepted(destination: "新宛先", phrase: "新合図", appendix: true)])
        session.beginNextMeetingForTesting(recording: true)
        session.setMeetingManualDestination(slot: 2)
        publish(session, diarization: true, text: "新合図", start: 6, end: 7)
        #expect(sounds == [true])
        #expect(notifications.count == 1)
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
        var notifications: [VoiceCueFeedback] = []; session.notifyVoiceCue = { notifications.append($0) }
        try start(session)
        session.updateManualDraft("手動の下書き", slot: 1)
        let nextFire = session.snapshot.aiSchedule.nextFire
        #expect(session.snapshot.canFireAutomatic)
        publish(session, diarization: diarization, final: 0)
        #expect(session.aiRecord == nil && sounds.isEmpty)
        publish(session, diarization: diarization)
        // MainActorを譲る前、確定待ちや接続開始より先に受付音を返す。
        #expect(sounds == [true])
        #expect(notifications == [.accepted(destination: session.meetingManualAI!.name, phrase: "アバンティ", appendix: false)])
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
        #expect(notifications.count == 1)
    }
    @Test(arguments: [false, true])
    func 指定しないと空配列は送信も音も出さない(disabled: Bool) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root, fake: FakeHerdr(), phrases: disabled ? [] : nil)
        defer { session.stopAISchedule() }
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        var notifications: [VoiceCueFeedback] = []; session.notifyVoiceCue = { notifications.append($0) }
        if disabled { try start(session) } else { session.setMeetingManualDestination(slot: nil) }
        publish(session, diarization: true)
        #expect(session.aiRecord == nil && sounds.isEmpty)
        #expect(notifications.isEmpty)
    }
    @Test func 通知は設定表記を保ち水位と10秒の無視では出さない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root, fake: FakeHerdr(), phrases: ["ＡＶＡＮＴＩ"])
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        var notifications: [VoiceCueFeedback] = []; session.notifyVoiceCue = { notifications.append($0) }
        session.update(config: ResolvedConfig(config: KikigakiConfig(autoSendPhrases: []), home: root))
        publish(session, diarization: true, text: "AVANTI")
        await session.submissionTaskForTesting?.value
        #expect(notifications.first?.body.contains("（ＡＶＡＮＴＩ）") == true)
        publish(session, diarization: true, text: "AVANTI", start: 0.5, end: 1)
        publish(session, diarization: true, text: "AVANTI", start: 1.1, end: 2)
        #expect(notifications.count == 1 && sounds == [true])
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
    func 準備中は低い音で返事待ちは自動の依頼へ追記する(awaiting: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root, fake: FakeHerdr())
        defer { session.stopAISchedule() }
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        var notifications: [VoiceCueFeedback] = []; session.notifyVoiceCue = { notifications.append($0) }
        session.setScheduleTranscriptForTesting("会議を始めます")
        try start(session)
        if awaiting { await session.submissionTaskForTesting?.value }
        #expect(!session.snapshot.canFireAutomatic)
        publish(session, diarization: true)
        await session.submissionTaskForTesting?.value
        #expect(session.aiRecord?.controller.conversation.questions.count == 1)
        #expect(sounds == [awaiting])
        #expect(notifications.count == 1)
        #expect(notifications.first?.accepted == awaiting)
        #expect(notifications.first?.body.contains("追記を送りました") == awaiting)
        let saved = session.aiRecord?.controller.conversation.questions.first
        #expect(saved?.appendices.count == (awaiting ? 1 : 0))
        if awaiting { #expect(saved?.request.trigger == .scheduled) }
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

    @Test func 返事待ちでも接続不可なら合図は低い音だけ返す() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), session = session(root, fake: fake)
        defer { session.stopAISchedule() }
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        session.setScheduleTranscriptForTesting("会議を始めます")
        session.submitAI(question: "作業して", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"))
        await session.submissionTaskForTesting?.value
        await fake.setStatuses(["missing"])
        try? await session.aiRecord?.controller.refreshConnection()
        publish(session, diarization: true)
        #expect(sounds == [false])
        #expect(session.aiRecord?.controller.conversation.questions[0].appendices.isEmpty == true)
    }

    @Test func 合図の受付直後に返事が来ても追記を捨てず新しい依頼へ送る() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root, fake: FakeHerdr())
        defer { session.stopAISchedule(); session.aiRecord?.controller.stopWatching() }
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        session.setScheduleTranscriptForTesting("会議を始めます")
        session.submitAI(question: "作業して", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"))
        await session.submissionTaskForTesting?.value
        let controller = try #require(session.aiRecord?.controller)
        let request = try #require(controller.conversation.questions.first?.request)
        publish(session, diarization: true)
        // 追記のTaskへMainActorを譲る前に、元の依頼の返事が届く。
        let event = try AIReceiveEvent(request: request, kind: .answered, recordedAt: Date(), body: "完了")
        try AIFileStore(root: root).write(AIJSON.encode(event), to: [".kikigaki-context", session.aiMeetingID.uuidString,
            "ai", "inbox", event.filename], replacing: false)
        controller.scan()
        await session.submissionTaskForTesting?.value
        for _ in 0..<200 {
            if !controller.hasPendingAppendices { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sounds == [true])
        #expect(controller.conversation.questions.count == 2 && controller.conversation.questions[0].appendices.count == 1)
        #expect(controller.conversation.questions[0].appendices[0].forwardedRequestID == controller.conversation.questions[1].request.id)
    }

    @Test func 自動非稼働でも設定の手動プロンプトで送信する() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var config = ResolvedConfig(config: KikigakiConfig(), home: root)
        config.ai = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path, initialPrompt: "設定の手動文面"), home: root)
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
        var notifications: [VoiceCueFeedback] = []; session.notifyVoiceCue = { notifications.append($0) }
        publish(session, diarization: true)
        #expect(sounds == [true])
        await session.submissionTaskForTesting?.value
        #expect(sounds == [true, false])
        #expect(notifications.map(\.accepted) == sounds)
        #expect(notifications.last?.body.contains("送れませんでした。送信が中断されました") == true)
    }

    @Test func 送信の入口で議事録の確認に失敗したら低い音だけ鳴らす() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root, fake: FakeHerdr())
        // 同じ会議IDに別の書き先がある場合、本番の入口は非同期処理を始めず拒否する。
        let store = try #require(session.aiStoreForTesting)
        _ = try store.minutesStores.store(meetingID: session.aiMeetingID, markdownURL: root.appendingPathComponent("another.md"))
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        var notifications: [VoiceCueFeedback] = []; session.notifyVoiceCue = { notifications.append($0) }
        publish(session, diarization: true)
        #expect(sounds == [false])
        #expect(notifications.first?.body.contains("送れませんでした。議事録の書き先を確認できません") == true)
        #expect(notifications.count == 1)
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
}
