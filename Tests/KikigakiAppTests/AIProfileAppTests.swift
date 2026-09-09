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

    @Test func 接続型は既存ペインへ送りworkspaceを作らない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        await fake.setListed([("w9:p1", "w9", "codex", "迅雷", root.path)])
        let list = try profiles(root, toml: """
        [[ai]]
        name = "接続"
        attach = true
        cwd = "\(root.path)"
        displayAgent = "迅雷"
        """)
        let session = session(root, profiles: list, fake: fake)
        try await submit(session, profile: list[0])
        let controller = try #require(session.aiRecord?.controller)
        #expect(controller.connection(slot: 1)?.paneID == "w9:p1")
        #expect(controller.conversation.questions.first?.state == .submitted)
        let commands = await fake.commands.map { Array($0.prefix(2)) }
        #expect(!commands.contains(["workspace", "create"]))
        #expect(!commands.contains(["agent", "start"]))
        #expect(!commands.contains(["pane", "run"]))
        #expect(commands.contains(["agent", "list"]) && commands.contains(["agent", "prompt"]))
        // フックを仕込めないので、返送未確認の補助表示は出さない。
        let question = try #require(controller.conversation.questions.first)
        #expect(!controller.isReturnUnconfirmed(question, now: Date().addingTimeInterval(600)))
        // 準備済みの文脈が目的なので、作り直しは提示しない。
        #expect(throws: (any Error).self) { try controller.newGeneration(slot: 1) }
    }

    @Test(arguments: [0, 2]) func 接続先が一意に決まらなければ送らず新規起動もしない(_ matches: Int) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        await fake.setListed((0..<matches).map { ("w\($0):p1", "w\($0)", "codex", "迅雷", root.path) })
        let list = try profiles(root, toml: "[[ai]]\nname = \"接続\"\nattach = true\ndisplayAgent = \"迅雷\"")
        let session = session(root, profiles: list, fake: fake)
        try await submit(session, profile: list[0])
        let commands = await fake.commands.map { Array($0.prefix(2)) }
        #expect(!commands.contains(["workspace", "create"]))
        #expect(!commands.contains(["agent", "prompt"]))
        let controller = try #require(session.aiRecord?.controller)
        #expect(controller.connection(slot: 1) == nil)
        #expect(controller.conversation.questions.first?.state == .failed)
        #expect(session.snapshot.ai?.warning != nil)
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

    @Test func 稼働中ペインをその場限りの宛先にできる() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        await fake.setListed([("w9:p1", "w9", "codex", "ネオ", root.path)])
        let list = try profiles(root, toml: "[ai]\ncommand = \"/bin/echo\"\ncwd = \"\(root.path)\"")
        let session = session(root, profiles: list, fake: fake)
        let agents = await session.runningAIAgents()
        let candidate = try #require(agents.first)
        let adhoc = try #require(session.addAdHocAIProfile(for: candidate))
        #expect(adhoc.slot == 2 && adhoc.connectsToExistingPane && adhoc.participantName == "ネオ")
        #expect(session.meetingAIProfiles.count == 2)
        // 同じペインを選び直しても増やさない。
        #expect(session.addAdHocAIProfile(for: candidate)?.slot == 2)
        #expect(session.meetingAIProfiles.count == 2)
        session.selectAIProfile(slot: 2)
        #expect(session.aiConfiguration?.slot == 2)
        try await submit(session, profile: session.aiConfiguration)
        let request = try #require(session.aiRecord?.controller.conversation.questions.first?.request)
        #expect(request.envelope.participant.profileSlot == 2)
        #expect(request.envelope.participant.sessionPath.hasSuffix("/ai/sessions/2/1.json"))
        // requestが参照する定義を固定値の記録にも残す。
        let manifest = try #require(session.aiRecord?.manifest)
        #expect(manifest.profiles.contains { $0.slot == 2 && $0.connectsToExistingPane })
    }

    @Test func 宛先ポップアップは候補が2つ以上のときだけ出す() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let picker = AIDestinationPicker()
        picker.update(profiles: [(1, "迅雷")], selected: .profile(slot: 1))
        #expect(picker.isHidden)
        picker.update(profiles: [(1, "議事録"), (2, "相談")], selected: .profile(slot: 2))
        #expect(!picker.isHidden && picker.selected == .profile(slot: 2))
        let agent = AIAgentCandidate(paneID: "w9:p1", workspaceID: "w9", kind: "codex", displayAgent: "ネオ", cwd: "/work")
        picker.update(profiles: [(1, "迅雷")], selected: .profile(slot: 1), agents: [agent])
        #expect(!picker.isHidden)
        #expect(picker.agent(for: "w9:p1")?.displayAgent == "ネオ")
    }
}
