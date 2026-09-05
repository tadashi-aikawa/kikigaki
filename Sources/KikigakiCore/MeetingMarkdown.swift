import Foundation

/// 1会議1ファイルの Markdown。停止時に保存し、話者名を付け直したら同じ内容構造で保存し直す
public enum MeetingMarkdown {
    /// 会議の基本情報。Markdown の見出しとメタ行に使う
    public struct Meeting: Equatable, Sendable {
        public var startedAt: Date
        /// 実際に音声を流した長さ(秒)。一時停止中は含まない
        public var duration: Double
        public var utterances: [Utterance]
        public var names: SpeakerNames
        public var pauses: [MeetingTimeline.Pause]
        public var timeline: MeetingTimeline { MeetingTimeline(startedAt: startedAt, pauses: pauses) }

        public init(startedAt: Date, duration: Double, utterances: [Utterance], names: SpeakerNames,
                    pauses: [MeetingTimeline.Pause] = []) {
            self.startedAt = startedAt
            self.duration = duration
            self.utterances = utterances
            self.names = names
            self.pauses = pauses
        }
    }

    public static func render(_ meeting: Meeting, timeZone: TimeZone = .current) -> String {
        let stamp = formatter(timeZone: timeZone).string(from: meeting.startedAt)
        var lines: [String] = []
        lines.append("# KIKIGAKI \(stamp)")
        lines.append("")
        lines.append("- 開始: \(stamp)")
        lines.append("- 長さ: \(TranscriptRenderer.clock(meeting.duration))")
        let speakers = appearingSlots(meeting.utterances)
        if !speakers.isEmpty {
            let list = speakers.map { "\(SpeakerNames.letter(for: $0))=\(meeting.names.name(for: $0))" }
            lines.append("- 話者: " + list.joined(separator: ", "))
        }
        lines.append("")
        lines.append("## 書き起こし")
        lines.append("")
        // 箇条書きにするのは、素の行を並べると Markdown レンダラが1段落に繋げてしまうため
        for utterance in meeting.utterances {
            lines.append("- " + TranscriptRenderer.line(utterance, names: meeting.names, timeline: meeting.timeline, timeZone: timeZone))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 発話に現れた話者スロットを番号順に(話者なし=nil は除く)
    static func appearingSlots(_ utterances: [Utterance]) -> [Int] {
        Array(Set(utterances.compactMap(\.speaker))).sorted()
    }

    static func formatter(timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }
}
