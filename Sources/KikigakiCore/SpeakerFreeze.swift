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
    public static func advanceByPhrase(
        frozen: [Int?], speakers: [Int?], tokens: [TimedToken], accurateFinalCount: Int, judgedUntil: Double
    ) -> [Int?] {
        let limit = min(tokens.count, speakers.count, max(accurateFinalCount, 0))
        var count = min(frozen.count, limit)
        func horizon(_ token: TimedToken) -> Double { max(token.end, token.midpoint + Aligner.windowHalfSeconds) }
        for phrase in Aligner.phraseRanges(tokens) where phrase.upperBound > count {
            guard phrase.lowerBound == count, phrase.upperBound <= limit,
                  Aligner.endsSentence(tokens[phrase.upperBound - 1]) || phrase.upperBound < limit else { break }
            var reach = phrase.map { horizon(tokens[$0]) }.max() ?? 0
            var held = false
            for k in phrase where SpeechTail.isLongSingle(tokens[k]) {
                guard let next = tokens.indices.dropFirst(k + 1).first(where: { SpeechTail.hasLetter(tokens[$0]) }),
                      next < limit else { held = true; break }
                reach = max(reach, horizon(tokens[next]))
            }
            guard !held, reach <= judgedUntil else { break }
            count = phrase.upperBound
        }
        return Array(speakers.prefix(count))
    }
}
