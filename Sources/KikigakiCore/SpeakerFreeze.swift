import Foundation

/// 話者判定の凍結。話者区間が確定していても、高精度側の未確定文字、後続の文字で伸びるフレーズの多数決、
/// 語境界の補正、長い1文字の尾部確認によって、録音中の話者表示は後から変わり得る。
/// 猶予を過ぎたトークンの判定を凍結し、確定済みの行を後から塗り替えないようにする
public enum SpeakerFreeze {
    /// 録音中の判定を固定するまでの猶予。後続の発話による修正を待つため30秒で試す。
    /// モデルの文脈長や推論遅延とは別の値。停止時は猶予に関係なく全体を再判定する。
    public static let graceSeconds = 30.0

    /// `frozen` を、`elapsed` から猶予を引いた時刻より前に終わるトークンまで伸ばした配列を返す。
    /// 伸ばす分の値は今回の判定 `speakers` から取る。
    /// `judgedUntil` は音声モデルの確定予測範囲。未判定部分を不明のまま凍結しない。
    ///
    /// - finalCount: 先頭から何個までが文字起こしの確定結果に属するか。暫定結果のトークンは
    ///   猶予を過ぎていても凍結しない。話者の多数決はフレーズ単位で、暫定のうちはフレーズが途中で
    ///   トークンが揃っていないため、そこで固めると「59」だけが別話者で残るような分断になる
    ///   (タダシの実録で確認。停止時の判定し直しでは消えるのに録音中だけ出ていた)
    public static func advance(
        frozen: [Int?], speakers: [Int?], tokens: [TimedToken], elapsed: Double, finalCount: Int,
        grace: Double = graceSeconds, judgedUntil: Double = .infinity
    ) -> [Int?] {
        let limit = min(tokens.count, max(finalCount, 0))
        var count = min(frozen.count, limit)
        while count < limit, tokens[count].end < elapsed - grace, tokens[count].end <= judgedUntil {
            // 長い1文字は後続文字で尾部の話者を確認する。次の確定結果がまだ無い時点で
            // 凍結すると、停止後にしか語頭を直せなくなるため、その文字から先を保留する。
            if tokens[count].duration > 0.8,
               tokens[count].text.filter({ $0.isLetter || $0.isNumber }).count == 1,
               !tokens[(count + 1)..<limit].contains(where: { $0.text.contains(where: { $0.isLetter || $0.isNumber }) }) {
                break
            }
            count += 1
        }
        return Array(speakers.prefix(count))
    }

    /// 録音中の凍結方式。`grace30` が本番。`phrase` は試験用
    public enum Mode: String, Sendable, CaseIterable {
        case grace30, phrase
    }

    /// フレーズ確定条件での凍結(試験)。凍結済みの末尾から始まるフレーズを、判定に読む入力が
    /// 全て確定したときだけ丸ごと凍結する。満たさないフレーズで止め、後ろも凍結しない。
    ///
    /// 1. フレーズの全トークンが高精度側で確定済み
    /// 2. 終端が確定: 文末記号で終わるか、次のトークンも高精度側で確定済み。
    ///    速報側のトークンは `phraseId` が負で必ず結果境界になり、後で差し替わるため根拠にしない
    /// 3. `options.tail` のときだけ、長い1文字の後続の有意文字がフレーズ外なら、それも確定済み。
    ///    後続がまだ無ければ保留する。語頭の付け替えが後続の割当を読むため
    /// 4. 判定済み末尾が、読む区間の範囲(各トークンの終端と、中央+窓の半幅)以上。
    ///    `SpeakerRuns` は判定済み範囲の中を後から変えないので、窓・尾部・覆いの判定がこれで固まる
    ///
    /// 停止時はどちらの方式でも凍結を外して全体を判定し直す。
    public static func advanceByPhrase(
        frozen: [Int?], speakers: [Int?], tokens: [TimedToken], accurateFinalCount: Int,
        judgedUntil: Double, options: Aligner.Options = .current
    ) -> [Int?] {
        let limit = min(tokens.count, speakers.count, max(accurateFinalCount, 0))
        var count = min(frozen.count, limit)
        for phrase in Aligner.phraseRanges(tokens) where phrase.upperBound > count {
            guard phrase.lowerBound == count, phrase.upperBound <= limit,
                  Aligner.endsSentence(tokens[phrase.upperBound - 1]) || phrase.upperBound < limit else { break }
            var horizon = phrase.map { max(tokens[$0].end, tokens[$0].midpoint + options.lookahead) }.max() ?? 0
            var held = false
            if options.tail {
                for k in phrase where SpeechTail.isLongSingle(tokens[k]) {
                    guard let next = tokens.indices.dropFirst(k + 1).first(where: { SpeechTail.hasLetter(tokens[$0]) }),
                          next < limit else { held = true; break }
                    horizon = max(horizon, tokens[next].end, tokens[next].midpoint + options.lookahead)
                }
            }
            guard !held, horizon <= judgedUntil else { break }
            count = phrase.upperBound
        }
        return Array(speakers.prefix(count))
    }
}
