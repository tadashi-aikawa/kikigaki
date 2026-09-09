import AppKit
import Testing
import KikigakiCore
import KikigakiAIIO
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
    private func session(_ root: URL, profiles list: [ResolvedAIConfig], fake: FakeHerdr) -> MeetingSession {
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        var config = ResolvedConfig(config: KikigakiConfig(), home: root)
        config.aiProfiles = list
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
                                     aiStore: store)
        session.automaticHelper = URL(fileURLWithPath: "/bin/echo")
        return session
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
        let prepared = AIPreparedStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        prepared.load()
        session.preparedStore = prepared
        await prepared.prepare(profile: list[0], helper: URL(fileURLWithPath: "/bin/echo"), outputDirectory: root)
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
        sheet.update(rows: [.init(id: UUID(), label: "議事録 · 13:05起動", stale: false)], launching: false,
                     warning: "AIセッションを準備できません")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let texts = descendants(sheet.window.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(texts.contains("AIセッションを準備できません"))
        #expect(texts.contains("議事録 · 13:05起動"))
    }
}
