import Foundation
import NaturalLanguage

/// 音声トークンではなく、前後の文脈を含む日本語の語境界を調べる。
/// 候補だけを渡すと「ゃあ」や「そ」も単独の語に見えてしまうため、フレーズ全体を解析する。
struct WordBoundaries {
    private let tokens: [TimedToken]
    private let offsets: [Int]
    private let starts: Set<Int>
    private let ends: Set<Int>
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
        words = Set(ranges)
        starts = Set(ranges.map(\.lowerBound))
        ends = Set(ranges.map(\.upperBound))
    }

    func containsWholeWords(_ range: Range<Int>) -> Bool {
        let text = tokens[range].map(\.text).joined()
        let leading = text.prefix(while: Self.ignored).utf16.count
        let trailing = String(text.reversed().prefix(while: Self.ignored)).utf16.count
        // 句読点だけや1文字の助詞は独立させない。語の途中を切る境界も救済しない。
        guard text.filter({ $0.isLetter || $0.isNumber }).count >= 2 else { return false }
        let start = offsets[range.lowerBound] + leading
        let end = offsets[range.upperBound] - trailing
        guard start < end, starts.contains(start), ends.contains(end) else { return false }
        // 文中の「経過報告」のような複数語の誤島を広く救済しない。
        // 1語の返答「はい」、または文末まで完結した「すごいね。」から保守的に残す。
        let sentenceEnd = text.trimmingCharacters(in: .whitespacesAndNewlines).last.map { "。！？!?".contains($0) } == true
        return words.contains(start..<end) || sentenceEnd
    }

    private static func ignored(_ char: Character) -> Bool { char.isWhitespace || char.isPunctuation }
}
