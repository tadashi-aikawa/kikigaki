import Testing
@testable import KikigakiCore

@Suite struct AIReplyNoticeTests {
    @Test func 書かなければ人が待つ返事と確認質問だけ知らせる() {
        #expect(AIReplyNotice.enabled(nil, kind: .answered, awaited: true))
        #expect(AIReplyNotice.enabled(nil, kind: .failed, awaited: true))
        #expect(!AIReplyNotice.enabled(nil, kind: .answered, awaited: false))
        #expect(!AIReplyNotice.enabled(nil, kind: .failed, awaited: false))
        #expect(AIReplyNotice.enabled(nil, kind: .needsInput, awaited: false))
        #expect(AIReplyNotice.enabled(nil, kind: .needsInput, awaited: true))
    }

    @Test func 書けば手動も自動も確認質問もその値に従う() {
        for kind in [AIReceiveEvent.Kind.answered, .needsInput, .failed] {
            for awaited in [true, false] {
                #expect(AIReplyNotice.enabled(true, kind: kind, awaited: awaited))
                #expect(!AIReplyNotice.enabled(false, kind: kind, awaited: awaited))
            }
        }
    }

    @Test func 受領は知らせない() {
        #expect(!AIReplyNotice.enabled(nil, kind: .accept, awaited: true))
        #expect(!AIReplyNotice.enabled(true, kind: .accept, awaited: true))
    }

    @Test func 本文は種類の印とMarkdownの記号を外した冒頭() {
        func text(_ kind: AIReceiveEvent.Kind, _ body: String) -> String {
            AIReplyNotice(slot: 1, kind: kind, awaited: true, body: body).text
        }
        #expect(text(.answered, "## 結論\n\n- **決定事項**を3件足しました\n- [議事録](https://example.com)を見て") ==
                "結論 決定事項を3件足しました 議事録を見て")
        #expect(text(.needsInput, "> どこに書けば\n1. `見出し`の下") == "確認: どこに書けば 見出しの下")
        #expect(text(.failed, "[[議事録|会議メモ]]へ書けません") == "失敗: 会議メモへ書けません")
        #expect(text(.answered, "| 列 | 値 |\n| --- | --- |\n| a | b |") == "| 列 | 値 | | a | b |")
        #expect(text(.answered, "```swift\nlet x = 1\n```\n- [x] 済み") == "let x = 1 済み")
    }

    @Test func 長い本文は上限で切って省略の印を付ける() {
        let long = String(repeating: "あ", count: AIReplyNotice.excerptLimit + 10)
        let text = AIReplyNotice(slot: 1, kind: .answered, awaited: true, body: long).text
        #expect(text.count == AIReplyNotice.excerptLimit + 1 && text.hasSuffix("…"))
    }
}
