import Foundation
import Testing
@testable import KikigakiCore

@Suite struct ConfigSchemaTests {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func schema() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("Resources/config.schema.json"))) as? [String: Any])
    }

    private func properties(_ object: [String: Any]) throws -> [String: [String: Any]] {
        #expect(object["type"] as? String == "object")
        #expect(object["additionalProperties"] as? Bool == false)
        let properties = try #require(object["properties"] as? [String: [String: Any]])
        for (key, value) in properties {
            #expect(!(value["description"] as? String ?? "").isEmpty, "説明がないキー: \(key)")
            #expect(value["type"] is String, "型がないキー: \(key)")
        }
        return properties
    }

    @Test func デコーダーが読むキーとスキーマのキーは一致する() throws {
        let schema = try schema()
        let top = try properties(schema)
        let topKeys = try KeyProbe.keys(KikigakiConfig.self)
        #expect(Set(top.keys) == topKeys)
        let speakers = try properties(#require(top["speakers"]?["items"] as? [String: Any]))
        let speakerKeys = try KeyProbe.keys(KikigakiConfig.Speaker.self)
        #expect(Set(speakers.keys) == speakerKeys)
        let ai = try properties(#require(top["ai"]?["items"] as? [String: Any]))
        let retired: Set<String> = ["prompt", "autoPrompt", "attach", "displayAgent"]
        let aiKeys = try KeyProbe.keys(AIConfig.self).subtracting(retired)
        #expect(Set(ai.keys) == aiKeys)
        #expect(Set(ai.keys).isDisjoint(with: retired))
    }

    @Test func スキーマの既定値と実装の既定値は一致する() throws {
        let top = try properties(schema())
        let resolved = ResolvedConfig(config: try ConfigLoader.parse(toml: ""))
        #expect(top["outputDir"]?["default"] as? String == ResolvedConfig.defaultOutputDir)
        #expect(top["participantsKey"]?["default"] as? String == resolved.participantsKey)
        #expect(top["autoSendPhrases"]?["default"] as? [String] == resolved.autoSendPhrases)
        #expect(top["saveRecording"]?["default"] as? Bool == resolved.saveRecording)
        #expect(top["measureAudioLevels"]?["default"] as? Bool == resolved.measureAudioLevels)
        #expect(top["speakers"]?["default"] as? [String] == resolved.speakers.map(\.name))
        #expect(resolved.ai == nil)
        #expect(top["ai"]?["default"] == nil)
        let ai = try properties(#require(top["ai"]?["items"] as? [String: Any]))
        let profile = ResolvedAIConfig(config: AIConfig(), home: URL(fileURLWithPath: "/tmp/schema-test-home"))
        #expect(ai["cli"]?["default"] as? String == profile.cli.rawValue)
        #expect(ai["cwd"]?["default"] as? String == ResolvedAIConfig.defaultCWD)
        #expect(ai["address"]?["default"] as? String == profile.address)
        // 未指定は手動と自動で既定が変わるため、固定の既定値を補完で挿入しない。
        #expect(profile.notifySound == nil && profile.notifyBanner == nil)
        #expect(ai["notifySound"]?["default"] == nil && ai["notifyBanner"]?["default"] == nil)
        #expect(ai["allowWork"]?["default"] as? Bool == profile.allowWork)
        #expect(ai["identifySpeakers"]?["default"] as? Bool == profile.identifySpeakers)
        #expect(ai["autoStart"]?["default"] as? Bool == profile.autoStart)
        // 未指定はトップレベルを継承するため、固定の既定配列を補完で挿入しない。
        #expect(profile.autoSendPhrases == nil)
        #expect(ai["autoSendPhrases"]?["default"] == nil)
        #expect(ai["autoSendPhrases"]?["maxItems"] as? Int == 20)
        #expect(ai["autoSendPhrases"]?["uniqueItems"] as? Bool == true)
        #expect(ai["autoIntervalMinutes"]?["default"] as? Int == profile.autoIntervalMinutes)
        #expect(ai["alwaysPrompt"]?["default"] as? String == profile.alwaysPrompt)
        #expect(ai["initialPrompt"]?["default"] as? String == profile.initialPrompt)
        #expect(ai["extraArgs"]?["default"] as? [String] == profile.extraArgs)
        let efforts = try #require(ai["effort"]?["enum"] as? [String])
        #expect(Set(efforts) == Set(AIEffort.values(for: .codex) + AIEffort.values(for: .claude)))
        #expect(efforts.count == Set(efforts).count)
    }

    @Test func 説明末尾の必須と既定値はスキーマに一致する() throws {
        // Taploはdefaultとrequiredを説明に表示しないため、description末尾にも明記する。
        func inspect(_ object: [String: Any], path: String) throws {
            if object["type"] as? String == "object" {
                let properties = try properties(object)
                let required = Set(object["required"] as? [String] ?? [])
                #expect(required.isSubset(of: Set(properties.keys)), "存在しない必須キー: \(path)")
                for (key, value) in properties {
                    let keyPath = path + "." + key
                    let description = try #require(value["description"] as? String)
                    let paragraphs = description.components(separatedBy: "\n\n")
                    #expect(paragraphs.count >= 2, "末尾の前に空行がない: \(keyPath)")
                    let lastLine = try #require(paragraphs.last)
                    #expect(!lastLine.contains("\n"), "末尾が1行でない: \(keyPath)")
                    if required.contains(key) {
                        #expect(value["default"] == nil, "必須キーに既定値がある: \(keyPath)")
                        #expect(lastLine == "必須", "必須の説明が一致しない: \(keyPath)")
                    } else if let defaultValue = value["default"] {
                        let data = try JSONSerialization.data(withJSONObject: defaultValue,
                            options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
                        let json = try #require(String(data: data, encoding: .utf8))
                        #expect(lastLine == "任意 · 既定: `\(json)`", "既定値の説明が一致しない: \(keyPath)")
                    } else {
                        let prefix = "任意 · 既定: "
                        #expect(lastLine.hasPrefix(prefix), "任意の説明がない: \(keyPath)")
                        let words = String(lastLine.dropFirst(prefix.count))
                        #expect(!words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                "言葉の既定が空: \(keyPath)")
                        #expect(!words.contains("`"), "言葉の既定をコードで囲んでいる: \(keyPath)")
                    }
                    try inspect(value, path: keyPath)
                }
            }
            if let items = object["items"] as? [String: Any] {
                try inspect(items, path: path + "[]")
            }
        }
        try inspect(schema(), path: "config")
    }

    @Test func 省略で設定エラーになるキーだけを必須にする() throws {
        let schema = try schema()
        let top = try properties(schema)
        #expect((schema["required"] as? [String] ?? []).isEmpty)
        _ = try ConfigLoader.parse(toml: "")
        let speakers = try #require(top["speakers"]?["items"] as? [String: Any])
        #expect(speakers["required"] as? [String] == ["name"])
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: "[[speakers]]") }
        let config = try ConfigLoader.parse(toml: "[[speakers]]\nname = '田中'\n[[ai]]")
        #expect(config.speakers?.first?.avatar == nil)
        #expect(config.ai?.profiles.count == 1)
        let ai = try #require(top["ai"]?["items"] as? [String: Any])
        #expect((ai["required"] as? [String] ?? []).isEmpty)
    }

    @Test func 補完対象のスキーマに合成キーワードを使わない() throws {
        // Taploはこれらがあると、その表の中の補完を返さない。
        let forbidden: Set<String> = ["allOf", "anyOf", "oneOf", "if", "not"]
        func inspect(_ object: [String: Any], path: String) {
            #expect(forbidden.isDisjoint(with: object.keys), "補完を妨げるキーワード: \(path)")
            if let properties = object["properties"] as? [String: [String: Any]] {
                for (key, value) in properties {
                    inspect(value, path: path + ".properties." + key)
                }
            }
            if let items = object["items"] as? [String: Any] {
                inspect(items, path: path + ".items")
            } else if let items = object["items"] as? [[String: Any]] {
                for (index, value) in items.enumerated() {
                    inspect(value, path: path + ".items[\(index)]")
                }
            }
        }
        inspect(try schema(), path: "schema")
    }

    @Test func 未知キーを無視する実行時の動作は変えない() throws {
        let config = try ConfigLoader.parse(toml: """
        saveRecroding = true
        [[speakers]]
        name = "田中"
        avater = "a.webp"
        [[ai]]
        autoStrat = true
        """)
        #expect(config.saveRecording == nil)
        #expect(config.speakers?.first?.avatar == nil)
        #expect(config.ai?.first?.autoStart == nil)
    }

    @Test(arguments: ["prompt", "autoPrompt", "attach", "displayAgent"])
    func 廃止キーはアプリでも拒否する(key: String) {
        let value = key == "attach" ? "false" : "'旧設定'"
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: "[[ai]]\n\(key) = \(value)") }
    }

    @Test func リファレンスの設定例をパーサーでも受け付ける() throws {
        let docs = try String(contentsOf: root.appendingPathComponent("docs/config.md"), encoding: .utf8)
        let examples = docs.components(separatedBy: "```toml\n").dropFirst()
            .compactMap { $0.components(separatedBy: "```").first }
        let example = try #require(examples.first { $0.contains("outputDir =") })
        #expect(try ConfigLoader.parse(toml: example).ai?.profiles.count == 2)
    }
}

