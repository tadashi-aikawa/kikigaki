import Testing
import KikigakiCore

@Suite struct MarkdownBlocksTests {
    private func text(_ runs: [MarkdownInline]) -> String { runs.map(\.text).joined() }

    @Test func 会議の返事に全要素が混在しても器と文字を保つ() throws {
        let source = """
        # 議事メモ
        決定は**継続**、*試験中*、~~旧案~~。実行は `swift test`。
        - [x] 合意済み
          + 次の確認
        10. [仕様](https://example.com/spec)
        > 引用した発言
        > 続き
        ```swift
        let message = "**これはコード**"
        ```
        | 担当 | 状況 |
        | :--- | ---: |
        | 迅雷 | 検証中 |
        ---
        https://example.com/minutes
        """
        let blocks = MarkdownBlocks.parse(source)
        #expect(blocks.count == 10)
        #expect(blocks[0] == .heading(level: 1, content: [.init("議事メモ")]))
        guard case .paragraph(let runs) = blocks[1] else { Issue.record("本文がない"); return }
        #expect(text(runs) == "決定は継続、試験中、旧案。実行は swift test。")
        #expect(runs.contains(.init("継続", style: .strong)))
        #expect(runs.contains(.init("試験中", style: .emphasis)))
        #expect(runs.contains(.init("旧案", style: .strikethrough)))
        #expect(runs.contains(.init("swift test", isCode: true)))
        #expect(blocks[6] == .code(text: "let message = \"**これはコード**\"", language: "swift"))
        #expect(blocks[8] == .rule)
        guard case .paragraph(let url) = blocks[9] else { Issue.record("URLがない"); return }
        #expect(url.first?.webURL?.absoluteString == "https://example.com/minutes")
    }

