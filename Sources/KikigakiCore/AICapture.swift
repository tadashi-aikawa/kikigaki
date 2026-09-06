import Foundation

/// Enter時点の音声位置で切る。後から到着したASRでも、上限以降に始まった語は加えない。
public struct AICapture: Equatable, Sendable {
    public let lines: [String]
    public let voice: String
    public let voiceUtteranceStart: Double?
    public let tail: AITentativeTail?
    public let needsConfirmation: Bool

    public init(tokens: [TimedToken], speakers: [Int?], finalCount: Int, processedUntil: Double,
                cutoff: Double, names: SpeakerNames, timeline: MeetingTimeline) throws {
        guard cutoff.isFinite, cutoff >= 0, processedUntil.isFinite, processedUntil >= 0,
              finalCount >= 0, finalCount <= tokens.count, speakers.count == tokens.count,
              tokens.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }),
              zip(tokens, tokens.dropFirst()).allSatisfy({ $0.start <= $1.start }) else { throw AIError.invalid("capture boundary") }
        let count = tokens.prefix { $0.start < cutoff }.count
        let fixed = tokens.prefix(min(finalCount, count)).prefix { $0.end <= cutoff }.count
        let utterances = Aligner.utterances(tokens: Array(tokens.prefix(fixed)), speakers: Array(speakers.prefix(fixed)))
        lines = utterances.map { TranscriptRenderer.line($0, names: names, timeline: timeline) }
        let pending = Array(tokens[fixed..<count])
        let text = pending.map(\.text).joined()
        if let first = pending.first, let last = pending.last, !text.isEmpty {
            tail = AITentativeTail(text: text, startSeconds: first.start, endSeconds: min(cutoff, last.end))
        } else { tail = nil }
        needsConfirmation = !pending.isEmpty || processedUntil < cutoff
        voice = (utterances.last?.text ?? "") + text
        voiceUtteranceStart = utterances.last?.start
    }
}
