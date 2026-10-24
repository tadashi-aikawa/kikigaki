import Foundation

/// 1会議1ファイルの Markdown。録音中は `InterimSave` が途中の記録を書き、停止時に保存し、
/// 話者名を付け直したら同じ内容構造で保存し直す
public enum MeetingMarkdown {
    /// 会議の基本情報。Markdown の見出しとメタ行に使う
    public struct Meeting: Codable, Equatable, Sendable {
        public var startedAt: Date
        /// 実際に音声を流した長さ(秒)。一時停止中は含まない
        public var duration: Double
        public var utterances: [Utterance]
        public var names: SpeakerNames
        public var pauses: [MeetingTimeline.Pause]
        public var ai: AIConversation?
        public var audioLevels: AudioLevelTrack?
        public var audioExclusion: AudioExclusion?
        public var showAudioLevels: Bool?
        /// 音声ファイルの書き起こしで音源にしたファイル名。録音の会議と旧archiveはnil
        public var sourceAudio: String?
        public var displaysAudioLevels: Bool { showAudioLevels ?? (audioLevels != nil) }
        public var timeline: MeetingTimeline { MeetingTimeline(startedAt: startedAt, pauses: pauses) }

        public init(startedAt: Date, duration: Double, utterances: [Utterance], names: SpeakerNames,
                    pauses: [MeetingTimeline.Pause] = [], ai: AIConversation? = nil, audioLevels: AudioLevelTrack? = nil) {
            self.startedAt = startedAt
            self.duration = duration
            self.utterances = utterances
            self.names = names
            self.pauses = pauses
            self.ai = ai
            self.audioLevels = audioLevels
        }
    }

    /// `interimSavedAt` は録音中の途中保存の時刻。異常終了で残った記録だと開いた人に分かるよう状態の行を出す。
    /// 停止後の保存では渡さないので、正常に停止した記録には残らない
    public static func render(_ meeting: Meeting, interimSavedAt: Date? = nil, timeZone: TimeZone = .current) -> String {
        let stamp = formatter(timeZone: timeZone).string(from: meeting.startedAt)
        var lines: [String] = []
        lines.append("# KIKIGAKI \(stamp)")
        lines.append("")
        lines.append("- 開始: \(stamp)")
        lines.append("- 長さ: \(TranscriptRenderer.elapsed(meeting.duration))")
        if let sourceAudio = meeting.sourceAudio {
            // 改行を含むファイル名でもメタ行の外へ書き出さない。
            lines.append("- 音声: " + sourceAudio.split(whereSeparator: \.isNewline).joined(separator: " "))
        }
        if let interimSavedAt {
            let clock = formatter(timeZone: timeZone, format: "HH:mm:ss").string(from: interimSavedAt)
            lines.append("- 状態: 録音中の途中保存 (\(clock))")
        }
        let speakers = appearingSlots(meeting.utterances)
        if !speakers.isEmpty {
            let list = speakers.map { "\(SpeakerNames.letter(for: $0))=\(meeting.names.name(for: $0))" }
            lines.append("- 話者: " + list.joined(separator: ", "))
        }
        lines.append("")
        lines.append("## 書き起こし")
        lines.append("")
        // 箇条書きにするのは、素の行を並べると Markdown レンダラが1段落に繋げてしまうため
        let exclusion = meeting.audioExclusion ?? AudioExclusion()
        var included = meeting
        included.utterances = exclusion.included(meeting.utterances, track: meeting.audioLevels)
        lines += AIMarkdown.transcriptLines(included, timeZone: timeZone)
        let excluded = meeting.utterances.filter { exclusion.excludes($0, track: meeting.audioLevels) }
        if !excluded.isEmpty {
            lines += ["", "## 小音量で除外した発話", "", exclusion.label + "。元の発話は以下に保持します。", ""]
            lines += excluded.map { "- " + TranscriptRenderer.line($0, names: meeting.names, timeline: meeting.timeline, timeZone: timeZone) + " — 小音量のため除外" }
        }
        if let ai = meeting.ai, !ai.questions.isEmpty {
            lines.append("")
            lines.append(AIMarkdown.section(ai, timeZone: timeZone))
        }
        if meeting.displaysAudioLevels, let track = meeting.audioLevels {
            lines += ["", "## 音量の計測", "", exclusion.label + "。候補表示はしきい値との比較です。", "",
                      "| 時刻 | 話者 | 音量 |", "|---|---|---|"]
            for (utterance, assessment) in zip(meeting.utterances, track.assessments(for: meeting.utterances, exclusion: meeting.audioExclusion)) {
                guard let assessment else { continue }
                let name = meeting.names.displayName(for: utterance).replacingOccurrences(of: "|", with: "&#124;")
                let clock = TranscriptRenderer.clock(for: utterance, timeline: meeting.timeline, timeZone: timeZone)
                lines.append("| \(clock) | \(name) | \(assessment.label) |")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 発話に現れた話者スロットを番号順に(話者なし=nil は除く)
    static func appearingSlots(_ utterances: [Utterance]) -> [Int] {
        Array(Set(utterances.compactMap(\.speaker))).sorted()
    }

    static func formatter(timeZone: TimeZone, format: String = "yyyy-MM-dd HH:mm") -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }
}
