import Foundation

/// 発話行のテキスト整形。書き起こしウィンドウと Markdown の両方が同じ行形式を使う
public enum TranscriptRenderer {
    /// 会議開始からの経過時刻を mm:ss で表す。60分を超えても時を出さず分を伸ばす(桁が揃うほうが
    /// 縦に流れる表示で読みやすい)。実時刻の `MeetingTimeline.clock` とは別物なので名前を分ける
    public static func elapsed(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// `[HH:mm:ss] 話者名: テキスト`。会議開始と一時停止を含む実時刻を使う。
    public static func line(_ utterance: Utterance, names: SpeakerNames,
                            timeline: MeetingTimeline, timeZone: TimeZone = .current) -> String {
        formattedLine(utterance, names: names, stamp: timeline.clock(at: utterance.start, seconds: true, timeZone: timeZone))
    }

    private static func formattedLine(_ utterance: Utterance, names: SpeakerNames, stamp: String) -> String {
        let text = utterance.text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "[\(stamp)] \(names.name(for: utterance.speaker)): \(text)"
    }

    public static func lines(_ utterances: [Utterance], names: SpeakerNames,
                             timeline: MeetingTimeline, timeZone: TimeZone = .current) -> [String] {
        utterances.map { line($0, names: names, timeline: timeline, timeZone: timeZone) }
    }

    public static func text(_ utterances: [Utterance], names: SpeakerNames) -> String {
        // 診断出力は従来どおり音声上の経過を残す。
        utterances.map { formattedLine($0, names: names, stamp: elapsed($0.start)) }.joined(separator: "\n")
    }
}
