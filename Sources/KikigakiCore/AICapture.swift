import Foundation

/// Enter時点の音声位置で切る。後から到着したASRでも、上限以降に始まった語は加えない。
public struct AICapture: Equatable, Sendable {
    public let lines: [String]
    public let voice: String
    public let voiceUtteranceStart: Double?
    public let tail: AITentativeTail?
    public let needsConfirmation: Bool
    public let needsAudioProcessing: Bool
    public let voiceExcluded: Bool

    public init(tokens: [TimedToken], speakers: [Int?], finalCount: Int, processedUntil: Double,
                cutoff: Double, names: SpeakerNames, timeline: MeetingTimeline, typed: [Utterance] = [],
                audioExclusion: AudioExclusion = AudioExclusion(), audioLevels: AudioLevelTrack? = nil) throws {
        guard cutoff.isFinite, cutoff >= 0, processedUntil.isFinite, processedUntil >= 0,
              finalCount >= 0, finalCount <= tokens.count, speakers.count == tokens.count,
              tokens.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }),
              zip(tokens, tokens.dropFirst()).allSatisfy({ $0.start <= $1.start }),
              typed.allSatisfy({ $0.kind == .typed && $0.speaker == nil && $0.start.isFinite && $0.start >= 0 && $0.end == $0.start })
              else { throw AIError.invalid("capture boundary") }
        let count = tokens.prefix { $0.start < cutoff }.count
        let fixed = tokens.prefix(min(finalCount, count)).prefix { $0.end <= cutoff }.count
        let utterances = names.diarizationEnabled
            ? Aligner.utterances(tokens: Array(tokens.prefix(fixed)), speakers: Array(speakers.prefix(fixed)))
            : UndiarizedTranscript.utterances(tokens: Array(tokens.prefix(fixed)))
        // typedは送信操作時点の値コピーを受け取る。一時停止中にも届くよう境界の等号を含める。
        let merged = TranscriptEntries.merge(voice: utterances, typed: typed.filter { $0.start <= cutoff }, timeline: timeline)
        lines = TranscriptRenderer.lines(audioExclusion.included(merged.utterances, track: audioLevels), names: names, timeline: timeline)
        let pending = Array(tokens[fixed..<count])
        let pendingExcluded = pending.first.flatMap { first in pending.last.map { last in
            audioExclusion.excludes(Utterance(speaker: nil, start: first.start, end: min(cutoff, last.end), text: ""), track: audioLevels)
        } } ?? false
        let text = pendingExcluded ? "" : pending.map(\.text).joined()
        if let first = pending.first, let last = pending.last, !text.isEmpty {
            tail = AITentativeTail(text: text, startSeconds: first.start, endSeconds: min(cutoff, last.end))
        } else { tail = nil }
        needsConfirmation = !pending.isEmpty || processedUntil < cutoff
        needsAudioProcessing = processedUntil < cutoff
        let last = utterances.last.flatMap { audioExclusion.excludes($0, track: audioLevels) ? nil : $0 }
        voiceExcluded = pendingExcluded || (pending.isEmpty && utterances.last != nil && last == nil)
        // 除外された末尾の代わりに古い発話を質問にしない。
        voice = pendingExcluded ? "" : (last?.text ?? "") + text
        voiceUtteranceStart = pendingExcluded ? nil : last?.start
    }
}
