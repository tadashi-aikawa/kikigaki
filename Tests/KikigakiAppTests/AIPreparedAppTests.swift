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

    @Test func 未作成の保存先でも録音前に準備して許可先を作る() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("new/meetings")
        let context = output.appendingPathComponent(".kikigaki-context")
        let fake = FakeHerdr()
        let profile = try profiles(root)[0]
        let prepared = AIPreparedStore(directory: root,
            makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        prepared.load()
        #expect(!FileManager.default.fileExists(atPath: output.path))
        await fake.onCommand { args in
            guard Array(args.prefix(2)) == ["pane", "run"] else { return }
            // 起動時点で実在するディレクトリを許可先に渡す。
            #expect(FileManager.default.fileExists(atPath: context.path))
            #expect(args.contains { $0.contains("sandbox_workspace_write.writable_roots=")
                && $0.contains(context.path) })
        }

        await prepare(prepared, profile, root: output)

        #expect(prepared.warning == nil)
        let entry = try #require(prepared.unbound.first)
        #expect(FileManager.default.fileExists(atPath: entry.sessionURL.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: context.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
        let commands = await fake.commands
        #expect(commands.contains { Array($0.prefix(2)) == ["pane", "run"] })
        let reloaded = AIPreparedStore(directory: root)
        reloaded.load()
        #expect(reloaded.unbound.map(\.id) == [entry.id])
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
        // 録音開始が予約したMarkdownと、実際に書いたWAVを模す。
        try Data().write(to: markdown)
        let writer = try WavWriter(url: wav)
        try writer.write(Array(repeating: 0.1, count: 16_000))
        writer.close()
        #expect((try Data(contentsOf: wav)).count > 44)
        await session.abandon()
        #expect(session.snapshot.state == .idle)
        #expect(!session.snapshot.saved)
        #expect(!FileManager.default.fileExists(atPath: markdown.path))
        #expect(!FileManager.default.fileExists(atPath: wav.path))
    }

    // MARK: - 3巡目の確認レビューの指摘

    /// 【中】取り止めた会議の登録と監視が残り、紐づけ済みの準備済みも使えないままになる。
    @Test func 取消はAIの登録と紐づけも戻す() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root)
        let session = session(root, profiles: list, fake: fake)
        let prepared = store(root, fake: fake, session: session)
        await prepare(prepared, list[0], root: root)
        let id = try #require(prepared.unbound.first?.id)
        #expect(await session.adoptPrepared(id, profile: list[0]))
        let meetingID = session.aiMeetingID
        let aiStore = try #require(session.aiStoreForTesting)
        #expect(aiStore.records[meetingID] != nil)
        try Data().write(to: root.appendingPathComponent("meeting.md"))

        await session.abandon()
        // 登録簿からも外す。残すと再起動時に無いmanifestを回収しようとして失敗する。
        #expect(aiStore.records[meetingID] == nil)
        let entries = try AIJSON.decode([AIRegistration].self, from: AIFileStore(root: root).read(["ai-roots.json"]))
        #expect(!entries.contains { $0.meetingID == meetingID })
        // 紐づけは未紐づけへ戻す。次の録音でまた選べる。
        #expect(prepared.unbound.map(\.id) == [id])
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".kikigaki-context/\(meetingID.uuidString)").path))
    }

    /// 【中】録音中に保存先を再読込すると、取消が元の保存先を片付けなかった。
    @Test func 取消は会議を始めた保存先を片付ける() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let list = try profiles(root)
        let started = root.appendingPathComponent("started", isDirectory: true)
        try FileManager.default.createDirectory(at: started, withIntermediateDirectories: true)
        let fake = FakeHerdr()
        let session = session(root, profiles: list, fake: fake,
                              markdown: started.appendingPathComponent("meeting.md"))
        try Data().write(to: started.appendingPathComponent("meeting.md"))
        // AIの置き場も会議を始めた保存先の下にできる。
        let prepared = store(root, fake: fake, session: session)
        await prepared.prepare(profile: list[0], helper: URL(fileURLWithPath: "/bin/echo"), outputDirectory: started)
        let id = try #require(prepared.unbound.first?.id)
        #expect(await session.adoptPrepared(id, profile: list[0]))
        let context = started.appendingPathComponent(".kikigaki-context")
            .appendingPathComponent(session.aiMeetingID.uuidString)
        #expect(FileManager.default.fileExists(atPath: context.path))

        // 録音中に保存先を変えて再読込する。この会議が書いた場所は変わらない。
        var moved = ResolvedConfig(config: KikigakiConfig(), home: root)
        moved.aiProfiles = list
        moved.outputDir = root.appendingPathComponent("moved", isDirectory: true)
        session.update(config: moved)
        await session.abandon()
        #expect(!FileManager.default.fileExists(atPath: started.appendingPathComponent("meeting.md").path))
        #expect(!FileManager.default.fileExists(atPath: context.path))
    }

    /// 【高】台帳の保存に失敗した後で「新規に起動する」を選ぶと、途中の接続へ送っていた。
    @Test func 新規を選び直したら途中の引き継ぎを手放す() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root, autoStart: true)
        let session = session(root, profiles: list, fake: fake)
        let prepared = store(root, fake: fake, session: session)
        await prepare(prepared, list[0], root: root)
        let id = try #require(prepared.unbound.first?.id)
        session.deferAutomaticStart = true

        // 会議側は保存できたが台帳の保存に失敗する。
        let ledgerFile = root.appendingPathComponent("ai-prepared.json")
        try FileManager.default.removeItem(at: ledgerFile)
        try FileManager.default.createDirectory(at: ledgerFile, withIntermediateDirectories: false)
        #expect(await session.applyPreparedSelection([1: id]) == [1])
        let controller = try #require(session.aiRecord?.controller)
        #expect(controller.connection(slot: 1) != nil)
        try FileManager.default.removeItem(at: ledgerFile)

        // 選び直しで「新規に起動する」。途中の接続を手放してから進む。
        #expect(await session.applyPreparedSelection([1: nil]).isEmpty)
        #expect(controller.connection(slot: 1) == nil)
        #expect(!controller.hasAdopted(slot: 1))
        // 準備済みは未紐づけのまま残る。
        #expect(prepared.unbound.map(\.id) == [id])
        #expect(session.snapshot.aiSchedule.active)
        session.stopAISchedule()
    }

    /// 【高】紐づけに失敗すると、画面はB・送信先はAのままだった。
    @Test func 紐づけに失敗したら表示を送信先へ戻す() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root)
        let session = session(root, profiles: list, fake: fake)
        let prepared = store(root, fake: fake, session: session)
        await prepare(prepared, list[1], root: root)
        let gone = try #require(prepared.unbound.first)
        await fake.removePane(try #require(gone.connection?.paneID))
        #expect(session.aiConfiguration?.slot == 1)

        // シートは「相談」の準備済みを選び、ポップアップだけ先に動いた状態。
        let sheet = AIQuestionSheet(participant: "議事録", parentNumber: nil, draft: "依頼",
            voice: "", range: "対象なし", tentative: false, canSubmit: true)
        sheet.updateDestinations(session.aiDestinationItems, selected: 1, participant: "議事録")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let popup = try #require(descendants(sheet.window.contentView!).compactMap { $0 as? NSPopUpButton }.first)
        // 準備済みの行を選んだ直後の状態。ポップアップだけが先に動いている。
        popup.selectItem(at: try #require(popup.itemArray.firstIndex { $0.title.hasPrefix("準備済み") }))

        #expect(await session.adoptPrepared(gone.id, profile: list[1]) == false)
        // 送信先は元の枠のまま。表示もそこへ戻す。
        #expect(session.aiConfiguration?.slot == 1)
        let restored = try #require(session.aiConfiguration?.slot)
        sheet.restoreDestination(restored, items: session.aiDestinationItems, participant: "議事録")
        #expect(sheet.owningSlot == 1)
        #expect(popup.selectedItem?.title == "議事録")
    }

    /// 【高】紐づけの最中に状態が更新されても、宛先と送信は無効のまま保つ。
    @Test func 紐づけ中はシートの更新でも宛先を戻さない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let sheet = AIQuestionSheet(participant: "議事録", parentNumber: nil, draft: "依頼",
            voice: "", range: "対象なし", tentative: false, canSubmit: true)
        sheet.updateDestinations([.init(slot: 1, name: "議事録"), .init(slot: 2, name: "相談")],
                                 selected: 1, participant: "議事録")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let send = try #require(descendants(sheet.window.contentView!).compactMap { $0 as? NSButton }
            .first { $0.title == "送信 ⏎" })
        let popup = try #require(descendants(sheet.window.contentView!).compactMap { $0 as? NSPopUpButton }.first)

        sheet.setBinding(true, canSubmit: false)
        #expect(!send.isEnabled && !popup.isEnabled)
        // 紐づけの開始で走る通常の更新。ここで戻すと二重に紐づけを始められる。
        sheet.update(progress: nil, canSubmit: true)
        #expect(!send.isEnabled && !popup.isEnabled)
        sheet.setBinding(false, canSubmit: true)
        #expect(send.isEnabled && popup.isEnabled)
    }

    // MARK: - 統合前の確認レビューの指摘

    /// 【中】引き継ぎの観測待ち中に取り止めると、消した置き場をsessionの保存で作り直していた。
    @Test func 取消の後に戻った引き継ぎは置き場を作り直さない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root)
        let session = session(root, profiles: list, fake: fake)
        let prepared = store(root, fake: fake, session: session)
        await prepare(prepared, list[0], root: root)
        let id = try #require(prepared.unbound.first?.id)
        let meetingID = session.aiMeetingID
        try Data().write(to: root.appendingPathComponent("meeting.md"))
        // 会議を作っておく。取消で外す対象にする。
        #expect(await session.adoptPrepared(id, profile: list[0]))
        #expect(prepared.unbound.isEmpty)
        let controller = try #require(session.aiRecord?.controller)
        try controller.releaseAdopted(slot: 1)
        prepared.unbindAll(meetingID: meetingID)

        // 引き継ぎの生存確認の最中に取り止める。
        await fake.onCommand { args in
            guard args.first == "agent", args.dropFirst().first == "get" else { return }
            await MainActor.run { Task { await session.abandon() } }
            try? await Task.sleep(for: .milliseconds(50))
        }
        _ = await session.adoptPrepared(id, profile: list[0])
        let context = root.appendingPathComponent(".kikigaki-context").appendingPathComponent(meetingID.uuidString)
        #expect(!FileManager.default.fileExists(atPath: context.path))
        #expect(!session.hasPendingDiscard)
    }

    /// 【中】続けて取り止めに失敗すると、古い会議が再試行の対象から消えていた。
    @Test func 片付け残しは会議ごとに持ち越す() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root)
        let session = session(root, profiles: list, fake: fake)
        let prepared = store(root, fake: fake, session: session)
        let ledgerFile = root.appendingPathComponent("ai-prepared.json")
        var contexts: [URL] = []

        // 同じアプリのまま、取り止めに失敗する会議を2つ続ける。
        for round in 0..<2 {
            await prepare(prepared, list[0], root: root)
            let id = try #require(prepared.unbound.first?.id)
            #expect(await session.adoptPrepared(id, profile: list[0]))
            contexts.append(root.appendingPathComponent(".kikigaki-context")
                .appendingPathComponent(session.aiMeetingID.uuidString))
            // 台帳を書けなくして取り止めを失敗させる。
            try FileManager.default.removeItem(at: ledgerFile)
            try FileManager.default.createDirectory(at: ledgerFile, withIntermediateDirectories: false)
            await session.abandon()
            #expect(session.hasPendingDiscard)
            try FileManager.default.removeItem(at: ledgerFile)
            // 次の会議は、前の片付けが済まないまま始まる(再試行もこの時点では失敗していた)。
            if round == 0 { session.beginNextMeetingForTesting(recording: true) }
        }
        #expect(contexts.count == 2 && contexts[0] != contexts[1])

        // 書けるようになったら、2会議ぶんとも片付く。古いほうを失っていない。
        #expect(session.retryDiscard())
        #expect(contexts.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(!session.hasPendingDiscard)
    }

    /// 【中】実体を消せなくても取消成功にしていた。「何も残らない」を満たしていない。
    @Test func 実体を消せなければ取消を未完了として残す() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root)
        let session = session(root, profiles: list, fake: fake)
        let prepared = store(root, fake: fake, session: session)
        await prepare(prepared, list[0], root: root)
        let id = try #require(prepared.unbound.first?.id)
        #expect(await session.adoptPrepared(id, profile: list[0]))
        let meetingID = session.aiMeetingID
        let context = root.appendingPathComponent(".kikigaki-context").appendingPathComponent(meetingID.uuidString)
        // 置き場を消せなくする。親ディレクトリから書き込み権限を外す。
        let parent = root.appendingPathComponent(".kikigaki-context")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }

        await session.abandon()
        #expect(FileManager.default.fileExists(atPath: context.path))
        #expect(session.hasPendingDiscard)
        #expect(session.snapshot.message?.contains("片付けられませんでした") == true)

        // 消せるようになれば、同じ経路でやり直せる。
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        #expect(session.retryDiscard())
        #expect(!FileManager.default.fileExists(atPath: context.path))
        #expect(!session.hasPendingDiscard)
    }

    /// 【低】1つのプロファイルでも、紐づけた宛先の表題は出し続ける。
    @Test func 単一プロファイルでも紐づけた表題は隠さない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let picker = AIDestinationPicker()
        picker.update(items: [.init(slot: 1, name: "議事録")], selected: 1)
        #expect(picker.isHidden)
        picker.update(items: [.init(slot: 1, name: "議事録", bound: "Kikigaki 議事録抽出 · 13:05起動")], selected: 1)
        #expect(!picker.isHidden)
    }

    // MARK: - 4巡目の確認レビューの指摘

    /// 【中】記録の後始末に失敗したまま実体を消すと、設計表の「起きない」状態ができる。
    @Test func 記録を片付けられないときは実体を消さない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root)
        let session = session(root, profiles: list, fake: fake)
        let prepared = store(root, fake: fake, session: session)
        await prepare(prepared, list[0], root: root)
        let id = try #require(prepared.unbound.first?.id)
        #expect(await session.adoptPrepared(id, profile: list[0]))
        let meetingID = session.aiMeetingID
        let markdown = root.appendingPathComponent("meeting.md")
        try Data().write(to: markdown)
        // 台帳を書けなくする。紐づけを戻せないまま実体を消してはいけない。
        let ledgerFile = root.appendingPathComponent("ai-prepared.json")
        try FileManager.default.removeItem(at: ledgerFile)
        try FileManager.default.createDirectory(at: ledgerFile, withIntermediateDirectories: false)

        await session.abandon()
        let context = root.appendingPathComponent(".kikigaki-context").appendingPathComponent(meetingID.uuidString)
        #expect(FileManager.default.fileExists(atPath: context.path))
        #expect(FileManager.default.fileExists(atPath: markdown.path))
        #expect(session.snapshot.state == .idle)
        #expect(session.snapshot.message?.contains("片付けられませんでした") == true)

        // 書けるようになれば、同じ操作でやり直せる。
        try FileManager.default.removeItem(at: ledgerFile)
        #expect(session.retryDiscard())
        #expect(!FileManager.default.fileExists(atPath: context.path))
        #expect(prepared.unbound.map(\.id) == [id])
    }

    /// 【中】監視を止めても、走っているpollがawaitから戻って消した場所へ書き直せる。
    @Test func 取り止めた会議へは遅れた観測でも書かない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root)
        let session = session(root, profiles: list, fake: fake)
        let prepared = store(root, fake: fake, session: session)
        await prepare(prepared, list[0], root: root)
        let id = try #require(prepared.unbound.first?.id)
        #expect(await session.adoptPrepared(id, profile: list[0]))
        let controller = try #require(session.aiRecord?.controller)
        let meetingID = session.aiMeetingID
        try Data().write(to: root.appendingPathComponent("meeting.md"))
        await session.abandon()
        let context = root.appendingPathComponent(".kikigaki-context").appendingPathComponent(meetingID.uuidString)
        #expect(!FileManager.default.fileExists(atPath: context.path))

        // 取り止めた後に観測が返ってくる。session IDが補われても書き戻さない。
        await fake.setSession("codex-thread-late")
        try? await controller.refreshConnection(slot: 1)
        #expect(!FileManager.default.fileExists(atPath: context.path))
        #expect(!controller.canSend(slot: 1))
    }

    /// 【中】台帳の保存に失敗した後、同じ枠で別の準備済みへ選び直せなかった。
    @Test func 台帳保存に失敗した枠でも別の準備済みへ移れる() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root)
        let session = session(root, profiles: list, fake: fake)
        let prepared = store(root, fake: fake, session: session)
        await prepare(prepared, list[0], root: root)
        await prepare(prepared, list[0], root: root)
        let first = try #require(prepared.unbound.first?.id)
        let second = try #require(prepared.unbound.last?.id)

        // 1つ目は会議側だけ保存できて、台帳の保存に失敗する。
        let ledgerFile = root.appendingPathComponent("ai-prepared.json")
        try FileManager.default.removeItem(at: ledgerFile)
        try FileManager.default.createDirectory(at: ledgerFile, withIntermediateDirectories: false)
        #expect(await session.adoptPrepared(first, profile: list[0]) == false)
        try FileManager.default.removeItem(at: ledgerFile)

        // 2つ目を選び直せる。1つ目の接続は手放してから移る。
        #expect(await session.adoptPrepared(second, profile: list[0]))
        let controller = try #require(session.aiRecord?.controller)
        #expect(controller.sessionToken(slot: 1) == prepared.ledger.sessions.first { $0.id == second }?.token)
        #expect(prepared.unbound.map(\.id) == [first])
    }

    /// 【高】候補が尽きても、新規起動へ黙って進めず利用者に選ばせる。
    @Test func 候補が尽きた枠でも新規を選ばせる() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let profiles = [(slot: 1, name: "議事録"), (slot: 2, name: "相談")]
        // 録音開始の初回は、候補が無い枠を出さない。
        #expect(AIAttachSheet.choices(profiles: profiles) { _ in [] }.isEmpty)
        // 選び直しは、候補が尽きた枠も残して「新規に起動する」を選ばせる。
        let retry = AIAttachSheet.choices(profiles: profiles, slots: [2], includingEmpty: true) { _ in [] }
        #expect(retry.map(\.slot) == [2] && retry[0].prepared.isEmpty)

        let sheet = AIAttachSheet(choices: retry,
                                  warning: "選んだ準備済みセッションを引き継げませんでした。選び直してください")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let titles = descendants(sheet.window.contentView!).compactMap { ($0 as? NSButton)?.title }
        #expect(titles.contains("新規に起動する"))
        #expect(titles.contains("取消 (録音を始めない)") && titles.contains("開始"))
        // 既定は新規。選んだ結果は「準備済みを使わない」。
        #expect(sheet.selection[2] == UUID?.none)
    }
}

/// 差し込みの中で見た値を持ち帰る入れ物。
@MainActor final class Observed {
    var same: Bool?
    var other: Bool?
    var started: Bool?
}
