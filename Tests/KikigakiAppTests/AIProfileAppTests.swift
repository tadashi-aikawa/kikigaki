import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite(.timeLimit(.minutes(1))) @MainActor struct AIProfileAppTests {
    private final class NoAudio: AudioSource {
        func start(onSamples: @escaping ([Float]) -> Void) throws { Issue.record("テストでは音源を起動しない") }
        func stop() {}
    }

    private func profiles(_ root: URL, toml: String) throws -> [ResolvedAIConfig] {
        ResolvedConfig(config: try ConfigLoader.parse(toml: toml), home: root).aiProfiles
    }

    private func session(_ root: URL, profiles: [ResolvedAIConfig], fake: FakeHerdr) -> MeetingSession {
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        var config = ResolvedConfig(config: KikigakiConfig(), home: root)
        config.aiProfiles = profiles
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config, aiStore: store)
        session.automaticHelper = URL(fileURLWithPath: "/bin/echo")
        return session
    }

    /// 非同期の確認が終わるまで待つ。負荷で遅れても落ちないよう、固定の待ち時間にしない。
    private func waitUntil(_ condition: () -> Bool, limit: Int = 200) async throws {
        for _ in 0..<limit {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func submit(_ session: MeetingSession, profile: ResolvedAIConfig?) async throws {
        session.submitAI(question: "質問", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"), profile: profile)
        await (try #require(session.submissionTaskForTesting)).value
    }

    @Test func 手動と自動で別プロファイルへ送りチャネルを分ける() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root, toml: """
        [[ai]]
        name = "議事録"
        command = "/bin/echo"
        cwd = "\(root.path)"
        address = "迅雷へ"

        [[ai]]
        name = "相談"
        command = "/bin/echo"
        cwd = "\(root.path)"
        address = "ネオへ"
        """)
        let session = session(root, profiles: list, fake: fake)
        try await submit(session, profile: list[0])
        try await submit(session, profile: list[1])
        let controller = try #require(session.aiRecord?.controller)
        let questions = controller.conversation.questions
        #expect(questions.count == 2)
        #expect(questions.map(\.request.number) == [1, 2])
        #expect(questions.map(\.request.envelope.participant.participantName) == ["迅雷", "ネオ"])
        #expect(questions.map { $0.request.envelope.participant.profileSlot } == [1, 2])
        // 別チャネルなので、それぞれ独立したstreamと接続先を持つ。
        #expect(questions[0].request.envelope.participant.streamID != questions[1].request.envelope.participant.streamID)
        #expect(controller.connection(slot: 1)?.paneID != nil && controller.connection(slot: 2)?.paneID != nil)
        // 片方が返事待ちでも、もう片方は送れる。
        #expect(!controller.canSend(slot: 1) && !controller.canSend(slot: 2))
        try controller.cancel(questions[0].request.id)
        #expect(controller.canSend(slot: 1) && !controller.canSend(slot: 2))
    }

    @Test func 単一プロファイルでは保存パスを平置きのまま保つ() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root, toml: "[ai]\ncommand = \"/bin/echo\"\ncwd = \"\(root.path)\"")
        let session = session(root, profiles: list, fake: fake)
        try await submit(session, profile: list[0])
        let request = try #require(session.aiRecord?.controller.conversation.questions.first?.request)
        #expect(request.envelope.participant.profileSlot == nil && request.envelope.participant.profile == nil)
        #expect(request.envelope.participant.sessionPath.hasSuffix("/ai/sessions/1.json"))
    }

    @Test func autoStartのプロファイルが録音開始で自動送信を始める() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root, toml: """
        [[ai]]
        name = "相談"
        command = "/bin/echo"
        cwd = "\(root.path)"

        [[ai]]
        name = "議事録"
        command = "/bin/echo"
        cwd = "\(root.path)"
        address = "迅雷へ"
        autoStart = true
        autoPrompt = "議事録を更新してください"
        autoIntervalMinutes = 5
        """)
        let session = session(root, profiles: list, fake: fake)
        session.startAutomaticSchedule()
        #expect(session.snapshot.aiSchedule.active)
        // 自動は2つ目、手動は既定の1つ目のまま。
        #expect(session.aiScheduleConfiguration?.name == "議事録")
        #expect(session.aiConfiguration?.name == "相談")
        #expect(session.lastScheduleOptions?.prompt == "議事録を更新してください")
        #expect(session.lastScheduleOptions?.interval == 300)
        #expect(session.snapshot.aiSchedule.text.contains("議事録へ"))
        session.stopAISchedule()
        #expect(!session.snapshot.aiSchedule.active)
    }

    @Test func 宛先ポップアップは候補が2つ以上のときだけ出す() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let picker = AIDestinationPicker()
        picker.update(items: [.init(slot: 1, name: "迅雷")], selected: 1)
        #expect(picker.isHidden)
        picker.update(items: [.init(slot: 1, name: "議事録"),
                              .init(slot: 2, name: "相談")], selected: 2)
        #expect(!picker.isHidden && picker.selected == 2)
        // 1つしか無くても、準備済みがあるなら選ぶ意味がある。
        picker.update(items: [.init(slot: 1, name: "議事録",
                                    prepared: [.init(id: UUID(), label: "Kikigaki 議事録抽出 · 13:05起動")])], selected: 1)
        #expect(!picker.isHidden)
    }
}
