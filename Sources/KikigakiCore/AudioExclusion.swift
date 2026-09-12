import Foundation

/// 音量は距離ではなく入力ゲインに依存する。欠測は除外しない。
public struct AudioExclusion: Codable, Equatable, Sendable {
    public var enabled: Bool
    public private(set) var thresholdDBFS: Double
    public init(enabled: Bool = false, thresholdDBFS: Double = -45) {
        self.enabled = enabled
        self.thresholdDBFS = thresholdDBFS.isFinite ? min(-20, max(-80, thresholdDBFS)) : -45
    }
    private enum CodingKeys: String, CodingKey { case enabled, thresholdDBFS }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: try values.decode(Bool.self, forKey: .enabled),
                  thresholdDBFS: try values.decode(Double.self, forKey: .thresholdDBFS))
    }
    public func excludes(_ utterance: Utterance, track: AudioLevelTrack?) -> Bool {
        enabled && utterance.kind == .voice && belowThreshold(track?.level(start: utterance.start, end: utterance.end))
    }
    public func belowThreshold(_ value: Double?) -> Bool { value.map { $0 < thresholdDBFS } ?? false }
    public func included(_ utterances: [Utterance], track: AudioLevelTrack?) -> [Utterance] {
        utterances.filter { !excludes($0, track: track) }
    }
    public var label: String {
        enabled ? String(format: "小音量の除外ON · %.0f dBFS未満", thresholdDBFS) : "小音量の除外OFF · 全発話を含む"
    }
}
