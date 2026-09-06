import Foundation

/// 話者の突き合わせと凍結は全トークンで済ませ、表示へ渡すときだけ文字の確定境界で分ける。
public struct LiveTranscript: Equatable, Sendable {
    public let utterances: [Utterance]
    public let tentativeText: String?
    /// 文字は確定済みだが、未凍結の話者判定を含む発話行の添字。
    public let pendingSpeakerRows: Set<Int>

    public init(tokens: [TimedToken], speakers: [Int?], finalCount: Int, frozenCount: Int = 0) {
        let count = min(max(0, finalCount), tokens.count)
        let finalized = Array(tokens.prefix(count))
        let labels = Array(speakers.prefix(count))
        utterances = Aligner.utterances(tokens: finalized, speakers: labels)
        pendingSpeakerRows = Set(Aligner.utteranceTokenRanges(tokens: finalized, speakers: labels)
            .enumerated().compactMap { $0.element.upperBound > max(0, frozenCount) ? $0.offset : nil })
        let text = tokens.dropFirst(count).map(\.text).joined()
        tentativeText = text.isEmpty ? nil : text
    }
}
