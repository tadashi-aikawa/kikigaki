import Foundation

/// 停止時の最終判定。録音中の凍結は使わず、確定した区間で全体を判定し直す(暫定区間で凍結した表示より
/// 確定区間のほうが正確で、保存する Markdown と画面を一致させる。プロトと同じ扱い)
public struct MeetingResult: Equatable, Sendable {
    /// トークンごとの話者。nil はどの話者区間にも当たらなかったもの
    public let speakers: [Int?]
    /// 省略前の発話行。`.raw.md` と、省略が無効なときの `.md` と画面に出る
    public let utterances: [Utterance]
    /// 繰り返し相槌を省いた発話行。省略が無効なら nil
    public let processed: [Utterance]?
    /// 省略候補のトークン範囲。省略が無効なら空
    public let candidates: [Range<Int>]

    public init(speakers: [Int?], utterances: [Utterance], processed: [Utterance]?, candidates: [Range<Int>]) {
        self.speakers = speakers
        self.utterances = utterances
        self.processed = processed
        self.candidates = candidates
    }

    public static func make(tokens: [TimedToken], segments: [SpeakerSegment],
                            dropRepeatedBackchannels: Bool, mapping: SpeakerMapping = SpeakerMapping()) -> MeetingResult {
        let speakers = mapping.apply(Aligner.speakers(for: tokens, segments: segments))
        let utterances = Aligner.utterances(tokens: tokens, speakers: speakers)
        guard dropRepeatedBackchannels else {
            return MeetingResult(speakers: speakers, utterances: utterances, processed: nil, candidates: [])
        }
        // 多数決前の窓判定も渡す。多数決で吸収された相槌を、元の話者で拾い直すため
        let raw = tokens.map { mapping.destination(for: Aligner.speaker(at: $0.midpoint, segments: segments, tiesAreUnknown: true)) }
        let candidates = RepeatedBackchannels.candidates(tokens: tokens, rawSpeakers: raw, speakers: speakers)
        let processed = RepeatedBackchannels.utterances(tokens: tokens, speakers: speakers, omitting: candidates)
        return MeetingResult(speakers: speakers, utterances: utterances, processed: processed, candidates: candidates)
    }
}
