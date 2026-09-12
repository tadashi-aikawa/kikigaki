import Foundation

/// 話者を区別しない会議の行境界。確定トークンの接頭辞だけで決め、後続文脈で閉じた行を動かさない。
public enum UndiarizedTranscript {
    public static func utterances(tokens: [TimedToken]) -> [Utterance] {
        guard !tokens.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        var start = 0
        for index in 1..<tokens.count {
            let previous = tokens[index - 1]
            let sentenceEnd = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .last.map { "。！？!?".contains($0) } == true
            // 結果IDだけでは通常の行を切らない。語の途中にあるASR境界を短い行にしないため。
            // 長い独話の上限に限り使う。NLTokenizerは後続結果で境界が変わるので使わない。
            let longResultBoundary = previous.end - tokens[start].start >= 30
                && previous.phraseId != tokens[index].phraseId
            if tokens[index].start - previous.end >= 1 || sentenceEnd || longResultBoundary {
                ranges.append(start..<index)
                start = index
            }
        }
        ranges.append(start..<tokens.count)
        return ranges.map { range in
            Utterance(speaker: nil, start: tokens[range.lowerBound].start, end: tokens[range.upperBound - 1].end,
                      text: tokens[range].map(\.text).joined().trimmingCharacters(in: .whitespaces))
        }
    }
}
