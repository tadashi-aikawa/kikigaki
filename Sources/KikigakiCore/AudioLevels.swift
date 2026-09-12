import Foundation

/// 100msごとのRMS。窓位置はサンプル番号で決め、チャンク分割や一時停止の壁時計に依存しない。
public struct AudioLevelTrack: Codable, Equatable, Sendable {
    public static let sampleRate = 16_000
    public static let windowSamples = 1_600
    public let sampleCount: Int
    public let levels: [Double?]
    public var duration: Double { Double(sampleCount) / Double(Self.sampleRate) }

    fileprivate init(sampleCount: Int, levels: [Double?]) {
        self.sampleCount = sampleCount; self.levels = levels
    }
    private enum CodingKeys: String, CodingKey { case sampleCount, levels }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sampleCount = try values.decode(Int.self, forKey: .sampleCount)
        levels = try values.decode([Double?].self, forKey: .levels)
        guard sampleCount >= 0,
              levels.count == (sampleCount == 0 ? 0 : (sampleCount - 1) / Self.windowSamples + 1),
              levels.allSatisfy({ $0.map { $0.isFinite && $0 >= -120 } ?? true }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid audio level track"))
        }
    }

    public func level(start: Double, end: Double) -> Double? {
        guard start.isFinite, end.isFinite, start >= 0, end > start, end <= duration + 0.000001 else { return nil }
        let first = max(0, Int(start * 10) - 1)
        let last = min(levels.count, Int(ceil(end * 10)) + 1)
        guard first < last else { return nil }
        var selected: [Double] = []
        for index in first..<last {
            let lower = Double(index * Self.windowSamples)
            let upper = min(lower + Double(Self.windowSamples), Double(sampleCount))
            let center = (lower + upper) / (2 * Double(Self.sampleRate))
            if center >= start && center < end {
                guard let value = levels[index] else { return nil }
                selected.append(value)
            }
        }
        guard !selected.isEmpty else { return nil }
        selected.sort()
        return selected[Int(ceil(Double(selected.count) * 0.9)) - 1]
    }

    /// 各表示の行集合の順で評価する。未来の行は基準へ入れない。手入力は数えない。
    public func assessments(for utterances: [Utterance], exclusion: AudioExclusion? = nil) -> [AudioLevelAssessment?] {
        var recent: [Double] = []
        return utterances.map { utterance in
            guard utterance.kind == .voice else { return nil }
            let value = level(start: utterance.start, end: utterance.end)
            var reference: Double?
            if recent.count >= 8 {
                let upper = Array(recent.sorted().suffix(Int(ceil(Double(recent.count) / 4))))
                reference = (upper[(upper.count - 1) / 2] + upper[upper.count / 2]) / 2
            }
            if let value {
                recent.append(value)
                if recent.count > 60 { recent.removeFirst() }
            }
            return AudioLevelAssessment(dbFS: value, referenceDBFS: reference, exclusion: exclusion)
        }
    }
}

public struct AudioLevelMeter: Sendable {
    private var levels: [Double?] = []
    private var count = 0
    private var sum = 0.0
    private var valid = true
    public init() {}
    public mutating func append(_ samples: [Float]) {
        for sample in samples {
            if sample.isFinite { sum += Double(sample) * Double(sample) } else { valid = false }
            count += 1
            if count == AudioLevelTrack.windowSamples {
                levels.append(currentLevel)
                count = 0; sum = 0; valid = true
            }
        }
    }
    private var currentLevel: Double? {
        guard valid, count > 0 else { return nil }
        return max(-120, 10 * log10(max(1e-12, sum / Double(count))))
    }
    /// 録音中は確定窓だけを使い、停止時に端数窓を加える。成長中の窓で過去の値を動かさない。
    public func track(includingPartial: Bool = false) -> AudioLevelTrack {
        if includingPartial, count > 0 {
            return .init(sampleCount: levels.count * AudioLevelTrack.windowSamples + count, levels: levels + [currentLevel])
        }
        return .init(sampleCount: levels.count * AudioLevelTrack.windowSamples, levels: levels)
    }
}

public struct AudioLevelAssessment: Equatable, Sendable {
    public let dbFS: Double?
    public let referenceDBFS: Double?
    public var exclusion: AudioExclusion? = nil
    public init(dbFS: Double?, referenceDBFS: Double? = nil, exclusion: AudioExclusion? = nil) {
        self.dbFS = dbFS; self.referenceDBFS = referenceDBFS; self.exclusion = exclusion
    }
    public var isCandidate: Bool {
        guard let dbFS else { return false }
        if let exclusion { return exclusion.belowThreshold(dbFS) }
        return dbFS < -45 || referenceDBFS.map { dbFS <= $0 - 15 } == true
    }
    public var label: String {
        guard let dbFS else { return "音量 未計測" }
        let value = String(format: "音量 %.1f dBFS", dbFS)
        return value + (isCandidate ? " · 小音量候補" : " · しきい値以上")
    }
    public var detail: String {
        var text = "100ms RMSの行内90パーセンタイル。別会議かどうかは判定しません。" + (exclusion ?? AudioExclusion()).label + "。"
        if let referenceDBFS { text += String(format: " 直前の基準 %.1f dBFS。", referenceDBFS) }
        if dbFS == nil { text += " 区間が短い、音声待ち、または欠測のため未計測です。" }
        return text
    }
}

/// 波形なしで再集計できる保存物。AIの返事は含めない。
public struct AudioLevelReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sampleRate: Int
    public let windowSamples: Int
    public let track: AudioLevelTrack
    public let startedAt: Date
    public let pauses: [MeetingTimeline.Pause]
    public let utterances: [Utterance]
    public let names: SpeakerNames
    public var audioExclusion: AudioExclusion?
    public init(meeting: MeetingMarkdown.Meeting, track: AudioLevelTrack) {
        schemaVersion = 2; sampleRate = AudioLevelTrack.sampleRate; windowSamples = AudioLevelTrack.windowSamples
        self.track = track; startedAt = meeting.startedAt; pauses = meeting.pauses
        utterances = meeting.utterances; names = meeting.names
        audioExclusion = meeting.audioExclusion
    }
}
