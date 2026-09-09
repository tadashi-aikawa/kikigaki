import AppKit
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import KikigakiCLI
@testable import Kikigaki

/// 準備済みセッションを会議へ引き継ぐ側の検証。台帳そのものは AIPreparedSessionTests。
@Suite(.timeLimit(.minutes(1))) @MainActor struct AIPreparedAppTests {
    private func profiles(_ root: URL, autoStart: Bool = false) throws -> [ResolvedAIConfig] {
        let toml = """
        [[ai]]
        name = "議事録"
        command = "/bin/echo"
        cwd = "\(root.path)"
        address = "迅雷へ"
        autoPrompt = "議事録を更新してください"
        \(autoStart ? "autoStart = true" : "")

        [[ai]]
        name = "相談"
        command = "/bin/echo"
        cwd = "\(root.path)"
        address = "ネオへ"
        """
        return ResolvedConfig(config: try ConfigLoader.parse(toml: toml), home: root).aiProfiles
    }
    /// フックの世代を見るテスト用。Claudeだけが背景処理中を伝える
    private func claudeProfiles(_ root: URL) throws -> [ResolvedAIConfig] {
        ResolvedConfig(config: try ConfigLoader.parse(toml: """
        [[ai]]
        name = "議事録"
        cli = "claude"
        command = "/bin/echo"
        cwd = "\(root.path)"
        address = "迅雷へ"
        """), home: root).aiProfiles
    }
    private func session(_ root: URL, profiles list: [ResolvedAIConfig], fake: FakeHerdr,
                         recordedSamples: Int = 0, markdown: URL? = nil) -> MeetingSession {
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        var config = ResolvedConfig(config: KikigakiConfig(), home: root)
        config.aiProfiles = list
        let session = MeetingSession(testingRecordingAt: markdown ?? root.appendingPathComponent("meeting.md"),
                                     config: config, aiStore: store, recordedSamples: recordedSamples)
        session.automaticHelper = URL(fileURLWithPath: "/bin/echo")
        return session
    }
    /// アプリと同じ配線にする。台帳が変われば表示も作り直し、送信中は準備を起こさない。
    private func store(_ root: URL, fake: FakeHerdr, session: MeetingSession) -> AIPreparedStore {
        let prepared = AIPreparedStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        prepared.load()
        session.preparedStore = prepared
        prepared.onChange = { [weak session] in session?.refreshPrepared() }
        prepared.isSlotBusy = { [weak session] in session?.isAIBusy(slot: $0) ?? false }
        return prepared
    }
    private func prepare(_ store: AIPreparedStore, _ profile: ResolvedAIConfig, root: URL) async {
        await store.prepare(profile: profile, helper: URL(fileURLWithPath: "/bin/echo"), outputDirectory: root)
    }
    private func submit(_ session: MeetingSession, profile: ResolvedAIConfig) async {
        session.submitAI(question: "質問", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"),
                         profile: profile)
        if let task = session.submissionTaskForTesting(slot: profile.slot) { await task.value }
    }

    /// 紐づけシートを出している間に `autoStart` が動くと、選ぶ前の新しいセッションへ1回目が飛ぶ。
    @Test func 紐づけを選ぶまで設定の自動送信を始めない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root, profiles: try profiles(root, autoStart: true), fake: FakeHerdr())
        session.deferAutomaticStart = true
        session.startAutomaticSchedule()
        #expect(!session.snapshot.aiSchedule.active)
        // 選び終えたら、同じ経路でそのまま始まる。
        session.deferAutomaticStart = false
        session.startAutomaticSchedule()
        #expect(session.snapshot.aiSchedule.active)
        session.stopAISchedule()
    }

    /// 引き継いだ準備済みは候補から外れ、閉じた表題へ「どれを使っているか」が出る。
    @Test func 引き継ぐと候補から外れ宛先の表題に出る() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root)
        let session = session(root, profiles: list, fake: fake)
        let prepared = store(root, fake: fake, session: session)
        await prepare(prepared, list[0], root: root)
        #expect(prepared.warning == nil)
        let id = try #require(prepared.unbound.first?.id)

        let before = session.aiDestinationItems
        #expect(before[0].prepared.map(\.id) == [id] && before[0].bound == nil)
        #expect(before[1].prepared.isEmpty)

        #expect(await session.adoptPrepared(id, profile: list[0]))
        let after = session.aiDestinationItems
        #expect(after[0].prepared.isEmpty)
        // 「Kikigaki 議事録抽出 · 13:05起動」。どの準備済みを使っているか閉じたままで判る。
        #expect(after[0].bound?.hasSuffix("起動") == true)
        #expect(prepared.unbound.isEmpty)
    }

    /// 起動に失敗しても、溜まっている準備済みは操作できなければ困る。
    @Test func 警告を出しても一覧は隠さない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let sheet = AIPrepareSheet(profiles: [(slot: 1, name: "議事録")], selected: 1)
        sheet.update(rows: [.init(id: UUID(), label: "議事録 · 13:05起動", reason: nil)], launching: false,
                     warning: "AIセッションを準備できません")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let texts = descendants(sheet.window.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(texts.contains("AIセッションを準備できません"))
        #expect(texts.contains("議事録 · 13:05起動"))
    }

    // MARK: - 確認レビューの指摘

    /// 【高】紐づけ時に1枠だけ登録すると保存パスが平置きになり、送信で全枠が登録された時点で
    /// 参照先が枝つきへ変わって、同梱CLIがsessionを読めなくなる。
    @Test func 紐づけた枠の保存パスは送信後も変わらず実CLIが読める() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root)
        let session = session(root, profiles: list, fake: fake, recordedSamples: 16_000)
        session.setScheduleTranscriptForTesting("架空の会議を始めます")
        let prepared = store(root, fake: fake, session: session)
        await prepare(prepared, list[0], root: root)
        let id = try #require(prepared.unbound.first?.id)
        #expect(await session.adoptPrepared(id, profile: list[0]))

        let controller = try #require(session.aiRecord?.controller)
        let adopted = controller.sessionURL(slot: 1)
        // 複数プロファイルの会議なので、紐づけの時点から枝つきで保存する。
        #expect(adopted.path.hasSuffix("/ai/sessions/1/1.json"))
        #expect(FileManager.default.fileExists(atPath: adopted.path))

        await submit(session, profile: list[0])
        let request = try #require(controller.conversation.questions.first?.request)
        let participant = request.envelope.participant
        // 送信が指すsessionは、紐づけで保存した実体と同じでなければならない。
        #expect(participant.sessionPath == adopted.path)

        // 実CLIで返送する。アプリが書いた保存物をそのまま読めることを確かめる。
        let args = ["--session", participant.sessionPath, "--request", request.id.uuidString,
                    "--token", participant.requestToken]
        _ = try ReturnCommand(["accept"] + args).execute(input: { Data() }, environment: [:])
        _ = try ReturnCommand(["reply"] + args + ["--kind", "answered"])
            .execute(input: { Data("準備済みからの回答".utf8) }, environment: [:])
        controller.scan()
        #expect(controller.invalidInboxFiles.isEmpty)
        #expect(controller.conversation.questions.first?.result?.body == "準備済みからの回答")
    }

    /// 【高】接続確認の待ちを跨いで会議が入れ替わると、次の会議へ紐づけてしまう。
    @Test func 待ちの最中に会議が入れ替わったら紐づけない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root)
        let session = session(root, profiles: list, fake: fake)
        let prepared = store(root, fake: fake, session: session)
        await prepare(prepared, list[0], root: root)
        let id = try #require(prepared.unbound.first?.id)
        let first = session.aiMeetingID
        // 引き継ぎの生存確認の最中に、録音が終わって次の会議が始まる。
        await fake.onCommand { args in
            guard args.first == "agent", args.dropFirst().first == "get" else { return }
            await MainActor.run { session.beginNextMeetingForTesting() }
        }
        let bound = await session.adoptPrepared(id, profile: list[0])
        #expect(!bound)
        #expect(session.aiMeetingID != first)
        // 台帳は未紐づけのまま。次の会議で選び直せる。
        #expect(prepared.unbound.map(\.id) == [id])
        #expect(session.aiDestinationItems[0].bound == nil)
    }

    /// 【中】準備の起動と同じ枠の送信は排他にする。別の枠は止めない。
    @Test func 準備の起動中は同じ枠へ送信できない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root)
        let session = session(root, profiles: list, fake: fake, recordedSamples: 16_000)
        session.setScheduleTranscriptForTesting("架空の会議を始めます")
        let prepared = store(root, fake: fake, session: session)

        // 起動の最中に、同じ枠と別の枠の送信可否を見る。
        let observed = Observed()
        await fake.onCommand { args in
            // 設定が `command` を持つので、起動は `pane run` で走る。
            guard args.first == "pane", args.dropFirst().first == "run" else { return }
            await MainActor.run {
                observed.same = session.snapshot.ai?.canSubmit(slot: 1)
                observed.other = session.snapshot.ai?.canSubmit(slot: 2)
                session.submitAI(question: "質問", full: false, parent: nil,
                                 helper: URL(fileURLWithPath: "/bin/echo"), profile: list[0])
                observed.started = session.isAIBusy(slot: 1)
            }
        }
        await prepare(prepared, list[0], root: root)
        #expect(observed.same == false && observed.other == true)
        // 起動中の送信は始まらない。表示だけでなく経路も止める。
        #expect(observed.started == false)
        #expect(session.aiRecord?.controller.conversation.questions.isEmpty != false)

        // 逆向き。送信が動いている間は同じ枠を起こさない。
        await fake.onCommand { _ in }
        session.submitAI(question: "質問", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"),
                         profile: list[1])
        #expect(session.isAIBusy(slot: 2))
        await prepare(prepared, list[1], root: root)
        #expect(prepared.unbound.allSatisfy { $0.profileSlot == 1 })
        if let task = session.submissionTaskForTesting(slot: 2) { await task.value }
    }

    /// 【中】接続を作り直すと、新しいCLIのフックは本会議へ落ちる。引き継いだ置き場を残さない。
    @Test func 世代を作り直すと引き継いだフックの置き場を捨てる() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root)
        let session = session(root, profiles: list, fake: fake)
        let prepared = store(root, fake: fake, session: session)
        await prepare(prepared, list[0], root: root)
        let id = try #require(prepared.unbound.first?.id)
        let context = try #require(prepared.unbound.first?.contextMeetingID)
        #expect(await session.adoptPrepared(id, profile: list[0]))
        let controller = try #require(session.aiRecord?.controller)
        #expect(controller.hookContextMeetingForTesting(slot: 1) == context)
        try controller.newGeneration(slot: 1)
        #expect(controller.hookContextMeetingForTesting(slot: 1) == nil)
    }

    /// 【中】消えたペインを引き継ぐと枠が塞がり、別の準備済みを選び直せなくなる。
    @Test func 消えたペインは引き継がず枠を塞がない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root)
        let session = session(root, profiles: list, fake: fake)
        let prepared = store(root, fake: fake, session: session)
        await prepare(prepared, list[0], root: root)
        await prepare(prepared, list[0], root: root)
        #expect(prepared.unbound.count == 2)
        let gone = try #require(prepared.unbound.first)
        let alive = try #require(prepared.unbound.last?.id)
        await fake.removePane(try #require(gone.connection?.paneID))

        #expect(await session.adoptPrepared(gone.id, profile: list[0]) == false)
        // 枠は空いたまま。残っている準備済みをそのまま選び直せる。
        #expect(await session.adoptPrepared(alive, profile: list[0]))
        #expect(session.aiDestinationItems[0].bound != nil)
    }

    /// 【中】前の会議で使った準備済みの表示が、次の会議へ残る。
    @Test func 紐づけの表示は次の会議へ持ち越さない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root)
        let session = session(root, profiles: list, fake: fake)
        let prepared = store(root, fake: fake, session: session)
        await prepare(prepared, list[0], root: root)
        let id = try #require(prepared.unbound.first?.id)
        #expect(await session.adoptPrepared(id, profile: list[0]))
        #expect(session.aiDestinationItems[0].bound != nil)
        session.beginNextMeetingForTesting()
        #expect(session.aiDestinationItems[0].bound == nil)
    }

    /// 【高】別の枠の準備済みを選んだのに、送信先が前の枠のままになる。
    @Test func 別の枠の準備済みを選ぶと送信先も移る() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root)
        let session = session(root, profiles: list, fake: fake)
        let prepared = store(root, fake: fake, session: session)
        await prepare(prepared, list[1], root: root)
        let id = try #require(prepared.unbound.first?.id)
        #expect(session.aiConfiguration?.slot == 1)
        #expect(await session.adoptPrepared(id, profile: list[1]))
        // 手動の宛先が移る。自動送信の宛先は触らない。
        #expect(session.aiConfiguration?.slot == 2)
        #expect(session.aiScheduleConfiguration?.slot == 1)
    }

    /// 【中】台帳の保存に失敗した紐づけは、候補から消えたまま再試行できなくなる。
    @Test func 台帳の保存に失敗したら紐づけを公開しない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root)
        let session = session(root, profiles: list, fake: fake)
        let prepared = store(root, fake: fake, session: session)
        await prepare(prepared, list[0], root: root)
        let id = try #require(prepared.unbound.first?.id)
        // 台帳のファイルをディレクトリで塞いで保存を失敗させる。
        let ledgerFile = root.appendingPathComponent("ai-prepared.json")
        try FileManager.default.removeItem(at: ledgerFile)
        try FileManager.default.createDirectory(at: ledgerFile, withIntermediateDirectories: false)
        #expect(await session.adoptPrepared(id, profile: list[0]) == false)
        // 台帳は未紐づけのまま。保存できるようになれば同じ紐づけをやり直せる。
        #expect(prepared.unbound.map(\.id) == [id])
        try FileManager.default.removeItem(at: ledgerFile)
        // 会議側だけ保存が済んでいる状態からのやり直し。同じ紐づけなら通る。
        #expect(await session.adoptPrepared(id, profile: list[0]))
        #expect(prepared.unbound.isEmpty)
    }

    // MARK: - 2巡目の確認レビューの指摘

    /// 【高】紐づけの確定を待っている間に送ると、画面はB・送信はAになる。
    @Test func 紐づけの確定を待つ間は送信させない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root)
        let session = session(root, profiles: list, fake: fake, recordedSamples: 16_000)
        session.setScheduleTranscriptForTesting("架空の会議を始めます")
        let prepared = store(root, fake: fake, session: session)
        await prepare(prepared, list[1], root: root)
        let id = try #require(prepared.unbound.first?.id)

        // 紐づけの生存確認の最中に、その枠へ送ろうとする。
        let observed = Observed()
        await fake.onCommand { args in
            guard args.first == "agent", args.dropFirst().first == "get" else { return }
            await MainActor.run {
                observed.same = session.snapshot.ai?.canSubmit(slot: 2)
                session.submitAI(question: "質問", full: false, parent: nil,
                                 helper: URL(fileURLWithPath: "/bin/echo"), profile: list[1])
                observed.started = session.submissionTaskForTesting(slot: 2) != nil
            }
        }
        #expect(await session.adoptPrepared(id, profile: list[1]))
        // 確定前は送信できない。送信の経路も始まらない。
        #expect(observed.same == false)
        #expect(observed.started == false)
        #expect(session.aiRecord?.controller.conversation.questions.isEmpty != false)
        // 確定したら、選んだ枠へ送れる。
        #expect(session.aiConfiguration?.slot == 2)
        #expect(session.snapshot.ai?.canSubmit(slot: 2) == true)
    }

    /// 【高】引き継ぎに失敗した枠のまま進めると、下ごしらえを持たないAIへ自動送信が飛ぶ。
    @Test func 引き継ぎに失敗したら自動送信を始めない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root, autoStart: true)
        let session = session(root, profiles: list, fake: fake)
        let prepared = store(root, fake: fake, session: session)
        await prepare(prepared, list[0], root: root)
        let gone = try #require(prepared.unbound.first)
        await fake.removePane(try #require(gone.connection?.paneID))
        session.deferAutomaticStart = true

        let failed = await session.applyPreparedSelection([1: gone.id])
        #expect(failed == [1])
        // 保留は解かない。選び直すまで自動送信を始めない。
        #expect(session.deferAutomaticStart)
        #expect(!session.snapshot.aiSchedule.active)

        // 選び直して新規起動にすれば、そこで始まる。
        #expect(await session.applyPreparedSelection([1: nil]).isEmpty)
        #expect(!session.deferAutomaticStart)
        #expect(session.snapshot.aiSchedule.active)
        session.stopAISchedule()
    }

    /// 【中】生存確認でsessionIDが補われると、台帳保存に失敗した紐づけをやり直せない。
    @Test func 接続の識別が補われても紐づけをやり直せる() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        // 実際のherdrはagent sessionを返す。台帳の接続にはまだ入っていない。
        await fake.setSession("codex-thread-1")
        let list = try profiles(root)
        let session = session(root, profiles: list, fake: fake)
        let prepared = store(root, fake: fake, session: session)
        await prepare(prepared, list[0], root: root)
        let id = try #require(prepared.unbound.first?.id)
        #expect(prepared.unbound.first?.connection?.sessionID == nil)

        let ledgerFile = root.appendingPathComponent("ai-prepared.json")
        try FileManager.default.removeItem(at: ledgerFile)
        try FileManager.default.createDirectory(at: ledgerFile, withIntermediateDirectories: false)
        #expect(await session.adoptPrepared(id, profile: list[0]) == false)
        try FileManager.default.removeItem(at: ledgerFile)
        // 会議側の接続にはsessionIDが入っている。台帳の値との差で弾かない。
        #expect(session.aiRecord?.controller.connection(slot: 1)?.sessionID == "codex-thread-1")
        #expect(await session.adoptPrepared(id, profile: list[0]))
        #expect(prepared.unbound.isEmpty)
    }

    /// 【高】保存先を変えると、準備時に許可した返送先と会議の保存先がずれて返送できない。
    @Test func 保存先が変わった準備済みは候補にしない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root)
        // 準備は元の保存先で行い、会議は新しい保存先で始める。
        let moved = root.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let session = session(root, profiles: list, fake: fake, markdown: moved.appendingPathComponent("meeting.md"))
        let prepared = store(root, fake: fake, session: session)
        await prepare(prepared, list[0], root: root)
        let id = try #require(prepared.unbound.first?.id)

        // 候補に出さない。選べないので誤って紐づけられない。
        #expect(session.aiDestinationItems[0].prepared.isEmpty)
        #expect(prepared.stale(for: list[0], contextRoot: moved).map(\.id) == [id])
        // 直接呼んでも断る。
        #expect(await session.adoptPrepared(id, profile: list[0]) == false)
        #expect(prepared.unbound.map(\.id) == [id])
    }

    /// 【中】作り直した枠へ引き継ぐと、準備側の第1世代の通知を捨ててしまう。
    @Test func 世代を作り直した枠でも準備側のフックを読む() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        await fake.setProvider("claude")
        await fake.setSession("claude-session-1")
        let list = try claudeProfiles(root)
        let session = session(root, profiles: list, fake: fake)
        let prepared = store(root, fake: fake, session: session)
        await prepare(prepared, list[0], root: root)
        let first = try #require(prepared.unbound.first)

        // 一度作り直してから引き継ぐ。会議側は第2世代、準備側の通知は第1世代。
        #expect(await session.adoptPrepared(first.id, profile: list[0]))
        let live = try #require(session.aiRecord?.controller)
        try live.newGeneration(slot: 1)
        await prepare(prepared, list[0], root: root)
        let second = try #require(prepared.unbound.first)
        #expect(await session.adoptPrepared(second.id, profile: list[0]))
        #expect(live.generation(slot: 1) == 2)

        // 準備側の置き場へ、第1世代を名乗るStopフックが落ちる。
        let record = AISessionRecord(meetingID: second.contextMeetingID, generation: 1, provider: .claude,
                                     token: second.token)
        let payload = Data("""
        {"hook_event_name":"Stop","session_id":"claude-session-1","background_tasks":[{"status":"running"}]}
        """.utf8)
        let observation = try AIHookObservation(payload: payload, session: record, now: Date())
        try AIFileStore(root: second.contextRoot).write(AIJSON.encode(observation),
            to: [".kikigaki-context", second.contextMeetingID.uuidString, "ai", "inbox", observation.filename],
            replacing: false)
        live.scan()
        #expect(live.hookBackgroundRunningForTesting(slot: 1))
    }

    /// 【中】「取消(録音を始めない)」が保存していた。取り止めた会議は残さない。
    @Test func 取消は録音を保存せず片付ける() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let list = try profiles(root)
        let session = session(root, profiles: list, fake: FakeHerdr())
        let markdown = root.appendingPathComponent("meeting.md")
        let wav = root.appendingPathComponent("meeting.wav")
        // 録音開始が予約したMarkdownとWAVを模す。
        try Data().write(to: markdown)
        try Data([0]).write(to: wav)
        await session.abandon()
        #expect(session.snapshot.state == .idle)
        #expect(!session.snapshot.saved)
        #expect(!FileManager.default.fileExists(atPath: markdown.path))
        #expect(!FileManager.default.fileExists(atPath: wav.path))
    }
}

/// 差し込みの中で見た値を持ち帰る入れ物。
@MainActor final class Observed {
    var same: Bool?
    var other: Bool?
    var started: Bool?
}
