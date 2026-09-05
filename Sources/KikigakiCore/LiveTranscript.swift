import Foundation

/// 話者の突き合わせと凍結は全トークンで済ませ、表示へ渡すときだけ文字の確定境界で分ける。
public struct LiveTranscript: Equatable, Sendable {
    public let utterances: [Utterance]
    public let tentativeText: String?

    public init(tokens: [TimedToken], speakers: [Int?], finalCount: Int) {
        let count = min(max(0, finalCount), tokens.count)
        utterances = Aligner.utterances(tokens: Array(tokens.prefix(count)), speakers: Array(speakers.prefix(count)))
        let text = tokens.dropFirst(count).map(\.text).joined()
        tentativeText = text.isEmpty ? nil : text
    }
}
