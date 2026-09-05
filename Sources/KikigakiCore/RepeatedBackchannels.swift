import Foundation

/// 繰り返し相槌の候補を、文字列の境界と窓判定の両方で絞る。停止後の確定トークン専用。
/// 話者の塊を丸ごと消すと「うんうん先週」の「先」まで巻き込むため、文字列から先に探す。
/// 推定話者の誤りは残るので、呼び出し側は有効化を明示させ、必ず原文も保存する。
public enum RepeatedBackchannels {
    public static func candidates(tokens: [TimedToken], rawSpeakers: [Int?], speakers: [Int?]) -> [Range<Int>] {
        guard tokens.count == rawSpeakers.count, tokens.count == speakers.count else { return [] }
        var result: [Range<Int>] = []
        for phrase in Aligner.phraseRanges(tokens) {
            var i = phrase.lowerBound
            while i < phrase.upperBound {
                var next = i + 1
                for word in ["うん", "そう"] {
                    let pattern = Array(word)
                    var count = 0
                    var j = i
                    while j < phrase.upperBound {
                        let text = Array(tokens[j].text)
                        guard !text.isEmpty, text.enumerated().allSatisfy({ $0.element == pattern[(count + $0.offset) % pattern.count] }) else { break }
                        count += text.count
                        j += 1
                    }
                    // 長すぎる反復も最後まで読み、途中から短い候補として拾い直さない。
                    next = max(next, j)
                    guard count >= pattern.count * 2, count % pattern.count == 0,
                          j < phrase.upperBound, let main = speakers[i],
                          speakers[j] == main, (i..<j).allSatisfy({ speakers[$0] == main }),
                          tokens[j].start - tokens[j - 1].end < Aligner.phraseGapSeconds,
                          tokens[j].text.contains(where: { !$0.isWhitespace && !$0.isPunctuation }),
                          tokens[j - 1].end - tokens[i].start < Aligner.keepIslandSeconds else { continue }
                    var weights: [Int: Double] = [:]
                    var total = 0.0
                    var valid = true
                    for k in i..<j {
                        guard let raw = rawSpeakers[k], tokens[k].duration.isFinite, tokens[k].duration > 0 else {
                            valid = false
                            break
                        }
                        weights[raw, default: 0] += tokens[k].duration
                        total += tokens[k].duration
                    }
                    if valid, weights.contains(where: { $0.key != main && $0.value > total / 2 + 1e-9 }) {
                        result.append(i..<j)
                    }
                }
                i = next
            }
        }
        return result
    }

    public static func utterances(tokens: [TimedToken], speakers: [Int?], omitting ranges: [Range<Int>]) -> [Utterance] {
        let omitted = Set(ranges.flatMap { $0 })
        let indices = tokens.indices.filter { !omitted.contains($0) }
        return Aligner.utterances(tokens: indices.map { tokens[$0] }, speakers: indices.map { speakers[$0] })
    }
}
