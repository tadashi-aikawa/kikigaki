import Foundation

/// 話し手の声が続いているのに、重なった別話者へ割れた短い島を、両隣の話者へ戻す補正の段階。
/// 採用前の比較用で、既定は `off`。段階は適用範囲だけを広げ、`cut` ⊂ `phrase` ⊂ `cross` の包含関係にある。
/// 設計と比較: docs/speaker-overlap-islands.md
///
/// 有意文字のトークンで同じ話者が続く塊を島と呼ぶ。島(話者X)を次の全てを満たすときに両隣の話者Yへ戻す。
/// - 直前と直後の有意文字がどちらも同じ既知話者Yで、Xも既知でYと違う
/// - 島の長さが `limitSeconds` 以下
/// - 島の各有意文字に、Yの声が `min(文字の長さ, voiceSeconds)` 以上重なる
/// - 段階の範囲: `cut` は同じフレーズで島の端が語を切る、`phrase` は同じフレーズ、`cross` は間の無い後続まで
///
/// 限界: Yの声が重なる中でXが実際に言った「はい」なども、`phrase` と `cross` では戻す。相槌の辞書では隠さない
public enum SpeakerIslands: String, CaseIterable, Codable, Sendable {
    case off, cut, phrase, cross

    static let limitSeconds = 1.5
    static let voiceSeconds = 0.12

    /// 補正前のラベル `base` から島を戻し、先頭を凍結済みの `frozen` で置き換えて返す。
    /// 凍結済みの行から始まる島は、凍結済みの部分が既に戻っている場合だけ後半も戻す。
    /// 判定は補正前のラベルだけで行い、戻した島や凍結済みのラベルを別の島の隣の根拠にしない
    func apply(tokens: [TimedToken], base: [Int?], segments: [SpeakerSegment], frozen: [Int?] = []) -> [Int?] {
        let frozenCount = min(frozen.count, base.count)
        var speakers = Array(frozen.prefix(frozenCount)) + base.dropFirst(frozenCount)
        guard self != .off else { return speakers }
        let phrases = Aligner.phraseRanges(tokens)
        var phraseOf = [Int](repeating: 0, count: tokens.count)
        for (n, phrase) in phrases.enumerated() { for i in phrase { phraseOf[i] = n } }
        let letters = tokens.indices.filter { SpeechTail.hasLetter(tokens[$0]) }
        var a = 1
        while a < letters.count {
            guard let x = base[letters[a]], let y = base[letters[a - 1]], x != y else { a += 1; continue }
            var b = a
            while b + 1 < letters.count && base[letters[b + 1]] == x { b += 1 }
            defer { a = b + 1 }
            guard b + 1 < letters.count, base[letters[b + 1]] == y, letters[b] >= frozenCount else { continue }
            let left = letters[a - 1], first = letters[a], last = letters[b], right = letters[b + 1]
            guard tokens[last].end - tokens[first].start <= Self.limitSeconds,
                  (a...b).allSatisfy({ Self.voice(of: y, on: tokens[letters[$0]], segments: segments) }) else { continue }
            switch self {
            case .off: continue
            case .cut:
                guard phraseOf[left] == phraseOf[right],
                      Self.cutsWord(first: first, last: last, tokens: tokens, phrase: phrases[phraseOf[first]]) else { continue }
            case .phrase:
                guard phraseOf[left] == phraseOf[right] else { continue }
            case .cross:
                guard (left..<right).allSatisfy({ tokens[$0 + 1].start - tokens[$0].end < Aligner.phraseGapSeconds }) else { continue }
            }
            // 凍結済みの前半が戻っていない島の後半だけを戻さない
            guard (a...b).allSatisfy({ letters[$0] >= frozenCount || speakers[letters[$0]] == y }) else { continue }
            for k in first...last where k >= frozenCount { speakers[k] = y }
        }
        return speakers
    }

    static func voice(of speaker: Int, on token: TimedToken, segments: [SpeakerSegment]) -> Bool {
        let overlap = segments.filter { $0.speaker == speaker }
            .reduce(0) { $0 + max(0, min(token.end, $1.end) - max(token.start, $1.start)) }
        return overlap >= min(token.duration, voiceSeconds) - 1e-9
    }

    /// 島の先頭か末尾の境界が、フレーズの語の内側にあるか
    static func cutsWord(first: Int, last: Int, tokens: [TimedToken], phrase: Range<Int>) -> Bool {
        let words = WordBoundaries(tokens: Array(tokens[phrase])).tokenRanges
            .map { ($0.lowerBound + phrase.lowerBound)..<($0.upperBound + phrase.lowerBound) }
        return words.contains { ($0.lowerBound < first && first < $0.upperBound) || ($0.lowerBound <= last && last + 1 < $0.upperBound) }
    }

    /// 凍結境界の手前で補正前のラベルを計算し直す先頭。境界に触れる島は `limitSeconds` 以内に始まり、
    /// その直前の有意文字を隣として読む。その文字のフレーズの先頭から計算し直せば、語内補正も同じ値になる。
    /// 凍結済みの範囲は入力が確定しているので、計算し直しても凍結時と同じ補正前のラベルになる
    func recomputeStart(tokens: [TimedToken], frozenCount: Int) -> Int {
        guard self != .off, frozenCount > 0, frozenCount < tokens.count else { return frozenCount }
        let horizon = tokens[frozenCount].start - Self.limitSeconds
        guard let anchor = tokens.indices.prefix(frozenCount).last(where: {
            SpeechTail.hasLetter(tokens[$0]) && tokens[$0].start < horizon
        }) else { return 0 }
        return Aligner.phraseRanges(tokens).first { $0.contains(anchor) }?.lowerBound ?? 0
    }
}
