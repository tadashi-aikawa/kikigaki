import Testing
@testable import KikigakiCore

@Suite struct MinutesMarkdownTests {
    private func text(_ source: String, minutes: Bool = true) -> String {
        MarkdownBlocks.parse(source, minutes: minutes).map { block in
            switch block {
            case .paragraph(let runs), .heading(_, let runs): return runs.map(\.text).joined()
            case .listItem(let item): return item.content.map(\.text).joined()
            case .quote(let lines): return lines.flatMap(\.content).map(\.text).joined()
            case .code(let body, _): return body
            case .table(let table): return ([table.header] + table.rows).flatMap { $0 }.flatMap { $0 }.map(\.text).joined(separator: " ")
            case .rule: return "---"
            }
        }.joined(separator: "\n")
    }
    @Test func frontmatterは閉じた先頭だけを隠す() {
        #expect(text("\u{FEFF}---\r\ntitle: test\r\n---\r\n本文") == "本文")
        #expect(text("---\ntitle: test").contains("title: test"))
        #expect(text("本文\n---\ntitle: test\n---").contains("title: test"))
    }
    @Test func wikilinkの別名を装飾にせずコードと埋め込みを保つ() {
        #expect(text("[[a|]]") == "a")
        #expect(text("[[閉じない") == "[[閉じない")
        #expect(text("<div>HTML</div>") == "<div>HTML</div>")
        let source = "[[a\\|**別名**]] [[見出し#節]] ![[図]] ![画像](x.png) `[[code]]`\n> [[引用]]\n\n```\n[[block]]\n```"
        let result = text(source)
        #expect(result.contains("**別名**") && result.contains("見出し#節"))
        #expect(result.contains("![[図]]") && result.contains("![画像](x.png)"))
        #expect(result.contains("[[code]]") && result.contains("[[block]]"))
        #expect(!result.contains("[[引用]]"))
        #expect(text(source, minutes: false).contains("[[a\\|**別名**]]"))
    }
    @Test func 表のescapedPipeを先に分割しコード内を変えない() {
        let blocks = MarkdownBlocks.parse("| ノート | 記法 |\n| --- | --- |\n| [[a\\|b]] | `[[code]]` |", minutes: true)
        guard case .table(let table) = blocks.first else { Issue.record("表として解析"); return }
        #expect(table.rows[0][0].map(\.text).joined() == "b")
        #expect(table.rows[0][1].map(\.text).joined() == "[[code]]")
    }
}
