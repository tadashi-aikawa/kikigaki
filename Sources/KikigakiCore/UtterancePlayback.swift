import Foundation

/// 発言の行から元の音声のその区間だけを流すための区間計算。仕様は docs/utterance-playback.md
///
/// 行の時刻は、話者判別と文字起こしへ流した音声の秒と同じ軸にある。
/// 録音WAVはその音声をそのまま書き、音声ファイルの書き起こしはファイルを頭から流すので、
/// どちらも行の時刻がそのまま元の音声の位置になる。
public enum UtterancePlayback {
    /// 前後へ広げる秒数。文字の時刻は語頭が遅れて付くことがあり、ちょうどの区間だと語頭が切れる
    public static let padding: Double = 0.5

    /// 声の行だけを流す。手入力は音声を持たない
    public static func isPlayable(_ utterance: Utterance) -> Bool {
        utterance.kind == .voice
    }

    /// 流す音声上の区間(秒)。前後へ `padding` ずつ広げ、頭は0で止める。末尾はファイルの長さで `frames` が切る
    public static func range(for utterance: Utterance) -> ClosedRange<Double>? {
        guard isPlayable(utterance) else { return nil }
        let start = max(0, utterance.start - padding)
        let end = max(start, utterance.end + padding)
        return start...end
    }

    /// 区間をファイルのフレームへ直す。ファイルより後ろを指す区間は流すものが無いのでnil
    public static func frames(for range: ClosedRange<Double>, sampleRate: Double, length: Int64) -> (start: Int64, count: Int64)? {
        guard sampleRate > 0, length > 0 else { return nil }
        let start = min(length, max(0, Int64((range.lowerBound * sampleRate).rounded(.down))))
        let end = min(length, max(start, Int64((range.upperBound * sampleRate).rounded(.up))))
        guard end > start else { return nil }
        return (start, end - start)
    }
}
