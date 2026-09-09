import Foundation
import Testing
@testable import KikigakiCore

@Suite struct AIProfilesTests {
    private let home = URL(fileURLWithPath: "/home/person")

    private func resolved(_ toml: String) throws -> [ResolvedAIConfig] {
        ResolvedConfig(config: try ConfigLoader.parse(toml: toml), home: home).aiProfiles
    }

    // MARK: - 配列と単数の読み分け

    @Test func 配列を順に読み1つ目を既定にする() throws {
        let profiles = try resolved("""
        [[ai]]
        name = "議事録"
        cli = "codex"
        address = "迅雷へ"

        [[ai]]
        name = "相談"
        cli = "claude"
        address = "ネオへ"
        """)
        #expect(profiles.map(\.name) == ["議事録", "相談"])
        #expect(profiles.map(\.slot) == [1, 2])
        #expect(profiles[0].cli == .codex && profiles[1].cli == .claude)
        #expect(profiles[1].participantName == "ネオ")
    }

    @Test func 単数の設定を1つのプロファイルとして互換で読む() throws {
        let parsed = try ConfigLoader.parse(toml: "[ai]\naddress = \"迅雷へ\"")
        #expect(parsed.ai?.isArrayForm == false)
        let profiles = try resolved("[ai]\naddress = \"迅雷へ\"")
        #expect(profiles.count == 1 && profiles[0].slot == 1 && profiles[0].name == "迅雷")
    }

    /// docs/ai-profiles.md の設定例をそのまま通す。文書と実装のずれをここで落とす。
    @Test func 文書の設定例を解釈できる() throws {
        let profiles = try resolved("""
        [[ai]]
        name = "議事録"
        cli = "codex"
        model = "gpt-5.4-codex"
        effort = "high"
        address = "迅雷へ"
        attach = true
        cwd = "~/work/minutes"
        displayAgent = "迅雷"
        autoStart = true
        autoPrompt = "会議の決定事項と担当・期限をMarkdown議事録へ更新してください"
        autoIntervalMinutes = 3

        [ai.hotkey]
        modifiers = ["ctrl", "alt", "cmd"]
        key = "a"

        [[ai]]
        name = "相談"
        cli = "claude"
        effort = "max"
        address = "ネオへ"
        """)
        #expect(profiles.count == 2)
        #expect(profiles[0].hotkey == ResolvedAIConfig.defaultHotkey && profiles[1].hotkey == ResolvedAIConfig.defaultHotkey)
        #expect(profiles[0].connectsToExistingPane && !profiles[1].connectsToExistingPane)
        #expect(profiles[0].effortArguments == ["-c", "model_reasoning_effort=\"high\""])
        #expect(profiles[1].effortArguments == ["--effort", "max"])
    }

