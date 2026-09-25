import Foundation
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

    @Test func 八枠はAからHで想定外のスロットは番号で表す() {
        #expect(SpeakerNames.slotCount == 8)
        #expect((4..<8).map { SpeakerNames().name(for: $0) } == ["話者E", "話者F", "話者G", "話者H"])
        #expect(SpeakerNames().name(for: 8) == "話者9")
    }

    @Test func 旧4人会議のarchiveは名前も記号も変えずに読める() throws {
        let legacy = Data(#"""
            {"original":{"startedAt":0,"duration":8,"utterances":[
              {"speaker":0,"start":0,"end":1,"text":"一"},{"speaker":3,"start":2,"end":3,"text":"四"}],
             "names":{"names":{"3":"田中"}},"pauses":[]},
             "markdownURL":"file:///tmp/legacy-4.md","candidateCount":0,"ownsRawFile":false,"omissionDisabledAfterFailure":false}
            """#.utf8)
        let archive = try JSONDecoder().decode(MeetingArchive.self, from: legacy)
        #expect(archive.original.names.diarizationEnabled)
        let markdown = MeetingMarkdown.render(archive.original)
        #expect(markdown.contains("- 話者: A=話者A, D=田中"))
    }

    @Test func E以降の名前を保存して読み戻せる() throws {
        var names = SpeakerNames([0: "田中"])
        names.set("鈴木", for: 7)
        let restored = try JSONDecoder().decode(SpeakerNames.self, from: JSONEncoder().encode(names))
        #expect(restored == names)
        #expect(restored.name(for: 7) == "鈴木" && restored.name(for: 4) == "話者E")
        #expect(restored.otherSlot(using: "鈴木", excluding: 0) == 7)
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
