import Foundation

/// 文字起こしのトークン時刻と話者判別の区間を突き合わせ、話者ごとの発話行にまとめる。
/// プロト(fluidaudio-sandbox の LiveScribe/Aligner.swift)からの移植。判断の根拠は各関数のコメント
public enum Aligner {
    /// 発話行を分ける無音の長さ(秒)。同じ話者でもこれ以上空けば別の行にする
    public static let utteranceGapSeconds = 1.0
    /// フレーズを切る無音の長さ(秒)
    public static let phraseGapSeconds = 0.35
    /// フレーズ内で別話者がこの長さ以上続く塊は、多数決から独立させる(秒)。
    /// より短くても、語境界で完結する1語か文末までの塊は独立させる。
    /// Apple のトークンは単語級で1個でも 0.5 秒を超えるため、本当の発話交代とみなせる 1.5 秒に
    /// しないと語の分断が残る(実測)
    public static let keepIslandSeconds = 1.5

    /// 時刻 t の話者を決める。t の前後 `halfWindow` 秒の窓と各話者区間の重なり長を話者ごとに合計し、
    /// 最大の話者を採る(窓なしの点判定だと 0.3 秒程度の細切れ区間に引きずられて話者が飛び飛びになる)。
    /// 重なりが無ければ nil
    public static func speaker(at t: Double, segments: [SpeakerSegment], halfWindow: Double = 0.5, tiesAreUnknown: Bool = false) -> Int? {
        var overlap: [Int: Double] = [:]
        let lo = t - halfWindow, hi = t + halfWindow
        for s in segments {
            let o = min(hi, s.end) - max(lo, s.start)
            guard o > 0 else { continue }
            overlap[s.speaker, default: 0] += o
        }
        // 表示の同点は従来の番号順。文字を省く判断では、同点を根拠に別話者と断定しない。
        if tiesAreUnknown, let best = overlap.values.max(), overlap.values.filter({ abs($0 - best) < 1e-9 }).count > 1 {
            return nil
        }
        return argmax(overlap)
    }

