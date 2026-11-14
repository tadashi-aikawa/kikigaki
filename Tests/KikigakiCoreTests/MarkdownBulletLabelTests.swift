import Testing
@testable import KikigakiCore

/// 判定はparliamentの `bullet-label.spec.ts` と同じ例で確かめる。
@Suite struct MarkdownBulletLabelTests {
    private func split(_ line: String) -> MarkdownBulletLabel? {
        guard case .listItem(let item) = MarkdownBlocks.parse(line).first else { return nil }
        return MarkdownBulletLabel.split(item.content)
    }
    private func text(_ runs: [MarkdownInline]) -> String { runs.map(\.text).joined() }

    @Test func 行頭のラベルを切り出し残りは空白から始まる() throws {
        let found = try #require(split("- 原因: 5秒で演出を止めるタイマー"))
        #expect(found.label == "原因")
        #expect(text(found.rest) == " 5秒で演出を止めるタイマー")
    }

    @Test func ラベルの直後がインラインコードでも切り出す() throws {
        let found = try #require(split("- 検証: `swift test` 全件通過"))
        #expect(found.label == "検証")
        #expect(found.rest.first == MarkdownInline(" "))
        #expect(found.rest.dropFirst().first?.isCode == true)
    }

    @Test func ラベルだけの行も切り出す() {
        #expect(split("- 選択肢:") == MarkdownBulletLabel(label: "選択肢", long: false, rest: []))
    }

    @Test func 字数と空白は問わず数字だけのラベルも拾う() {
        #expect(split("- GitHub Release: https://example.com")?.label == "GitHub Release")
        #expect(split("- homebrew-tap: 更新")?.label == "homebrew-tap")
        #expect(split("- 決定事項として明記した内容: 自動判定しない")?.label == "決定事項として明記した内容")
        #expect(split("1. 0: 番号への回答")?.label == "0")
        #expect(split("- [ ] 担当: 佐藤")?.label == "担当")
    }

    @Test func 十二字までは折り返さないラベルで十三字からは長いラベル() {
        #expect(split("- 未対応で受け入れるリスク: 小さい")?.long == false)
        #expect(split("- 未対応のまま受け入れるリスク量: 小さい")?.long == true)
    }

    @Test func 太字のラベルは二つの形とも拾い残りを地の文で返す() {
        #expect(split("- **検証**: 全件通過") == MarkdownBulletLabel(label: "検証", long: false, rest: [MarkdownInline(" 全件通過")]))
        #expect(split("- **理由:** 遅い") == MarkdownBulletLabel(label: "理由", long: false, rest: [MarkdownInline(" 遅い")]))
        #expect(split("- **装飾しない形**:") == MarkdownBulletLabel(label: "装飾しない形", long: false, rest: []))
        #expect(split("- **docs/credits.md を新設**: 素材の細目を移す")?.label == "docs/credits.md を新設")
        let after = split("- **検証**: `swift test` 全件通過")
        #expect(after?.rest.dropFirst().first?.isCode == true)
    }

    @Test func 改行の手前もラベルの行末() {
        #expect(split("- 前提:<br>続き")?.label == "前提")
        #expect(split("- **前提**:<br>続き")?.label == "前提")
    }

    @Test func ラベルの形でない行は拾わない() {
        for line in ["- 18:43 に開始", "- https://example.com", "- 理由:遅い", "- 理由:**遅い**", "- **理由**:**遅い**",
                     "- 理由 : 遅い", "- 理由： 全角", "- `swift test`: コード", "- 推奨はA。理由: 文", "- 無料プランの上限。出典: 公式",
                     "- **理**由: 途中まで太字", "- *理由*: 斜体", "- [理由](https://example.com): リンク",
                     "- **太字の文** と続く", "- コロンの無い行"] {
            #expect(split(line) == nil, "\(line)")
        }
    }

    @Test func ラベルと残りをつなぐと元の字に戻る() throws {
        for line in ["- 理由: 遅い **とても** `code`", "- **理由**: 遅い", "- **理由:** 遅い"] {
            let found = try #require(split(line))
            #expect(found.label + ":" + text(found.rest) == line.replacingOccurrences(of: "- ", with: "")
                .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: ""))
        }
    }
}
