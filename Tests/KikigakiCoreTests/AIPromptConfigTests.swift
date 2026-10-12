import Foundation
import Testing
@testable import KikigakiCore

@Suite struct AIPromptConfigTests {
    private let home = URL(fileURLWithPath: "/tmp/prompt-config-tests")

    @Test func 新しいキーは毎回の指示と初期文面を別々に読む() throws {
        let source = try ConfigLoader.parse(toml: """
        [[ai]]
        alwaysPrompt = "必ず日本語で返してください"
        initialPrompt = "決定事項を更新してください"
        autoStart = true
        """)
        let profile = try #require(ResolvedConfig(config: source, home: home).ai)
        #expect(profile.alwaysPrompt == "必ず日本語で返してください")
        #expect(profile.initialPrompt == "決定事項を更新してください")
        #expect(profile.scheduledPrompt == profile.initialPrompt)
        let empty = try #require(ResolvedConfig(config: ConfigLoader.parse(toml: "[[ai]]"), home: home).ai)
        #expect(empty.alwaysPrompt.isEmpty && empty.initialPrompt.isEmpty)
        // boardでは手動の初期文面を残し、自動だけ既存の内蔵プロンプトを使う。
        let board = ResolvedAIConfig(config: AIConfig(initialPrompt: "議事録を更新", autoStart: true, board: "## ボード"), home: home)
        #expect(board.initialPrompt == "議事録を更新" && board.scheduledPrompt == BoardPrompt.builtIn)
    }

    @Test(arguments: [("prompt", "alwaysPrompt"), ("autoPrompt", "initialPrompt")])
    func 旧キーは空や型違いでも移行先を示して拒否する(old: String, new: String) throws {
        for value in ["'指示'", "''", "3"] {
            let toml = "[[ai]]\n\(old) = \(value)"
            #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: toml) }
            do { _ = try ConfigLoader.parse(toml: toml) }
            catch let ConfigError.invalid(description) {
                #expect(description.contains("\(old) は \(new) に名前が変わりました"))
            }
        }
    }

    @Test(arguments: [("prompt", "alwaysPrompt"), ("autoPrompt", "initialPrompt")])
    func 新旧両方を書いても旧キーを拒否する(old: String, new: String) throws {
        let toml = "[[ai]]\n\(old) = '旧文面'\n\(new) = '新文面'"
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: toml) }
        do { _ = try ConfigLoader.parse(toml: toml) }
        catch let ConfigError.invalid(description) {
            #expect(description.contains("\(old) は \(new) に名前が変わりました"))
        }
    }

    @Test func 旧キーが両方あると両方の移行先を示す() throws {
        let toml = "[[ai]]\nprompt = '補助指示'\nautoPrompt = '初期文面'"
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: toml) }
        do { _ = try ConfigLoader.parse(toml: toml) }
        catch let ConfigError.invalid(description) {
            #expect(description.contains("prompt は alwaysPrompt に名前が変わりました"))
            #expect(description.contains("autoPrompt は initialPrompt に名前が変わりました"))
        }
    }

    @Test func 保存済み会議の設定キーは読み書きとも旧形式を保つ() throws {
        let old = Data("""
        {"cli":"codex","address":"迅雷へ","cwd":"file:///tmp/prompt-config-tests/",
         "extraArgs":[],"prompt":"毎回の指示","autoPrompt":"初期文面","notifySound":false}
        """.utf8)
        let profile = try AIJSON.decode(ResolvedAIConfig.self, from: old)
        #expect(profile.alwaysPrompt == "毎回の指示" && profile.initialPrompt == "初期文面")
        let data = try AIJSON.encode(profile)
        let saved = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(saved["prompt"] as? String == "毎回の指示")
        #expect(saved["autoPrompt"] as? String == "初期文面")
        #expect(saved["alwaysPrompt"] == nil && saved["initialPrompt"] == nil)
        #expect(try AIJSON.decode(ResolvedAIConfig.self, from: data) == profile)
        for text in ["a\0", String(repeating: "あ", count: 11_000)] {
            #expect(throws: ConfigError.self) { try AIConfig(alwaysPrompt: text).validate() }
            #expect(throws: ConfigError.self) { try AIConfig(initialPrompt: text).validate() }
        }
    }
}