    /// 重み最大の話者。同点は番号の小さい話者に倒す。Swift の Dictionary はインスタンスごとに
    /// 反復順が変わるので、`max(by:)` に同点を任せると呼ぶたびに答えが変わる(実測: 同じ入力で
    /// 表示と保存の話者が食い違った)
    public static func argmax(_ weights: [Int: Double]) -> Int? {
        weights.sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }.first?.key
    }

    /// 各トークンの話者を決める。`frozen` に入っている先頭部分はそのまま使い(確定済みの行を後から
    /// 塗り替えないため)、残りだけ区間から判定する。
    ///
    /// トークンごとに区間から引き、語内の境界を補正してからフレーズ単位で揃える。
    /// フレーズの多数派は語内補正前に固定する。
    /// トークン単位のままだと、相槌の重なりや話者区間の数百msのずれが語の途中に切れ目を作る
    /// (「い / や本当に」のような分断。タダシの実録で確認)。フレーズの中で別話者が `keepIslandSeconds`
    /// 以上続く塊と、語境界で完結する短い1語・文末の塊は独立させる
    public static func speakers(
        for tokens: [TimedToken], segments: [SpeakerSegment], frozen: [Int?] = [],
        gapSeconds: Double = phraseGapSeconds, keepIslandSeconds: Double = keepIslandSeconds
    ) -> [Int?] {
        var speakers = Array(frozen.prefix(tokens.count))
        let observed = SpeechTail.speakers(tokens: tokens, segments: segments, skippingPrefix: speakers.count)
        speakers.append(contentsOf: observed.dropFirst(speakers.count))
        return smoothSpeakers(tokens: tokens, speakers: speakers, frozenCount: frozen.count,
                              gapSeconds: gapSeconds, keepIslandSeconds: keepIslandSeconds,
                              evidenceWeights: SpeechTail.evidenceWeights(tokens: tokens, speakers: speakers, segments: segments),
                              segments: segments)
    }

    /// 窓判定の観測値を回帰テストへ渡せるよう、音声区間との突き合わせと分ける。
    static func smoothSpeakers(tokens: [TimedToken], speakers initial: [Int?], frozenCount: Int = 0,
                               gapSeconds: Double = phraseGapSeconds, keepIslandSeconds: Double = keepIslandSeconds,
                               evidenceWeights: [Double]? = nil, segments: [SpeakerSegment] = []) -> [Int?] {
        var speakers = initial
        let orderedSegments = segments.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        for phrase in phraseRanges(tokens, gapSeconds: gapSeconds) {
            // 全体が凍結済みのフレーズは、どの経路も書き込まない。語内補正は `word.lowerBound >= frozenCount`
            // で入らず `correctedWords` は空のまま、島の吸収も `k >= frozenCount` で守られる。
            // 語境界の解析(NLTokenizer)だけが毎回走るので飛ばす。長い会議の録音中に効く
            if phrase.upperBound <= frozenCount { continue }
            let words = WordBoundaries(tokens: Array(tokens[phrase]))
            let lexicalRanges = words.tokenRanges.map { ($0.lowerBound + phrase.lowerBound)..<($0.upperBound + phrase.lowerBound) }
            // 語内補正前の時間重みで多数決。長い1文字は検出された声の時間に絞る。
            var weight: [Int: Double] = [:]
            for i in phrase {
                if let s = speakers[i] { weight[s, default: 0] += max(evidenceWeights?[i] ?? tokens[i].duration, 0.04) }
            }
            guard let major = argmax(weight) else { continue }
            // 多数派は補正前の時間重みで固定する。長い語頭を動かしてもフレーズ全体を反転させない。
            var correctedWords: [Range<Int>] = []
            for word in lexicalRanges {
                guard word.lowerBound >= frozenCount,
                      word.allSatisfy({ initial[$0] != nil && tokens[$0].duration.isFinite && tokens[$0].duration > 0 }) else { continue }
                var counts: [Int: Int] = [:]
                for k in word {
                    counts[initial[k]!, default: 0] += tokens[k].text.filter { $0.isLetter || $0.isNumber }.count
                }
                let total = counts.values.reduce(0, +)
                guard let winner = counts.first(where: { $0.value * 2 > total })?.key,
                      word.contains(where: { initial[$0] != winner }) else { continue }
                // ASRの語頭は前の発話や無音を含んで長くなる。ここだけは時間ではなく文字数を使う。
                // 同点は語末などへ決め打ちしない。元の境界を残す。
                for k in word { speakers[k] = winner }
                correctedWords.append(word)
            }
            // 多数派と違う短い塊を多数派に揃える(凍結済みは触らない)
            var i = phrase.lowerBound
            while i < phrase.upperBound {
                var j = i
                while j < phrase.upperBound && speakers[j] == speakers[i] { j += 1 }
                if speakers[i] != major {
                    let coreWords = lexicalRanges.filter { $0.lowerBound >= i && $0.upperBound <= j }
                    // 戻す側の隣も多数派である場合だけ端を戻す。第三話者への交代を多数派で埋めない。
                    if speakers[i] != nil, coreWords.count >= 2, let first = coreWords.first, let last = coreWords.last,
                       Self.hasShortRepairedEdge(first: first, last: last, correctedWords: correctedWords,
                                                 initial: initial, tokens: tokens, phrase: phrase,
                                                 speaker: speakers[i]!, limit: keepIslandSeconds),
                       (first.lowerBound == i || (i > phrase.lowerBound && speakers[i - 1] == major)),
                       (last.upperBound == j || (j < phrase.upperBound && speakers[j] == major)) {
                        // 「ゃあ…そ」→「じゃあ…そ」と語頭を修復できた場合だけ、
                        // 完全な語の核を残し、末尾の「そ」のような部分語を周囲へ戻す。
                        for k in i..<first.lowerBound where k >= frozenCount { speakers[k] = major }
                        for k in last.upperBound..<j where k >= frozenCount { speakers[k] = major }
                        i = j
                        continue
                    }
                    let span = tokens[j - 1].end - tokens[i].start
                    if span < keepIslandSeconds {
                        // 「すごいね。」は0.84秒でも別話者の返答だった。短さだけで吸収せず、
                        // 語境界で完結する塊は残す。上の境界補正でも完結しない部分語は従来通り。
                        if speakers[i] != nil {
                            let local = (i - phrase.lowerBound)..<(j - phrase.lowerBound)
                            // 多数派の声が区間全体を覆う場合、句点だけを根拠に複数語の島を
                            // 保護しない。一語の返答と、境界から始まる質問の保護は残す。
                            var coveredUntil = tokens[i].start
                            for segment in orderedSegments where segment.speaker == major {
                                if segment.end <= coveredUntil { continue }
                                if segment.start > coveredUntil + 0.01 { break }
                                coveredUntil = segment.end
                            }
                            let coveredByMajor = coveredUntil >= tokens[j - 1].end
                            if words.containsWholeWords(local, sentenceEndAllowed: !coveredByMajor)
                                || (span >= 0.6 && words.containsMeaningfulReply(local)) { i = j; continue }
                        }
                        for k in i..<j where k >= frozenCount { speakers[k] = major }
                    }
                }
                i = j
            }
        }
        // 句読点だけのトークンは直前のトークンの話者に付ける(凍結済みは触らない)。句点は直前の文の
        // 一部で、時刻が次の発話の頭に食い込むと別話者に判定され「。」だけの行になる(実録で確認)
        for i in speakers.indices where i >= frozenCount && i > 0 && isPunctuationOnly(tokens[i]) {
            speakers[i] = speakers[i - 1]
        }
        return speakers
    }

    private static func hasShortRepairedEdge(first: Range<Int>, last: Range<Int>, correctedWords: [Range<Int>],
                                             initial: [Int?], tokens: [TimedToken], phrase: Range<Int>,
                                             speaker: Int, limit: Double) -> Bool {
        for word in correctedWords where word == first || word == last {
            guard let anchor = word.first(where: { initial[$0] == speaker }) else { continue }
            var start = anchor, end = anchor + 1
            while start > phrase.lowerBound && initial[start - 1] == speaker { start -= 1 }
            while end < phrase.upperBound && initial[end] == speaker { end += 1 }
            let movedStart = word == first && start > first.lowerBound && start < first.upperBound
            let movedEnd = word == last && end > last.lowerBound && end < last.upperBound
            // 元から長い島や、島の内部だけの補正で複数語を新しく保護しない。
            // 「じ」を取り戻すと1.5秒を超えるため、長さは補正前の連続raw島で判定する。
            if (movedStart || movedEnd), start < first.upperBound, end > last.lowerBound,
               tokens[end - 1].end - tokens[start].start < limit { return true }
        }
        return false
    }

    /// 句読点・空白だけのトークンか
    static func isPunctuationOnly(_ token: TimedToken) -> Bool {
        let trimmed = token.text.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.allSatisfy { "。、！？!?,.".contains($0) }
    }

    /// エンジンの結果境界(phraseId の変化)をフレーズの切れ目として数える最小の無音(秒)。
    /// Apple の確定結果の境界は語の途中にも落ちる(「読 / みやすい」「わ / かりました」)。無音を
    /// ほぼ挟まない境界は発話の区切りではないので、フレーズを切らずに多数決へ含める。
    /// プロトでは「0.4秒未満の1トークンだけ次へ寄せる」救済だったが、1文字が0.4秒を超える
    /// 喋り方で救済から漏れて1文字の行が残った(タダシの実録で確認)
    public static let resultBoundaryGapSeconds = 0.2

    /// フレーズの切れ目: 直前との間が `gapSeconds` 以上空く / 直前が文末の句点 /
    /// エンジンのフレーズ id が変わり、かつ直前との間が `resultBoundaryGapSeconds` 以上空く
    public static func phraseRanges(_ tokens: [TimedToken], gapSeconds: Double = phraseGapSeconds) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        for i in 1..<max(tokens.count, 1) {
            let prev = tokens[i - 1]
            let gap = tokens[i].start - prev.end
            let boundary =
                gap >= gapSeconds
                || endsSentence(prev)
                || (tokens[i].phraseId != prev.phraseId && gap >= resultBoundaryGapSeconds)
            if boundary {
                ranges.append(start..<i)
                start = i
            }
        }
        if start < tokens.count { ranges.append(start..<tokens.count) }
        return ranges
    }

    /// 文末の句点・感嘆符・疑問符で終わるトークンか
    static func endsSentence(_ token: TimedToken) -> Bool {
        token.text.last.map { "。！？!?".contains($0) } == true
    }

    /// トークン列と話者列を発話行にまとめる。同じ話者でもトークン間が `gap` 秒以上空けば行を分ける
    public static func utterances(tokens: [TimedToken], speakers: [Int?], gap: Double = utteranceGapSeconds) -> [Utterance] {
        var result: [Utterance] = []
        for (tok, spk) in zip(tokens, speakers) {
            if var last = result.last, last.speaker == spk, tok.start - last.end < gap {
                last.text += tok.text
                last.end = tok.end
                result[result.count - 1] = last
            } else {
                result.append(Utterance(speaker: spk, start: tok.start, end: tok.end, text: tok.text))
            }
        }
        for i in result.indices {
            result[i].text = result[i].text.trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
