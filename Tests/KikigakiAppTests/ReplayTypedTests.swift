import Testing
@testable import Kikigaki

@Suite struct ReplayTypedTests {
    @Test func 通常起動は不正な開発入力も無視しreplayだけ解釈する() throws {
        let env = ["KIKIGAKI_DEBUG_TYPED_ENTRIES": "不正", "KIKIGAKI_DEBUG_TYPED_VERIFY": "不正"]
        #expect(try ReplayDebugOptions.load(arguments: ["Kikigaki", "--smoke"], environment: env).typedEntries.isEmpty)
        #expect(throws: (any Error).self) { try ReplayDebugOptions.load(arguments: ["Kikigaki", "--smoke", "--replay"], environment: env) }
        let input = #"[{"seconds":20,"text":"https://example.com:8080/a;b?q=1:2","pauseSeconds":2},{"seconds":10,"text":"先"},{"seconds":20,"text":"同位置の後"}]"#
        let value = try ReplayDebugOptions.load(arguments: ["Kikigaki", "--smoke", "--replay"],
            environment: ["KIKIGAKI_DEBUG_TYPED_ENTRIES": input, "KIKIGAKI_DEBUG_TYPED_VERIFY": "1"])
        #expect(value.typedEntries.map(\.text) == ["先", "https://example.com:8080/a;b?q=1:2", "同位置の後"])
        #expect(value.verifyTyped)
        #expect(value.typedEntries[1].pauseSeconds == 2)
    }
    @Test(arguments: [#"[{"seconds":-1,"text":"本文"}]"#, #"[{"seconds":1,"text":"  "}]"#,
                      #"[{"seconds":1,"text":"\u0000"}]"#, #"[{"seconds":1}]"#, #"{}"#,
                      #"[{"seconds":1,"text":"本文","pauseSeconds":-1}]"#,
                      #"[{"seconds":1,"text":"本文","pauseSeconds":61}]"#])
    func 不正な投稿位置や本文をsmokeで拒否する(_ input: String) {
        #expect(throws: (any Error).self) {
            try ReplayDebugOptions.load(arguments: ["Kikigaki", "--smoke", "--replay"], environment: ["KIKIGAKI_DEBUG_TYPED_ENTRIES": input])
        }
    }
}
