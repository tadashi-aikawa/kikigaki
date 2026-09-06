import Foundation

/// 元の話者枠を残して表示先へ変換する。手動指定は直接の行き先で、連鎖させない。
public struct SpeakerMapping: Equatable, Sendable {
    public var limited: Bool
    public var automatic: [Int: Int]
    public var overrides: [Int: Int]

    public init(limited: Bool = false, automatic: [Int: Int] = [:], overrides: [Int: Int] = [:]) {
        self.limited = limited
        self.automatic = automatic
        self.overrides = overrides
    }

    public func destination(for source: Int?) -> Int? {
        guard let source else { return nil }
        if let manual = overrides[source] { return manual }
        return limited ? automatic[source] : source
    }

    public func apply(_ speakers: [Int?]) -> [Int?] { speakers.map { destination(for: $0) } }
}

/// WeSpeakerの正規化特徴を照合する。Sortformerの確率の二番手で代用しない。
/// 閾値は実験機能の保守的な初期値。近さだけでなく次点との差も必要とする。
public struct SpeakerIdentity: Sendable {
    public let limit: Int
    public let minimumSimilarity: Double
    public let minimumMargin: Double
    public private(set) var profiles: [Int: [[Float]]] = [:]
    public private(set) var anchors: [Int] = []
    public private(set) var mapping: [Int: Int] = [:]
    public private(set) var scores: [Int: [Int: Double]] = [:]
    private var order: [Int] = []
    private var dimension: Int?

    public init(limit: Int, minimumSimilarity: Double = 0.5, minimumMargin: Double = 0.08) {
        self.limit = min(4, max(1, limit))
        self.minimumSimilarity = minimumSimilarity
        self.minimumMargin = minimumMargin
    }

    @discardableResult
    public mutating func observe(slot: Int, embedding: [Float]) -> Bool {
        guard (0..<4).contains(slot), let normalized = Self.normalized(embedding),
              dimension == nil || dimension == normalized.count else { return false }
        dimension = normalized.count
        if profiles[slot] == nil { order.append(slot) }
        // メモリと推論回数を会議の長さに依存させない。代表音声3本を保持する。
        guard profiles[slot, default: []].count < 3 else { return false }
        profiles[slot, default: []].append(normalized)
        recompute()
        return true
    }

    private mutating func recompute() {
        // 全枠を再照合する。初期の分裂枠を固定したまま本来の別話者を押し出さない。
        anchors = []
        mapping = [:]
        scores = [:]
        let representatives = profiles.compactMapValues { vectors -> [Float]? in
            guard let first = vectors.first else { return nil }
            var sum = [Float](repeating: 0, count: first.count)
            for vector in vectors { for i in sum.indices { sum[i] += vector[i] } }
            return Self.normalized(sum)
        }
        for slot in order {
            guard let voice = representatives[slot] else { continue }
            let ranked = anchors.compactMap { anchor -> (Int, Double)? in
                guard let other = representatives[anchor], let similarity = Self.cosine(voice, other) else { return nil }
                return (anchor, similarity)
            }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            scores[slot] = Dictionary(uniqueKeysWithValues: ranked)
            if let best = ranked.first, best.1 >= minimumSimilarity {
                if ranked.count == 1 || best.1 - ranked[1].1 >= minimumMargin { mapping[slot] = best.0 }
                // 僅差なら新しい人物だとも断定せず、次の特徴か手動訂正を待つ。
            } else if anchors.count < limit {
                anchors.append(slot)
                mapping[slot] = slot
            }
        }
    }

    public static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double? {
        guard lhs.count == rhs.count, let a = normalized(lhs), let b = normalized(rhs) else { return nil }
        return zip(a, b).reduce(0) { $0 + Double($1.0) * Double($1.1) }
    }

    private static func normalized(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 1e-12 else { return nil }
        return vector.map { Float(Double($0) / norm) }
    }
}

/// 直近の単独発話だけを特徴抽出に使う。別話者との重複と区間端を除く。
public enum SpeakerVoiceSamples {
    public static func ranges(segments: [SpeakerSegment], after: [Int: Double],
                              bufferStart: Double, until: Double) -> [SpeakerSegment] {
        let valid = segments.filter {
            (0..<4).contains($0.speaker) && $0.start.isFinite && $0.end.isFinite && $0.end > $0.start
                && $0.end > bufferStart && $0.start < until
        }
        var result: [SpeakerSegment] = []
        for slot in Set(valid.map(\.speaker)).sorted() {
            let lower = max(bufferStart, after[slot] ?? 0)
            var candidates: [SpeakerSegment] = []
            for segment in valid where segment.speaker == slot {
                var pieces = [(max(lower, segment.start) + 0.15, min(until, segment.end) - 0.15)]
                for other in valid where other.speaker != slot {
                    pieces = pieces.flatMap { start, end -> [(Double, Double)] in
                        if other.end <= start || other.start >= end { return [(start, end)] }
                        return [(start, min(end, other.start - 0.15)), (max(start, other.end + 0.15), end)]
                            .filter { $0.1 > $0.0 }
                    }
                }
                for (start, end) in pieces where end - start >= 2 {
                    candidates.append(.init(speaker: slot, start: start, end: min(end, start + 6)))
                }
            }
            if let best = candidates.sorted(by: {
                let a = $0.end - $0.start, b = $1.end - $1.start
                return a == b ? $0.start < $1.start : a > b
            }).first { result.append(best) }
        }
        return result.sorted { $0.start == $1.start ? $0.speaker < $1.speaker : $0.start < $1.start }
    }
}
