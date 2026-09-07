import Foundation
import Testing
@testable import Kikigaki

struct ReplayScheduleTests {
    @Test func 自動送信はreplayだけで解釈してコロンと改行を保持する() throws {
        let env = ["KIKIGAKI_DEBUG_AI_AUTO": "2.5:議事録: 更新\n短く返す"]
        #expect(try ReplayDebugOptions.load(arguments: ["Kikigaki", "--smoke"], environment: env).automatic == nil)
        let value = try ReplayDebugOptions.load(arguments: ["Kikigaki", "--smoke", "--replay"], environment: env)
        #expect(value.automatic?.interval == 2.5)
        #expect(value.automatic?.prompt == "議事録: 更新\n短く返す")
        #expect(value.automatic?.sendFinal == true)
    }

    @Test(arguments: ["", "3", "0:更新", "-1:更新", "nan:更新", "inf:更新", "3:", "3: \n", "3:更新\0", "3:" + String(repeating: "a", count: 32769)])
    func 不正な自動入力をsmokeでも拒否する(input: String) {
        #expect(throws: (any Error).self) {
            try ReplayDebugOptions.load(arguments: ["Kikigaki", "--smoke", "--replay"], environment: ["KIKIGAKI_DEBUG_AI_AUTO": input])
        }
    }
}
