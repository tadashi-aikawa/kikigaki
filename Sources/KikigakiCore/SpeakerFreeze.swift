import Foundation

/// 話者判定の凍結。話者区間が確定していても、高精度側の未確定文字、後続の文字で変わる語境界、
/// 長い1文字の語頭の確認によって、録音中の話者表示は後から変わり得る。
/// 判定に読む入力が全て確定したフレーズを丸ごと凍結し、確定済みの行を後から塗り替えないようにする。
/// 停止時は凍結を外して全体を判定し直す。30秒猶予からの置き換えの経緯: docs/speaker-correction-trial.md
public enum SpeakerFreeze {
    /// 凍結済みの末尾から始まるフレーズを、次の全てを満たすときに丸ごと凍結する。
    /// 満たさないフレーズで止め、後ろも凍結しない。
    ///
    /// 1. フレーズの全トークンが高精度側で確定済み。速報や暫定のうちはフレーズのトークンが揃っていない
    ///    (固めると「59」だけが別話者で残るような分断になった。タダシの実録で確認)
    /// 2. 終端が確定: 文末記号で終わるか、次のトークンも高精度側で確定済み。
    ///    速報側のトークンは `phraseId` が負で必ず結果境界になり、後で差し替わるため根拠にしない
    /// 3. 長い1文字の後続の有意文字がフレーズ外なら、それも確定済み。後続がまだ無ければ保留する。
    ///    `SpeechTail` の語頭の付け替えが後続の割当を読むため。語内の長い語頭の付け替えは同じ語、
    ///    つまり同じフレーズの中だけを読むので、1で足りる
    /// 4. 判定済み末尾 `judgedUntil` が、読む区間の範囲(各トークンの終端と、中央+窓の半幅)以上。
    ///    `SpeakerRuns` は判定済み範囲の中を後から変えないので、窓・尾部の判定がこれで固まる
    ///
    /// 島の補正 `SpeakerIslands.cross` は、フレーズの末尾の島を、間の無い後続のトークンとその次の有意文字で判定する。
    /// その隣の話者は語内補正後の値で、隣のフレーズ全体に依存する。そこで間の無い後続のフレーズを、
    /// 終端から `SpeakerIslands.limitSeconds` を超えた有意文字を含むフレーズまで、1〜4で確定済みにしてから凍結する。
    /// 間の有無は、次のフレーズの先頭が高精度側で確定してから判定する。`cut` と `phrase` は同じフレーズだけを読む
    public static func advanceByPhrase(
        frozen: [Int?], speakers: [Int?], tokens: [TimedToken], accurateFinalCount: Int, judgedUntil: Double,
        islands: SpeakerIslands = .off
    ) -> [Int?] {
        let limit = min(tokens.count, speakers.count, max(accurateFinalCount, 0))
        var count = min(frozen.count, limit)
        func horizon(_ token: TimedToken) -> Double { max(token.end, token.midpoint + Aligner.windowHalfSeconds) }
        let phrases = Aligner.phraseRanges(tokens)
        // フレーズの割当が読む区間の範囲。入力が未確定なら nil
        func reach(of phrase: Range<Int>) -> Double? {
            guard phrase.upperBound <= limit,
                  Aligner.endsSentence(tokens[phrase.upperBound - 1]) || phrase.upperBound < limit else { return nil }
            var reach = phrase.map { horizon(tokens[$0]) }.max() ?? 0
            for k in phrase where SpeechTail.isLongSingle(tokens[k]) {
                guard let next = tokens.indices.dropFirst(k + 1).first(where: { SpeechTail.hasLetter(tokens[$0]) }),
                      next < limit else { return nil }
                reach = max(reach, horizon(tokens[next]))
            }
            return reach
        }
        for (n, phrase) in phrases.enumerated() where phrase.upperBound > count {
            guard phrase.lowerBound == count, var needed = reach(of: phrase) else { break }
            if islands == .cross {
                guard let following = reachOfFollowing(n, phrases: phrases, tokens: tokens, limit: limit, reach: reach) else { break }
                needed = max(needed, following)
            }
            guard needed <= judgedUntil else { break }
            count = phrase.upperBound
        }
        return Array(speakers.prefix(count))
    }

    /// `cross` で n 番目のフレーズの末尾の島が読む、後続のフレーズの範囲。未確定なら nil
    private static func reachOfFollowing(_ n: Int, phrases: [Range<Int>], tokens: [TimedToken], limit: Int,
                                         reach: (Range<Int>) -> Double?) -> Double? {
        let end = tokens[phrases[n].upperBound - 1].end
        var result = 0.0
        for next in phrases.dropFirst(n + 1) {
            guard next.lowerBound < limit else { return nil }
            if tokens[next.lowerBound].start - tokens[next.lowerBound - 1].end >= Aligner.phraseGapSeconds { return result }
            guard let r = reach(next) else { return nil }
            result = max(result, r)
            if next.contains(where: { SpeechTail.hasLetter(tokens[$0]) && tokens[$0].start > end + SpeakerIslands.limitSeconds }) {
                return result
            }
        }
        // 後続がまだ無い。間なしで続くかは次のトークンが来るまで分からない
        return nil
    }
}
