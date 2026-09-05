import Testing

@testable import KikigakiCore

@Suite struct SpeakerNamesTests {
    @Test func 既定は枡の記号() {
        let names = SpeakerNames()
        #expect(names.name(for: 0) == "話者A")
        #expect(names.name(for: 3) == "話者D")
        #expect(names.name(for: nil) == "?")
        #expect(names.customName(for: 0) == nil)
    }

    @Test func 想定外のスロットは番号で表す() {
        #expect(SpeakerNames().name(for: 4) == "話者5")
    }

    @Test func 名前を付けると表示が変わり空白は落とす() {
        var names = SpeakerNames()
        names.set("  田中 ", for: 1)
        #expect(names.name(for: 1) == "田中")
        #expect(names.customName(for: 1) == "田中")
    }

    @Test func 改行は空白にする() {
        var names = SpeakerNames()
        names.set("田中\n太郎\r\n", for: 0)
        #expect(names.name(for: 0) == "田中 太郎")
    }

    @Test func 空文字で既定に戻る() {
        var names = SpeakerNames([0: "山田"])
        names.set("   ", for: 0)
        #expect(names.name(for: 0) == "話者A")
        #expect(names.customName(for: 0) == nil)
    }

    @Test func resetで全部既定に戻る() {
        var names = SpeakerNames([0: "山田", 2: "鈴木"])
        names.reset()
        #expect(names == SpeakerNames())
    }

    @Test func 既定名の確定はカスタム名を残さない() {
        for slot in 0..<SpeakerNames.slotCount {
            let defaultName = SpeakerNames.defaultName(for: slot)
            var names = SpeakerNames()
            names.set(defaultName, for: slot)
            #expect(names.customName(for: slot) == nil)
            #expect(names == SpeakerNames())
            names.set("田中", for: slot)
            names.set(" \(defaultName) ", for: slot)
            #expect(names.customName(for: slot) == nil)
            #expect(names.name(for: slot) == defaultName)
        }
    }
}