    @Test func name省略時は宛名から導き重複を拒否する() throws {
        #expect(try resolved("[[ai]]\naddress = \"迅雷へ\"")[0].name == "迅雷")
        #expect(throws: ConfigError.self) {
            try ConfigLoader.parse(toml: "[[ai]]\naddress = \"迅雷へ\"\n\n[[ai]]\naddress = \"迅雷へ\"")
        }
        // 同じ宛名でも name を明示すれば区別できる。
        #expect(try resolved("[[ai]]\nname = \"議事録\"\naddress = \"迅雷へ\"\n\n[[ai]]\nname = \"相談\"\naddress = \"迅雷へ\"").count == 2)
    }

    @Test(arguments: ["name = ''", "name = '   '", "name = \"\"\"\na\nb\"\"\"",
                      "name = '\(String(repeating: "あ", count: 22))'",
                      "displayAgent = ''", "autoStart = true", "effort = ''"])
    func 不正なプロファイル設定を拒否する(_ field: String) throws {
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: "[[ai]]\n" + field) }
    }

    @Test func 空の配列を拒否する() throws {
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: "ai = []") }
    }

    @Test func ホットキーは1つ目のプロファイルにだけ許す() throws {
        let ok = try resolved("""
        [[ai]]
        name = "一"
        [ai.hotkey]
        modifiers = ["cmd", "shift"]
        key = "j"
        """)
        #expect(ok[0].hotkey.key == "j")
        #expect(throws: ConfigError.self) {
            try ConfigLoader.parse(toml: """
            [[ai]]
            name = "一"

            [[ai]]
            name = "二"
            [ai.hotkey]
            modifiers = ["cmd", "shift"]
            key = "j"
            """)
        }
    }

    // MARK: - effort

    @Test func effortをCLIごとの引数へ翻訳する() throws {
        let codex = try resolved("[[ai]]\ncli = \"codex\"\neffort = \"xhigh\"")[0]
        #expect(codex.effortArguments == ["-c", "model_reasoning_effort=\"xhigh\""])
        let claude = try resolved("[[ai]]\ncli = \"claude\"\neffort = \"max\"")[0]
        #expect(claude.effortArguments == ["--effort", "max"])
        #expect(try resolved("[[ai]]\ncli = \"codex\"")[0].effortArguments.isEmpty)
    }

    @Test(arguments: [("codex", "ultra", true), ("codex", "none", true), ("codex", "bogus", false),
                      ("claude", "max", true), ("claude", "ultra", false), ("claude", "minimal", false)])
    func effortの値域をCLIごとに検証する(_ input: (cli: String, effort: String, valid: Bool)) throws {
        let toml = "[[ai]]\ncli = \"\(input.cli)\"\neffort = \"\(input.effort)\""
        if input.valid { #expect(try resolved(toml)[0].effort == input.effort) }
        else { #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: toml) } }
    }

    @Test func extraArgsによるeffortの二重指定を拒否する() throws {
        #expect(throws: ConfigError.self) {
            try ConfigLoader.parse(toml: "[[ai]]\ncli = \"claude\"\nextraArgs = [\"--effort\", \"high\"]")
        }
        #expect(throws: ConfigError.self) {
            try ConfigLoader.parse(toml: "[[ai]]\ncli = \"claude\"\nextraArgs = [\"--effort=high\"]")
        }
    }

    // MARK: - autoStart

    @Test func autoStartは1つまででautoPromptを要る() throws {
        let profiles = try resolved("""
        [[ai]]
        name = "議事録"
        autoStart = true
        autoPrompt = "議事録を更新して"
        autoIntervalMinutes = 5

        [[ai]]
        name = "相談"
        """)
        let auto = try #require(ResolvedConfig(config: try ConfigLoader.parse(toml: """
        [[ai]]
        name = "議事録"
        autoStart = true
        autoPrompt = "議事録を更新して"

        [[ai]]
        name = "相談"
        """), home: home).aiAutoStart)
        #expect(auto.name == "議事録")
        #expect(profiles[0].autoStart && !profiles[1].autoStart && profiles[0].autoIntervalMinutes == 5)
        #expect(throws: ConfigError.self) {
            try ConfigLoader.parse(toml: """
            [[ai]]
            name = "一"
            autoStart = true
            autoPrompt = "a"

            [[ai]]
            name = "二"
            autoStart = true
            autoPrompt = "b"
            """)
        }
    }

    // MARK: - 接続先の解決

    @Test func 接続はattachの宣言が要りcwd単独では新規起動のまま() throws {
        #expect(try resolved("[[ai]]\nname = \"既定\"")[0].connectsToExistingPane == false)
        // 既存の cwd 指定は新規起動の作業ディレクトリのまま。接続型へ化けさせない。
        let launch = try resolved("[[ai]]\nname = \"新規\"\ncwd = \"~/work/project\"")[0]
        #expect(!launch.connectsToExistingPane && launch.criteria == nil)
        #expect(launch.cwd.path == "/home/person/work/project" && launch.cwdSpecified)

        let byCWD = try resolved("[[ai]]\nname = \"接続\"\nattach = true\ncwd = \"~/work\"")[0]
        #expect(byCWD.connectsToExistingPane && byCWD.criteria?.cwd == "/home/person/work")
        #expect(byCWD.criteria?.displayAgent == nil)
        let byName = try resolved("[[ai]]\nname = \"接続\"\nattach = true\ndisplayAgent = \"迅雷\"")[0]
        #expect(byName.connectsToExistingPane && byName.criteria?.displayAgent == "迅雷" && byName.criteria?.cwd == nil)
    }

    @Test func attachに条件が無い設定とattach無しのdisplayAgentを拒否する() throws {
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: "[[ai]]\nname = \"接続\"\nattach = true") }
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: "[[ai]]\nname = \"新規\"\ndisplayAgent = \"迅雷\"") }
    }

    @Test func 同じ条件へ解決する2プロファイルを拒否する() throws {
        #expect(throws: ConfigError.self) {
            try ConfigLoader.parse(toml: """
            [[ai]]
            name = "一"
            attach = true
            cwd = "~/work"
            displayAgent = "迅雷"

            [[ai]]
            name = "二"
            attach = true
            cwd = "~/work"
            displayAgent = "迅雷"
            """)
        }
        // 新規起動のプロファイルは条件を持たないので、同じcwdでいくつ並べても衝突しない。
        #expect(try resolved("[[ai]]\nname = \"一\"\ncwd = \"~/work\"\n\n[[ai]]\nname = \"二\"\ncwd = \"~/work\"").count == 2)
    }

    private func candidate(_ pane: String, kind: String? = "codex", agent: String? = nil, cwd: String? = nil) -> AIAgentCandidate {
        AIAgentCandidate(paneID: pane, workspaceID: String(pane.prefix(3)), kind: kind, displayAgent: agent, cwd: cwd)
    }

    @Test func cwdで絞りdisplayAgentで追加に絞る() throws {
        let candidates = [candidate("w1:p1", agent: "迅雷", cwd: "/work/a"),
                          candidate("w2:p1", agent: "ネオ", cwd: "/work/a"),
                          candidate("w3:p1", agent: "迅雷", cwd: "/work/b")]
        let byBoth = AIAgentResolver.resolve(candidates: candidates,
            criteria: AIAgentCriteria(cwd: "/work/a", displayAgent: "迅雷"), provider: .codex)
        #expect(try byBoth.get().paneID == "w1:p1")
        let byAgentOnly = AIAgentResolver.resolve(candidates: candidates,
            criteria: AIAgentCriteria(cwd: nil, displayAgent: "ネオ"), provider: .codex)
        #expect(try byAgentOnly.get().paneID == "w2:p1")
        let byCWDOnly = AIAgentResolver.resolve(candidates: candidates,
            criteria: AIAgentCriteria(cwd: "/work/b", displayAgent: nil), provider: .codex)
        #expect(try byCWDOnly.get().paneID == "w3:p1")
    }

    @Test func 末尾のスラッシュを吸収して同じcwdとみなす() throws {
        let result = AIAgentResolver.resolve(candidates: [candidate("w1:p1", cwd: "/work/a")],
            criteria: AIAgentCriteria(cwd: "/work/a/", displayAgent: nil), provider: .codex)
        #expect(try result.get().paneID == "w1:p1")
    }

    @Test func 条件なし0件複数件は失敗させ新規起動へ倒さない() throws {
        let candidates = [candidate("w1:p1", agent: "迅雷", cwd: "/work/a"),
                          candidate("w2:p1", agent: "迅雷", cwd: "/work/a")]
        #expect(AIAgentResolver.resolve(candidates: candidates, criteria: nil, provider: .codex)
            == .failure(.noCriteria))
        #expect(AIAgentResolver.resolve(candidates: candidates,
            criteria: AIAgentCriteria(cwd: "/work/none", displayAgent: nil), provider: .codex) == .failure(.notFound))
        #expect(AIAgentResolver.resolve(candidates: candidates,
            criteria: AIAgentCriteria(cwd: "/work/a", displayAgent: "迅雷"), provider: .codex) == .failure(.ambiguous(count: 2)))
    }

    @Test func CLI種別は絞り込みに使わず最後に拒否する() throws {
        // 種別で絞ると、条件が甘いまま偶然1件になった候補へ送ってしまう。
        let candidates = [candidate("w1:p1", kind: "claude", agent: "迅雷", cwd: "/work/a"),
                          candidate("w2:p1", kind: "codex", agent: "ネオ", cwd: "/work/a")]
        #expect(AIAgentResolver.resolve(candidates: candidates,
            criteria: AIAgentCriteria(cwd: "/work/a", displayAgent: nil), provider: .codex) == .failure(.ambiguous(count: 2)))
        #expect(AIAgentResolver.resolve(candidates: candidates,
            criteria: AIAgentCriteria(cwd: nil, displayAgent: "迅雷"), provider: .codex)
            == .failure(.kindMismatch(expected: "codex", found: "claude")))
        #expect(AIAgentResolver.resolve(candidates: [candidate("w1:p1", kind: nil, agent: "迅雷")],
            criteria: AIAgentCriteria(cwd: nil, displayAgent: "迅雷"), provider: .codex)
            == .failure(.kindMismatch(expected: "codex", found: nil)))
    }

    @Test func 同じペインへ解決した重複を数える() throws {
        let panes = [candidate("w1:p1"), candidate("w2:p1"), candidate("w1:p1")]
        #expect(AIAgentResolver.duplicatedPanes(panes) == ["w1:p1"])
        #expect(AIAgentResolver.duplicatedPanes([candidate("w1:p1"), candidate("w2:p1")]).isEmpty)
    }

    // MARK: - envelopeのプロファイル

    private func participant(profile: String?, slot: Int?, generation: Int = 1) -> AIParticipantContext {
        AIParticipantContext(streamID: UUID(), requestID: UUID(), sessionGeneration: generation,
            participantName: "迅雷", cliPath: "/Applications/KIKIGAKI.app/Contents/Helpers/kikigaki-cli",
            sessionPath: "/out/.kikigaki-context/\(Self.meeting.uuidString)/"
                + AIEnvelope.sessionPath(slot: slot, generation: generation),
            requestToken: "token", question: "問い", capturedAt: Date(), audioCutoffSeconds: 1,
            profile: profile, profileSlot: slot)
    }
    private static let meeting = UUID()

    @Test func プロファイル付きのsessionPathは枝を切り旧requestは平置きを保つ() throws {
        #expect(AIEnvelope.sessionPath(slot: nil, generation: 2) == "ai/sessions/2.json")
        #expect(AIEnvelope.sessionPath(slot: 3, generation: 2) == "ai/sessions/3/2.json")
        let withProfile = participant(profile: "議事録", slot: 3)
        #expect(throws: Never.self) { try withProfile.validate() }
        let legacy = participant(profile: nil, slot: nil)
        #expect(throws: Never.self) { try legacy.validate() }
        #expect(legacy.profile == nil && legacy.profileSlot == nil)
    }

    @Test func プロファイル名と番号の片方だけは拒否する() throws {
        #expect(throws: AIError.self) { try participant(profile: "議事録", slot: nil).validate() }
        #expect(throws: AIError.self) { try participant(profile: nil, slot: 3).validate() }
        #expect(throws: AIError.self) { try participant(profile: "議事録", slot: 0).validate() }
        #expect(throws: AIError.self) { try participant(profile: " ", slot: 1).validate() }
    }

    @Test func プロファイル欠損のJSONを既定プロファイルとして読む() throws {
        let encoded = try AIJSON.encode(participant(profile: nil, slot: nil))
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains("profile_slot") && !json.contains("\"profile\""))
        let decoded = try AIJSON.decode(AIParticipantContext.self, from: encoded)
        #expect(decoded.profile == nil && decoded.profileSlot == nil)
    }

    @Test func プロファイル付きのJSONを往復できる() throws {
        let encoded = try AIJSON.encode(participant(profile: "議事録", slot: 2))
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains("\"profile_slot\" : 2") || json.contains("\"profile_slot\":2"))
        let decoded = try AIJSON.decode(AIParticipantContext.self, from: encoded)
        #expect(decoded.profile == "議事録" && decoded.profileSlot == 2)
    }

    // MARK: - manifestの固定値

    @Test func 解決した設定の往復で新しい項目を保つ() throws {
        let profile = try resolved("""
        [[ai]]
        name = "議事録"
        cli = "claude"
        effort = "xhigh"
        attach = true
        cwd = "~/work"
        displayAgent = "迅雷"
        autoStart = true
        autoPrompt = "更新して"
        """)[0]
        let decoded = try AIJSON.decode(ResolvedAIConfig.self, from: AIJSON.encode(profile))
        #expect(decoded == profile)
        #expect(decoded.slot == 1 && decoded.name == "議事録" && decoded.effort == "xhigh")
        #expect(decoded.displayAgent == "迅雷" && decoded.cwdSpecified && decoded.autoStart && decoded.attach)
    }

    @Test func 新しい項目を持たない旧manifestを既定として読む() throws {
        let legacy = """
        {"cli":"codex","address":"迅雷へ","cwd":"file:///out/","extraArgs":[],"prompt":"",
         "notifySound":false,"hotkey":{"modifiers":["cmd"],"key":"a"}}
        """
        let decoded = try AIJSON.decode(ResolvedAIConfig.self, from: Data(legacy.utf8))
        #expect(decoded.slot == 1 && decoded.name == "迅雷" && decoded.effort == nil)
        #expect(decoded.displayAgent == nil && !decoded.cwdSpecified && !decoded.autoStart && !decoded.attach)
        #expect(decoded.connectsToExistingPane == false && decoded.allowWork)
    }
}
