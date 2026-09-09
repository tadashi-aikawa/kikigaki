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
        cwd = "~/work/minutes"
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
        #expect(profiles[0].cwd.path == "/home/person/work/minutes")
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

    // MARK: - 取り下げた接続案

    /// 稼働中ペインへ接続する案は取り下げた。黙って無視すると、接続するつもりの設定で
    /// 新規起動が始まってしまうので、書かれていたら止める。
    @Test(arguments: ["attach = true", "attach = false", "displayAgent = '迅雷'"])
    func 取り下げた接続の設定を拒否する(_ field: String) throws {
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: "[[ai]]\nname = \"議事録\"\n" + field) }
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: "[ai]\n" + field) }
    }

    @Test func cwdは起動時の作業ディレクトリのまま() throws {
        let profile = try resolved("[[ai]]\nname = \"議事録\"\ncwd = \"~/work/project\"")[0]
        #expect(profile.cwd.path == "/home/person/work/project")
        // 同じcwdのプロファイルが並んでも設定エラーにしない。
        #expect(try resolved("[[ai]]\nname = \"一\"\ncwd = \"~/w\"\n\n[[ai]]\nname = \"二\"\ncwd = \"~/w\"").count == 2)
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

    @Test func 解決した設定の往復で追加した項目を保つ() throws {
        let profile = try resolved("""
        [[ai]]
        name = "議事録"
        cli = "claude"
        effort = "xhigh"
        cwd = "~/work"
        autoStart = true
        autoPrompt = "更新して"
        """)[0]
        let decoded = try AIJSON.decode(ResolvedAIConfig.self, from: AIJSON.encode(profile))
        #expect(decoded == profile)
        #expect(decoded.slot == 1 && decoded.name == "議事録" && decoded.effort == "xhigh")
        #expect(decoded.cwd.path == "/home/person/work" && decoded.autoStart)
    }

    @Test func 新しい項目を持たない旧manifestを既定として読む() throws {
        let legacy = """
        {"cli":"codex","address":"迅雷へ","cwd":"file:///out/","extraArgs":[],"prompt":"",
         "notifySound":false,"hotkey":{"modifiers":["cmd"],"key":"a"}}
        """
        let decoded = try AIJSON.decode(ResolvedAIConfig.self, from: Data(legacy.utf8))
        #expect(decoded.slot == 1 && decoded.name == "迅雷" && decoded.effort == nil)
        #expect(!decoded.autoStart && decoded.allowWork)
        // 取り下げた案の項目が残ったmanifestも、未知のキーとして読み飛ばせる。
        let extra = ",\"attach\":true,\"displayAgent\":\"迅雷\",\"cwdSpecified\":true}"
        let withdrawn = try AIJSON.decode(ResolvedAIConfig.self, from: Data((legacy.dropLast() + extra).utf8))
        #expect(withdrawn.name == "迅雷" && !withdrawn.autoStart)
    }
}
