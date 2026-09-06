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
        // NLTokenizerは「なり / ます」を分ける。語尾だけが別話者に見えても、
        // 直前の語と連続する丁寧語尾は一つの語として文字多数決へ渡す。
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
        starts = Set(connected.map(\.lowerBound))
        ends = Set(connected.map(\.upperBound))
    }

    func containsWholeWords(_ range: Range<Int>, sentenceEndAllowed: Bool = true) -> Bool {
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
        return words.contains(start..<end) || (sentenceEndAllowed && sentenceEnd)
    }

    /// 句点が認識されなくても、語境界で閉じた質問・否定・依頼は意味のある短い発言として扱う。
    /// 一般の複数語を全て保護すると、文中の誤った話者の島も残るため範囲を限定する。
    func containsMeaningfulReply(_ range: Range<Int>) -> Bool {
        let text = tokens[range].map(\.text).joined()
        let leading = text.prefix(while: Self.ignored).utf16.count
        let trailing = String(text.reversed().prefix(while: Self.ignored)).utf16.count
        let start = offsets[range.lowerBound] + leading
        let end = offsets[range.upperBound] - trailing
        guard start < end, starts.contains(start), ends.contains(end) else { return false }
        let prefix = tokens[..<range.lowerBound].map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.isEmpty || prefix.last?.isPunctuation == true else { return false }
        let following = tokens[range.upperBound...].map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !following.hasPrefix("どうか") else { return false }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        return ["ですか", "ますか"]
            .contains(where: value.hasSuffix)
    }

    /// 相槌・応答の語彙。多数派の声が島を覆っていても保護する1語で、消す一覧ではない。
    /// 重なった相手の「うん」が文字になったとき、主話者の本文へ混ぜないためのもの。
    /// 品詞(NLTagger の lexicalClass)は日本語で提供されないため、語彙で限定する
    static let backchannelWords: Set<String> = [
        "はい", "はいはい", "うん", "うんうん", "ええ", "そう", "そうそう", "そうですね", "そうなんですね",
        "なるほど", "いや", "いいえ", "確かに", "本当", "ほんと", "本当に", "ほんとに", "ですね", "ですよね",
        "おお", "へえ", "ふーん", "了解", "了解です", "オッケー", "はーい", "いえ", "まあ", "うーん",
    ]

    /// 空白・句読点を除いた本文が相槌・応答の語彙に一致するか
    func isBackchannel(_ range: Range<Int>) -> Bool {
        let text = tokens[range].map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        return Self.backchannelWords.contains(text)
    }

    private static func ignored(_ char: Character) -> Bool { char.isWhitespace || char.isPunctuation }
}
