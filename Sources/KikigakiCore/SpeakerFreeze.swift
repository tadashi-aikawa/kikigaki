import Foundation

/// 話者判定の凍結。Sortformer の暫定区間は「直近数秒」ではなく連続発話の長さぶん過去へ届くため
/// (実測 8.6 秒)、そのまま再判定し続けると1分以上前の行の話者境界が再描画のたびに往復する。
/// 猶予を過ぎたトークンの判定を凍結し、確定済みの行を後から塗り替えないようにする
public enum SpeakerFreeze {
    /// 判定を凍結するまでの猶予(秒)。Sortformer の暫定区間(FIFO 約3秒+右文脈)が確定してから
    /// 凍結するため、その遅延より長く取る
    public static let graceSeconds = 8.0

    /// `frozen` を、`elapsed` から猶予を引いた時刻より前に終わるトークンまで伸ばした配列を返す。
    /// 伸ばす分の値は今回の判定 `speakers` から取る。
    ///
    /// - finalCount: 先頭から何個までが文字起こしの確定結果に属するか。暫定結果のトークンは
    ///   猶予を過ぎていても凍結しない。話者の多数決はフレーズ単位で、暫定のうちはフレーズが途中で
    ///   トークンが揃っていないため、そこで固めると「59」だけが別話者で残るような分断になる
    ///   (タダシの実録で確認。停止時の判定し直しでは消えるのに録音中だけ出ていた)
    public static func advance(
        frozen: [Int?], speakers: [Int?], tokens: [TimedToken], elapsed: Double, finalCount: Int,
        grace: Double = graceSeconds
    ) -> [Int?] {
        let limit = min(tokens.count, max(finalCount, 0))
        var count = min(frozen.count, limit)
        while count < limit, tokens[count].end < elapsed - grace {
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
}
