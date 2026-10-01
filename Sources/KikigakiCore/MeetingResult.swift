import Foundation

/// 停止時の最終判定。録音中の凍結は使わず、確定した区間で全体を判定し直す(暫定区間で凍結した表示より
/// 確定区間のほうが正確で、保存する Markdown と画面を一致させる。プロトと同じ扱い)
public struct MeetingResult: Equatable, Sendable {
    /// トークンごとの話者。nil はどの話者区間にも当たらなかったもの
    public let speakers: [Int?]
    /// 最終判定の発話行。保存するMarkdownと画面で共有する。
    public let utterances: [Utterance]

    public init(speakers: [Int?], utterances: [Utterance]) {
        self.speakers = speakers
        self.utterances = utterances
    }

    public static func make(tokens: [TimedToken], segments: [SpeakerSegment],
                            mapping: SpeakerMapping = SpeakerMapping()) -> MeetingResult {
        let speakers = mapping.apply(Aligner.speakers(for: tokens, segments: segments))
        let utterances = Aligner.utterances(tokens: tokens, speakers: speakers)
        return MeetingResult(speakers: speakers, utterances: utterances)
    }

    /// 話者なしの会議では最終判定をせず、録音中と同じ境界を使う。
    public static func withoutDiarization(tokens: [TimedToken]) -> MeetingResult {
        MeetingResult(speakers: Array(repeating: nil, count: tokens.count),
                      utterances: UndiarizedTranscript.utterances(tokens: tokens))
    }
}
