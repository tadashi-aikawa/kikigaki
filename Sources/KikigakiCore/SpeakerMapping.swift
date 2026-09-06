/// 元の検出枠を残して手動の統合先へ変換する。指定は直接の行き先で、連鎖させない。
public struct SpeakerMapping: Equatable, Sendable {
    public var overrides: [Int: Int]

    public init(overrides: [Int: Int] = [:]) {
        self.overrides = overrides
    }

    public func destination(for source: Int?) -> Int? {
        guard let source else { return nil }
        return overrides[source] ?? source
    }

    public func apply(_ speakers: [Int?]) -> [Int?] { speakers.map { destination(for: $0) } }
}