    @Test func 見出しの元の段を保持して描画のサイズから分離する() {
        for level in 1...6 {
            #expect(MarkdownBlocks.parse(String(repeating: "#", count: level) + " 見出し ###")
                == [.heading(level: level, content: [.init("見出し")])])
        }
        #expect(MarkdownBlocks.parse("###") == [.heading(level: 3, content: [])])
        for line in ["####### 対象外", "#空白なし", "    # 字下げ", "文章 # 中ほど"] {
            #expect(MarkdownBlocks.parse(line) == [.paragraph([.init(line)])])
        }
    }

    @Test func 箇条書きの増減と元の番号とチェック状態を保持する() {
        let blocks = MarkdownBlocks.parse("- 親\n  * 子\n    + 孫\n  09) [X] 済\n10. [ ] 未\n+ [x]\n- [z] 文字")
        let items = blocks.compactMap { block -> MarkdownListItem? in
            if case .listItem(let item) = block { return item }; return nil
        }
        #expect(items.count == 7)
        #expect(items.map(\.depth) == [0, 1, 2, 1, 0, 0, 0])
        #expect(items.map(\.marker) == ["-", "*", "+", "09)", "10.", "+", "-"])
        #expect(items.map(\.ordered) == [false, false, false, true, true, false, false])
        #expect(items.map(\.checked) == [nil, nil, nil, true, false, true, nil])
        #expect(items.last?.content == [.init("[z] 文字")])
    }

    @Test func タブと異なる字下げ幅も増減として扱い通常段落でリセットする() {
        let blocks = MarkdownBlocks.parse("- 親\n\t- 子\n\t\t- 孫\n\n\t- 子2\n本文\n- 新親")
        let depths = blocks.compactMap { if case .listItem(let item) = $0 { return item.depth }; return nil }
        #expect(depths == [0, 1, 2, 1, 0])
        #expect(blocks[3] == .paragraph([]))
        #expect(MarkdownBlocks.parse("1.2 数字\n-x\n+plus") == [
            .paragraph([.init("1.2 数字")]), .paragraph([.init("-x")]), .paragraph([.init("+plus")])
        ])
    }

    @Test func 引用の連なりと空行と段数を保ちcalloutは文字として残す() throws {
        let blocks = MarkdownBlocks.parse("> [!NOTE] お知らせ\n> **確認**\n>\n> > 入れ子\n\n終わり")
        guard case .quote(let lines) = try #require(blocks.first) else { Issue.record("引用がない"); return }
        #expect(lines.map(\.depth) == [1, 1, 1, 2])
        #expect(lines.map { text($0.content) } == ["[!NOTE] お知らせ", "確認", "", "入れ子"])
        #expect(lines[1].content == [.init("確認", style: .strong)])
        #expect(blocks.count == 3)
    }

    @Test func フェンス内は見出しや表や装飾を解釈せず同じ長さ以上で閉じる() {
        let source = "```` swift\n# head\n```\n|a|b|\n|---|---|\n  **字**  \n`````\n本文"
        #expect(MarkdownBlocks.parse(source) == [
            .code(text: "# head\n```\n|a|b|\n|---|---|\n  **字**  ", language: "swift"),
            .paragraph([.init("本文")])
        ])
    }

    @Test func 未閉鎖フェンスと空コードと異なるフェンスを保持する() {
        #expect(MarkdownBlocks.parse("~~~text\n一行\n```\n") == [.code(text: "一行\n```\n", language: "text")])
        #expect(MarkdownBlocks.parse("```\n```") == [.code(text: "", language: nil)])
        #expect(MarkdownBlocks.parse("~~~\n~~~~ extra\n~~~") == [.code(text: "~~~~ extra", language: nil)])
    }

    @Test func 空入力と改行と日本語の結合文字を保持する() {
        #expect(MarkdownBlocks.parse("") == [])
        #expect(MarkdownBlocks.parse("前\r\n\r\n👩🏽‍💻か\u{3099}\r") == [
            .paragraph([.init("前")]), .paragraph([]), .paragraph([.init("👩🏽‍💻か\u{3099}")]), .paragraph([])
        ])
        #expect(MarkdownBlocks.inline("**👩🏽‍💻か\u{3099}**") == [.init("👩🏽‍💻か\u{3099}", style: .strong)])
    }

    @Test func 表の区切りと整列と短い行の空セルを保持する() throws {
        let blocks = MarkdownBlocks.parse("左 | 中 | 右\n:--- | :---: | ---:\na | **b** | `c`\nx | y")
        guard case .table(let table) = try #require(blocks.first) else { Issue.record("表がない"); return }
        #expect(table.alignments == [.left, .center, .right])
        #expect(table.header == [[.init("左")], [.init("中")], [.init("右")]])
        #expect(table.rows == [
            [[.init("a")], [.init("b", style: .strong)], [.init("c", isCode: true)]],
            [[.init("x")], [.init("y")], []]
        ])
    }

    @Test func エスケープと行内コードのパイプは表を分割しない() throws {
        let source = "| 記法 | 説明 |\n| --- | --- |\n| a\\|b | `x|y` |\n| `` `|` `` | 末尾 |"
        guard case .table(let table) = try #require(MarkdownBlocks.parse(source).first) else { Issue.record("表がない"); return }
        #expect(table.rows[0] == [[.init("a|b")], [.init("x|y", isCode: true)]])
        #expect(table.rows[1] == [[.init("`|`", isCode: true)], [.init("末尾")]])
    }

    @Test func 不正な表や区切りのない行は文字を捨てない() {
        for source in ["a | b\n--- | :", "a | b\n--- | --- | ---", "| a | b |", "a\\|b\n---"] {
            let blocks = MarkdownBlocks.parse(source)
            #expect(!blocks.contains { if case .table = $0 { return true }; return false })
        }
        let source = "|a|b|\n|---|---|\n|1|2|3|\n末尾"
        let blocks = MarkdownBlocks.parse(source)
        #expect(blocks.count == 3)
        #expect(blocks[1] == .paragraph([.init("|1|2|3|")]))
        #expect(blocks[2] == .paragraph([.init("末尾")]))
    }

    // GFM TablesのExamples 199・200にある短い区切りとcode内のエスケープ。
    // https://github.github.com/gfm/#tables-extension-
    @Test func GFMの短い区切りとコード内のパイプを扱う() throws {
        let source = "| 記号 | 本文 |\n:-: | -:\n`\\|` | 日本語"
        guard case .table(let table) = try #require(MarkdownBlocks.parse(source).first) else { Issue.record("表がない"); return }
        #expect(table.alignments == [.center, .right])
        #expect(table.rows == [[[.init("|", isCode: true)], [.init("日本語")]]])
    }

    @Test func 表の次の引用や見出しをパイプのために表へ飲み込まない() {
        let blocks = MarkdownBlocks.parse("|a|b|\n|-|-|\n> x|y\n# a|b")
        #expect(blocks.count == 3)
        guard case .quote = blocks[1] else { Issue.record("引用を失った"); return }
        #expect(blocks[2] == .heading(level: 1, content: [.init("a|b")]))
        guard case .heading = MarkdownBlocks.parse("# a|b\n---|---").first else { Issue.record("見出しを表にした"); return }
        let malformed = MarkdownBlocks.parse("|a|b|\n|-|-|\n``a|b`|c")
        #expect(malformed.count == 2)
        #expect(malformed[1] == .paragraph([.init("``a|b`|c")]))
    }

    @Test(arguments: ["---", "* * *", "___", "  - - -  "])
    func 水平線を認識する(source: String) { #expect(MarkdownBlocks.parse(source) == [.rule]) }

    @Test func 水平線に似た箇条書きと文章は残す() {
        #expect(MarkdownBlocks.parse("--\n-_-\n文章 ---") == [
            .paragraph([.init("--")]), .paragraph([.init("-_-")]), .paragraph([.init("文章 ---")])
        ])
        guard case .listItem = MarkdownBlocks.parse("- 項目").first else { Issue.record("箇条書きを失った"); return }
    }

    @Test func 装飾の入れ子と組合せを保持する() {
        #expect(MarkdownBlocks.inline("***太字斜体***") == [.init("太字斜体", style: [.strong, .emphasis])])
        #expect(MarkdownBlocks.inline("**太字 *斜体* と ~~取消~~**") == [
            .init("太字 ", style: .strong), .init("斜体", style: [.strong, .emphasis]),
            .init(" と ", style: .strong), .init("取消", style: [.strong, .strikethrough])
        ])
        #expect(MarkdownBlocks.inline("*斜体 **太字** 続き*") == [
            .init("斜体 ", style: .emphasis), .init("太字", style: [.strong, .emphasis]), .init(" 続き", style: .emphasis)
        ])
        #expect(MarkdownBlocks.inline("__太字__ _斜体_ foo_bar_baz") == [
            .init("太字", style: .strong), .init(" "), .init("斜体", style: .emphasis), .init(" foo_bar_baz")
        ])
        #expect(MarkdownBlocks.inline("**太字 *斜体***") == [
            .init("太字 ", style: .strong), .init("斜体", style: [.strong, .emphasis])
        ])
        #expect(MarkdownBlocks.inline("*斜体 **太字***") == [
            .init("斜体 ", style: .emphasis), .init("太字", style: [.strong, .emphasis])
        ])
    }

    @Test func 行内コードの内側では何も解釈せず外側の装飾は維持する() {
        #expect(MarkdownBlocks.inline("`**字** [x](https://example.com)`") == [
            .init("**字** [x](https://example.com)", isCode: true)
        ])
        #expect(MarkdownBlocks.inline("**a `b**c` d**") == [
            .init("a ", style: .strong), .init("b**c", style: .strong, isCode: true), .init(" d", style: .strong)
        ])
        #expect(MarkdownBlocks.inline("`` `foo` ``") == [.init("`foo`", isCode: true)])
        #expect(MarkdownBlocks.inline("`  `") == [.init("  ", isCode: true)])
    }

    @Test func エスケープと壊れた記法を文字で残す() {
        #expect(MarkdownBlocks.inline(#"\*文字\* \[文字\] \_文字\_ \\ \日"#) == [.init(#"*文字* [文字] _文字_ \ \日"#)])
        for source in ["**閉じない", "`閉じない", "[閉じない](https://example.com", "foo_bar_baz", "* 空白 *"] {
            #expect(text(MarkdownBlocks.inline(source)) == source)
        }
        #expect(MarkdownBlocks.inline("``閉じない`") == [.init("``閉じない`")])
        #expect(MarkdownBlocks.inline("~~~取り消さない~~~") == [.init("~~~取り消さない~~~")])
    }

    @Test func 明示リンクは装飾した表示と行き先を分け括弧を保持する() {
        let runs = MarkdownBlocks.inline("[**仕様**と`実装`](https://example.com/a_(b))")
        #expect(runs == [
            .init("仕様", style: .strong, destination: "https://example.com/a_(b)"),
            .init("と", destination: "https://example.com/a_(b)"),
            .init("実装", isCode: true, destination: "https://example.com/a_(b)")
        ])
        #expect(MarkdownBlocks.inline(#"[a\]b](https://example.com/a\(b\))"#)
            == [.init("a]b", destination: "https://example.com/a(b)")])
    }

    @Test func 裸URLは末尾の句読点と対応しない括弧を含めない() {
        let runs = MarkdownBlocks.inline("(https://example.com/a_(b)). https://example.com/資料。")
        #expect(runs == [
            .init("("), .init("https://example.com/a_(b)", destination: "https://example.com/a_(b)"),
            .init("). "), .init("https://example.com/資料", destination: "https://example.com/資料"), .init("。")
        ])
        #expect(MarkdownBlocks.inline("https://example.com/?x=1&y=2#part").first?.destination
            == "https://example.com/?x=1&y=2#part")
        #expect(MarkdownBlocks.inline("https://example.com。続き") == [
            .init("https://example.com", destination: "https://example.com"), .init("。続き")
        ])
    }

    @Test(arguments: ["file:///tmp/a", "javascript:alert(1)", "mailto:a@example.com", "relative.md", "https://", "https://a b"])
    func 押せない行き先でもリンクの表示と原文の行き先は残す(target: String) {
        let runs = MarkdownBlocks.inline("[表示](\(target))")
        #expect(runs == [.init("表示", destination: target)])
        #expect(runs.first?.webURL == nil)
    }

    @Test func 対象外の画像とwikilinkとHTMLは表示用HTMLへ変換しない() {
        for source in ["![**画像**](https://example.com/a.png)", "[[ノート|**別名**]]", "<script>alert(1)</script>", "deadbeef Notes/test.md"] {
            #expect(MarkdownBlocks.inline(source) == [.init(source)])
        }
    }

    @Test func 長文と未閉鎖の角括弧の連続でも文字を保持する() {
        let prose = String(repeating: "長い返事👩🏽‍💻", count: 800)
        #expect(MarkdownBlocks.inline(prose) == [.init(prose)])
        let broken = String(repeating: "[", count: 256) + "未閉鎖"
        #expect(MarkdownBlocks.inline(broken) == [.init(broken)])
    }
}
