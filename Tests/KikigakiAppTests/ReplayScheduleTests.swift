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

    @Test func 設定のautoStartを短い間隔へ上書きする指定はreplayだけで効く() throws {
        let env = ["KIKIGAKI_DEBUG_AI_AUTO_SECONDS": "4.5"]
        #expect(try ReplayDebugOptions.load(arguments: ["Kikigaki", "--smoke"], environment: env).automaticSeconds == nil)
        let value = try ReplayDebugOptions.load(arguments: ["Kikigaki", "--smoke", "--replay"], environment: env)
        #expect(value.automaticSeconds == 4.5)
    }

    @Test(arguments: ["", "0", "-1", "nan", "inf", "3601", "abc"])
    func 不正な間隔上書きをsmokeでも拒否する(input: String) {
        #expect(throws: (any Error).self) {
            try ReplayDebugOptions.load(arguments: ["Kikigaki", "--smoke", "--replay"],
                                        environment: ["KIKIGAKI_DEBUG_AI_AUTO_SECONDS": input])
        }
    }

    @Test func 手動の宛先指定はreplayだけで効く() throws {
        let env = ["KIKIGAKI_DEBUG_AI_ASK_PROFILE": "相談"]
        #expect(try ReplayDebugOptions.load(arguments: ["Kikigaki", "--smoke"], environment: env).askProfile == nil)
        let value = try ReplayDebugOptions.load(arguments: ["Kikigaki", "--smoke", "--replay"], environment: env)
        #expect(value.askProfile == "相談")
    }

    /// 長い名前は拒否しない。宛名から補ったプロファイル名は64バイトを超え得る。
    @Test func 宛名から補った長い宛先も指定できる() throws {
        let long = String(repeating: "あ", count: 22)
        let value = try ReplayDebugOptions.load(arguments: ["Kikigaki", "--smoke", "--replay"],
                                                environment: ["KIKIGAKI_DEBUG_AI_ASK_PROFILE": long])
        #expect(value.askProfile == long)
    }

    @Test(arguments: ["", "  ", "相談\n議事録", "相談\0"])
    func 不正な宛先指定をsmokeでも拒否する(input: String) {
        #expect(throws: (any Error).self) {
            try ReplayDebugOptions.load(arguments: ["Kikigaki", "--smoke", "--replay"],
                                        environment: ["KIKIGAKI_DEBUG_AI_ASK_PROFILE": input])
        }
    }

    /// 段8の入力。準備の起動と紐づけの選択もreplayから駆動する。
    @Test func 準備と紐づけの指定はreplayだけで効く() throws {
        let env = ["KIKIGAKI_DEBUG_AI_PREPARE": "議事録;相談",
                   "KIKIGAKI_DEBUG_AI_ATTACH": "1=oldest;2=new"]
        let ignored = try ReplayDebugOptions.load(arguments: ["Kikigaki", "--smoke"], environment: env)
        #expect(ignored.prepareProfiles.isEmpty && ignored.attach.isEmpty)
        let value = try ReplayDebugOptions.load(arguments: ["Kikigaki", "--smoke", "--replay"], environment: env)
        #expect(value.prepareProfiles == ["議事録", "相談"])
        #expect(value.attach == [1: .oldest, 2: .new])
    }

    /// 空は「指定なし」。既存のASKと同じ扱いにする。
    @Test(arguments: ["  ", "議事録\n相談", "議事録\0"])
    func 不正な準備の指定をsmokeでも拒否する(input: String) {
        #expect(throws: (any Error).self) {
            try ReplayDebugOptions.load(arguments: ["Kikigaki", "--smoke", "--replay"],
                                        environment: ["KIKIGAKI_DEBUG_AI_PREPARE": input])
        }
    }

    @Test(arguments: ["1", "1=", "0=oldest", "-1=new", "1=both", "1=oldest;1=new", "a=new"])
    func 不正な紐づけの指定をsmokeでも拒否する(input: String) {
        #expect(throws: (any Error).self) {
            try ReplayDebugOptions.load(arguments: ["Kikigaki", "--smoke", "--replay"],
                                        environment: ["KIKIGAKI_DEBUG_AI_ATTACH": input])
        }
    }

    /// 「取消(録音を始めない)」の実機確認をreplayから駆動する。
    @Test func 取消の指定はreplayだけで効く() throws {
        let env = ["KIKIGAKI_DEBUG_AI_ATTACH_CANCEL": "1"]
        #expect(try ReplayDebugOptions.load(arguments: ["Kikigaki", "--smoke"], environment: env).attachCancel == false)
        #expect(try ReplayDebugOptions.load(arguments: ["Kikigaki", "--smoke", "--replay"], environment: env).attachCancel)
    }

    @Test(arguments: ["", "2", "true", "yes"])
    func 不正な取消指定をsmokeでも拒否する(input: String) {
        #expect(throws: (any Error).self) {
            try ReplayDebugOptions.load(arguments: ["Kikigaki", "--smoke", "--replay"],
                                        environment: ["KIKIGAKI_DEBUG_AI_ATTACH_CANCEL": input])
        }
    }
}
