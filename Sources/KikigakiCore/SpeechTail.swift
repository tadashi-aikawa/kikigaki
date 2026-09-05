import Foundation

/// ASRの1文字に発話前の間が含まれた場合だけ、最後の発話塊と後続文字で話者を確認する。
/// 文全体や単語全体のトークンを末尾の話者へ付け替えない。
enum SpeechTail {
    /// 長い1文字の時間には無音や別話者の声が混ざる。その全長を多数決へ投票させず、
    /// 付与された話者が実際に検出された時間だけを重みにする。区間の重複は二重加算しない。
    static func evidenceWeights(tokens: [TimedToken], speakers: [Int?], segments: [SpeakerSegment]) -> [Double] {
        let ordered = segments.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        return tokens.indices.map { i in
            let token = tokens[i]
            guard token.start.isFinite, token.end.isFinite, token.duration > 0.8,
                  token.text.filter({ $0.isLetter || $0.isNumber }).count == 1,
                  let speaker = speakers[i] else { return token.duration }
            var end = token.start
            var duration = 0.0
            for segment in ordered where segment.speaker == speaker {
                if segment.start >= token.end { break }
                let lo = max(end, segment.start)
                let hi = min(token.end, segment.end)
                if hi > lo { duration += hi - lo; end = hi }
            }
            return duration
        }
    }

    static func speakers(tokens: [TimedToken], segments: [SpeakerSegment], skippingPrefix: Int = 0) -> [Int?] {
        let first = min(tokens.count, max(0, skippingPrefix))
        let raw = tokens.indices.map { $0 < first ? nil : Aligner.speaker(at: tokens[$0].midpoint, segments: segments) }
        var result = raw
        let ordered = segments.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        for i in tokens.indices.dropFirst(first) {
            let token = tokens[i]
            guard token.start.isFinite, token.end.isFinite, token.duration > 0.8,
                  token.text.filter({ $0.isLetter || $0.isNumber }).count == 1,
                  let next = tokens.indices.dropFirst(i + 1).first(where: {
                      tokens[$0].text.contains(where: { $0.isLetter || $0.isNumber })
                  }),
                  tokens[next].start >= token.end - 0.01,
                  tokens[next].start - token.end <= 0.35,
                  let nextSpeaker = raw[next] else { continue }

            var start = token.start
            var end = token.start
            var followsGap = false
            for segment in ordered {
                if segment.start >= token.end { break }
                let lo = max(token.start, segment.start)
                let hi = min(token.end, segment.end)
                guard hi > lo else { continue }
                if lo - end >= 0.5 {
                    start = lo
                    followsGap = true
                }
                end = max(end, hi)
            }
            guard followsGap, start - token.start >= 0.5,
                  end >= token.end - 0.12 else { continue }

            var overlap: [Int: Double] = [:]
            for segment in ordered {
                let duration = min(end, segment.end) - max(start, segment.start)
                if duration > 0 { overlap[segment.speaker, default: 0] += duration }
            }
            let total = overlap.values.reduce(0, +)
            // 交代直後は前話者の区間が尾部へ少し重なる。最後に他話者が終わった後、
            // 後続話者だけの声が0.12秒以上続く場合も、独立した尾部の裏付けとする。
            let otherEnd = ordered.filter { $0.speaker != nextSpeaker && $0.start < end && $0.end > start }
                .map { min(end, $0.end) }.max() ?? start
            let exclusiveTail = end - max(start, otherEnd)
            let supportedTail = ordered.contains {
                $0.speaker == nextSpeaker && $0.start <= end - 0.12 && $0.end >= end
            }
            // 尾部の多数派にも独占的な末尾にも裏付けがない場合は、そのまま残す。
            guard let duration = overlap[nextSpeaker], duration >= 0.01,
                  duration > total * 0.75 || (exclusiveTail >= 0.12 && supportedTail) else { continue }
            result[i] = nextSpeaker
        }
        return result
    }
}
