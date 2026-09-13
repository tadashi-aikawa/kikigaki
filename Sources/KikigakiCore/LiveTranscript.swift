import Foundation

/// 話者の突き合わせと凍結は全トークンで済ませ、表示へ渡すときだけ文字の確定境界で分ける。
public struct LiveTranscript: Equatable, Sendable {
    public let utterances: [Utterance]
    public let tentativeText: String?
    /// 文字は確定済みだが、未凍結の話者判定を含む発話行の添字。
    public let pendingSpeakerRows: Set<Int>
    private let rowTokenRanges: [Range<Int>]
    private let finalCount: Int
    private let frozenCount: Int
    private let diarizationEnabled: Bool

    public init(tokens: [TimedToken], speakers: [Int?], finalCount: Int, frozenCount: Int = 0,
                diarizationEnabled: Bool = true) {
        let count = min(max(0, finalCount), tokens.count)
        let finalized = Array(tokens.prefix(count))
        let labels = Array(speakers.prefix(count))
        self.finalCount = count
        self.frozenCount = min(max(0, frozenCount), count)
        self.diarizationEnabled = diarizationEnabled
        rowTokenRanges = diarizationEnabled
            ? Aligner.utteranceTokenRanges(tokens: finalized, speakers: labels)
            : UndiarizedTranscript.utteranceTokenRanges(tokens: finalized)
        utterances = rowTokenRanges.map { range in
            Utterance(speaker: diarizationEnabled ? labels[range.lowerBound] : nil,
                      start: finalized[range.lowerBound].start, end: finalized[range.upperBound - 1].end,
                      text: finalized[range].map(\.text).joined().trimmingCharacters(in: .whitespaces))
        }
        pendingSpeakerRows = diarizationEnabled ? Set(rowTokenRanges
            .enumerated().compactMap { $0.element.upperBound > max(0, frozenCount) ? $0.offset : nil })
            : []
        let text = tokens.dropFirst(count).map(\.text).joined()
        tentativeText = text.isEmpty ? nil : text
    }

    /// 同じ合成スナップショットの高精度確定数を必ず渡す。停止結果にはこの表示情報を引き継がない。
    public func progress(accurateFinalCount: Int) -> UtteranceProgress {
        let accurate = min(max(0, accurateFinalCount), finalCount)
        let frozen = min(max(0, frozenCount), accurate)
        let rows: [UtteranceProgress.Stage?] = rowTokenRanges.map { range in
            if range.upperBound > accurate { return .fastFinal }
            if diarizationEnabled && range.upperBound > frozen { return .accurateFinal }
            return nil
        }
        return UtteranceProgress(steps: diarizationEnabled
            ? [.tentative, .fastFinal, .accurateFinal, .speakerFixed]
            : [.tentative, .fastFinal, .accurateFinal],
            rows: rows, tentative: tentativeText != nil ? .tentative : nil)
    }
}
