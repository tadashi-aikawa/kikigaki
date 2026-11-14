import Foundation
import Testing

@testable import KikigakiCore

@Suite struct AISubmitKeysTests {
    private let home = URL(fileURLWithPath: "/Users/test")

    @Test func 送信キーは宛先のCLIの分だけ効く() throws {
        let config = try ConfigLoader.parse(toml: """
        [aiSubmitKeys]
        claude = ["ctrl+x", "ctrl+s"]

        [[ai]]
        name = "議事録"
        cli = "codex"
        [[ai]]
        name = "相談"
        cli = "claude"
        [[ai]]
        name = "既定のCLI"
        """)
        let profiles = ResolvedConfig(config: config, home: home).aiProfiles
        #expect(profiles.map(\.submitKeys) == [[], ["ctrl+x", "ctrl+s"], []])
    }

    @Test func 省略とEnterだけの指定は今までどおりEnterだけで送る() throws {
        for toml in ["[[ai]]", "[aiSubmitKeys]\n[[ai]]", "[aiSubmitKeys]\ncodex = [\"enter\"]\n[[ai]]",
                     "[aiSubmitKeys]\ncodex = [\"Return\"]\n[[ai]]"] {
            let config = try ConfigLoader.parse(toml: toml)
            #expect(ResolvedConfig(config: config, home: home).ai?.submitKeys == [], "\(toml)")
        }
        let shift = try ConfigLoader.parse(toml: "[aiSubmitKeys]\ncodex = [\"shift+enter\"]\n[[ai]]")
        #expect(ResolvedConfig(config: shift, home: home).ai?.submitKeys == ["shift+enter"])
    }

    @Test(arguments: ["ctrl+enter", "shift+enter", "cmd+enter", "alt+enter", "ctrl+x", "ctrl+shift+s", "f5", "f20",
                      "Ctrl+Enter", "control+return", "option+tab", "meta+space", "ctrl+-", "esc",
                      "+", "ctrl++", "ctrl+shift++", "ctrl+plus", "alt+slash"])
    func herdrが読める形を受け付ける(key: String) throws {
        #expect(AISubmitKeys.valid(key))
        _ = try ConfigLoader.parse(toml: "[aiSubmitKeys]\ncodex = [\"\(key)\"]")
    }

    @Test(arguments: ["", "ctrl+", "+enter", "+++", "ctrl+a++", "ctrl+ctrl++", "ctrl+enter+x", "ctrl+ctrl+x", "ctrl", "shift+ctrl",
                      "-", "--help", "ctrl enter", "pagedown", "f0", "f21", "f05", "ctrl+エンター", "ctrl+\\u0000"])
    func 送れない形は設定エラーにする(key: String) {
        #expect(!AISubmitKeys.valid(key.replacingOccurrences(of: "\\u0000", with: "\0")))
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: "[aiSubmitKeys]\nclaude = [\"\(key)\"]") }
    }

    @Test func 打鍵の数は1から4まで() throws {
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: "[aiSubmitKeys]\ncodex = []") }
        let five = Array(repeating: "\"ctrl+x\"", count: 5).joined(separator: ", ")
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: "[aiSubmitKeys]\ncodex = [\(five)]") }
        let four = Array(repeating: "\"ctrl+x\"", count: 4).joined(separator: ", ")
        _ = try ConfigLoader.parse(toml: "[aiSubmitKeys]\ncodex = [\(four)]")
    }

    @Test func 未知のCLI名は他の未知キーと同じくアプリでは無視する() throws {
        let config = try ConfigLoader.parse(toml: "[aiSubmitKeys]\ngemini = [\"--bad\"]\n[[ai]]")
        #expect(ResolvedConfig(config: config, home: home).ai?.submitKeys == [])
    }

    @Test func 会議に固定した送信キーを保存して読み戻し旧会議はEnterだけで読む() throws {
        let config = try ConfigLoader.parse(toml: "[aiSubmitKeys]\ncodex = [\"ctrl+enter\"]\n[[ai]]")
        let resolved = try #require(ResolvedConfig(config: config, home: home).ai)
        let data = try JSONEncoder().encode(resolved)
        #expect(try JSONDecoder().decode(ResolvedAIConfig.self, from: data) == resolved)

        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["submitKeys"] = nil
        let old = try JSONDecoder().decode(ResolvedAIConfig.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.submitKeys == [])

        object["submitKeys"] = ["--help"]
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ResolvedAIConfig.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }
}
