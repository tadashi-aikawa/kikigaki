import Foundation
import NaturalLanguage

/// 音声トークンではなく、前後の文脈を含む日本語の語境界を調べる。
/// 候補だけを渡すと「ゃあ」や「そ」も単独の語に見えてしまうため、フレーズ全体を解析する。
struct WordBoundaries {
    private let tokens: [TimedToken]
    private let offsets: [Int]
    private let words: Set<Range<Int>>
    /// 語の両端がASRトークンの端にも一致する場合だけ返す。混在トークンは分割しない。
    var tokenRanges: [Range<Int>] {
        var starts: [Int: Int] = [:]
        var ends: [Int: Int] = [:]
        for i in tokens.indices {
            let text = tokens[i].text
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            starts[offsets[i] + text.prefix(while: Self.ignored).utf16.count] = i
            ends[offsets[i + 1] - String(text.reversed().prefix(while: Self.ignored)).utf16.count] = i + 1
        }
        return words.compactMap { word in
            guard let start = starts[word.lowerBound], let end = ends[word.upperBound], start < end else { return nil }
            return start..<end
        }.sorted { $0.lowerBound < $1.lowerBound }
    }

    init(tokens: [TimedToken]) {
        self.tokens = tokens
        var offsets = [0]
        for token in tokens { offsets.append(offsets.last! + token.text.utf16.count) }
        self.offsets = offsets
        let text = tokens.map(\.text).joined()
        // NLTokenizerはスレッド間で共有しない。日本語ASRに合わせて言語を固定する。
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.japanese)
        tokenizer.string = text
        let ranges = tokenizer.tokens(for: text.startIndex..<text.endIndex).compactMap { range -> Range<Int>? in
            let value = String(text[range])
            let location = NSRange(range, in: text).location
            let start = location + value.prefix(while: Self.ignored).utf16.count
            let end = location + value.utf16.count - String(value.reversed().prefix(while: Self.ignored)).utf16.count
            return start < end ? start..<end : nil
        }
        // NLTokenizerは「なり / ます」を分ける。語尾だけが別話者に見えても、
        // 直前の語と連続する丁寧語尾は一つの語として語内補正の文字数の集計へ渡す。
        // 空白・句読点を越えて接続しない。
        var connected: [Range<Int>] = []
        let tokenEndOffsets = Set(tokens.indices.map {
            offsets[$0 + 1] - String(tokens[$0].text.reversed().prefix(while: Self.ignored)).utf16.count
        })
        for range in ranges {
            let value = (text as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
            if ["ます", "です"].contains(value), let previous = connected.last,
               previous.upperBound == range.lowerBound, tokenEndOffsets.contains(range.upperBound),
               !["ます", "です"].contains(where: (text as NSString).substring(with:
                   NSRange(location: previous.lowerBound, length: previous.count)).hasSuffix) {
                connected[connected.count - 1] = previous.lowerBound..<range.upperBound
            } else {
                connected.append(range)
            }
        }
        words = Set(connected)
    }

    private static func ignored(_ char: Character) -> Bool { char.isWhitespace || char.isPunctuation }
}
