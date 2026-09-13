import Testing
import KikigakiCore

struct MinutesHistoryTests {
    @Test func 再表示を先頭へ移し重複させず古いものから落とす() {
        var history = MinutesHistory()
        for index in 1...12 { history.record("/議事録/定例\(index).md") }
        #expect(history.paths == (3...12).reversed().map { "/議事録/定例\($0).md" })
        history.record("/議事録/定例5.md")
        #expect(history.paths == ["/議事録/定例5.md"] + (3...12).reversed().filter { $0 != 5 }.map { "/議事録/定例\($0).md" })
        history.record("/議事録/定例5.md")
        #expect(history.paths.count == 10)
    }

    @Test func 復元時は保存順を保って不正値と重複を除く() {
        let input = ["relative.md", "/a.md", "/b.md", "/a.md", "", "/bad.txt"] + (1...12).map { "/\($0).md" }
        #expect(MinutesHistory(paths: input).paths == ["/a.md", "/b.md"] + (1...8).map { "/\($0).md" })
        var history = MinutesHistory(paths: ["/a.md"])
        for invalid in ["", "relative.md", "/a/../b.md", "/bad\n.md", "/.kikigaki-context/a.md"] { history.record(invalid) }
        #expect(history.paths == ["/a.md"])
    }

    @Test func 実在や大小文字の解決を履歴の同一性へ混ぜない() {
        let paths = ["/未作成/会議.md", "/未作成/会議.MD", "/別の場所/会議.md"]
        #expect(MinutesHistory(paths: paths).paths == paths)
        #expect(MinutesHistory().paths.isEmpty)
    }
}