/// nilを返すDecoderで、合成されたinit(from:)も手書きのinit(from:)も実際に呼ぶ。
/// 任意キーを増やすだけで記録対象に入るため、全キー入りfixtureの更新忘れに依存しない。
private final class KeyProbe: Decoder {
    var keys: Set<String> = []
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    static func keys<T: Decodable>(_ type: T.Type) throws -> Set<String> {
        let probe = KeyProbe()
        _ = try T(from: probe)
        return probe.keys
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(Container<Key>(probe: self))
    }
    func unkeyedContainer() throws -> any UnkeyedDecodingContainer { throw ProbeError.unsupported }
    func singleValueContainer() throws -> any SingleValueDecodingContainer { throw ProbeError.unsupported }

    private enum ProbeError: Error { case unsupported }
    private struct Container<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let probe: KeyProbe
        var codingPath: [any CodingKey] { [] }
        var allKeys: [Key] { [] }
        func contains(_ key: Key) -> Bool { probe.keys.insert(key.stringValue); return false }
        func decodeNil(forKey key: Key) -> Bool { probe.keys.insert(key.stringValue); return true }
        func decode(_ type: String.Type, forKey key: Key) -> String { probe.keys.insert(key.stringValue); return "" }
        func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
            probe.keys.insert(key.stringValue)
            throw ProbeError.unsupported
        }
        func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
            throw ProbeError.unsupported
        }
        func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer { throw ProbeError.unsupported }
        func superDecoder() throws -> any Decoder { throw ProbeError.unsupported }
        func superDecoder(forKey key: Key) throws -> any Decoder { throw ProbeError.unsupported }
    }
}
