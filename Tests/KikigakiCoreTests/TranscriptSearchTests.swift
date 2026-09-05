import Foundation
import Testing
@testable import KikigakiCore

@Suite struct TranscriptSearchTests {
    @Test func 大小と全半角を同一視し元の文字位置を返す() {
        let text = "ABC abc ＡＢＣ"
        let ranges = TranscriptSearch.ranges(in: text, query: "aBc")
        #expect(ranges.map { String(text[$0]) } == ["ABC", "abc", "ＡＢＣ"])
        #expect(ranges.map { NSRange($0, in: text) } == [.init(location: 0, length: 3), .init(location: 4, length: 3), .init(location: 8, length: 3)])
    }
    @Test func かな種と漢字は別の表記() {
        let text = "たなか タナカ 田中"
        for query in ["たなか", "タナカ", "田中"] {
            #expect(TranscriptSearch.ranges(in: text, query: query).map { String(text[$0]) } == [query])
        }
    }
    @Test func 空と一致なしと連続一致とUnicode位置() {
        #expect(TranscriptSearch.ranges(in: "abc", query: "").isEmpty)
        #expect(TranscriptSearch.ranges(in: "", query: "a").isEmpty)
        #expect(TranscriptSearch.ranges(in: "abc", query: "x").isEmpty)
        #expect(TranscriptSearch.ranges(in: "aaaa", query: "aa").count == 2)
        let text = "🦉予算、予算"
        #expect(TranscriptSearch.ranges(in: text, query: "予算").map { NSRange($0, in: text).location } == [2, 5])
    }
}
