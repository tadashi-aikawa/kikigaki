import Foundation

/// 発話行のテキスト整形。書き起こしウィンドウと Markdown の両方が同じ行形式を使う
public enum TranscriptRenderer {
    /// 会議開始からの経過時刻を mm:ss で表す。60分を超えても時を出さず分を伸ばす(桁が揃うほうが
    /// 縦に流れる表示で読みやすい)
    public static func clock(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// `[mm:ss] 話者名: テキスト`。テキスト中の改行は1行1発話を保つため空白にする
    public static func line(_ utterance: Utterance, names: SpeakerNames) -> String {
        let text = utterance.text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "[\(clock(utterance.start))] \(names.name(for: utterance.speaker)): \(text)"
    }

    public static func lines(_ utterances: [Utterance], names: SpeakerNames) -> [String] {
        utterances.map { line($0, names: names) }
    }

    public static func text(_ utterances: [Utterance], names: SpeakerNames) -> String {
        lines(utterances, names: names).joined(separator: "\n")
    }
}
