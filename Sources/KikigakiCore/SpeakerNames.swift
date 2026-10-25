import Foundation

/// 話者スロット(話者判別の出力 0〜7 = 枡 A〜H)に付ける名前。
/// 名前を付けていない枡は「話者A」のように枡の記号で表示する。
/// 旧版の4枠の会議も枠番号の辞書なので、そのまま読める
public struct SpeakerNames: Codable, Equatable, Sendable {
    public static let letters = ["A", "B", "C", "D", "E", "F", "G", "H"]
    public static var slotCount: Int { letters.count }

    private var names: [Int: String] = [:]
    public private(set) var humanTouched: Set<Int> = []
    public private(set) var attributions: [Int: SpeakerAttribution] = [:]
    /// 会議開始で固定する。名前と同じ保存・コピー経路を通し、次回設定で過去会議を変えない。
    public var diarizationEnabled = true

    public init() {}

    public init(_ names: [Int: String]) {
        for (slot, name) in names { set(name, for: slot) }
    }

    /// 枡の記号。話者判別は最大8話者だが、想定外のスロットが来ても落ちないよう番号で返す
    public static func letter(for slot: Int) -> String {
        letters.indices.contains(slot) ? letters[slot] : String(slot + 1)
    }

    public static func defaultName(for slot: Int) -> String {
        "話者" + letter(for: slot)
    }

    /// 表示名。nil(どの話者区間にも当たらなかった)は "?"
    public func name(for slot: Int?) -> String {
        guard let slot else { return diarizationEnabled ? "?" : "発言" }
        return names[slot] ?? Self.defaultName(for: slot)
    }

    public func displayName(for utterance: Utterance) -> String {
        utterance.kind == .typed ? "手入力" : name(for: utterance.speaker)
    }

    /// 付けた名前(既定のままなら nil)
    public func customName(for slot: Int) -> String? {
        names[slot]
    }

    /// 名前を付ける。前後の空白を落とし、空かその枡の既定名なら既定に戻す。改行は空白にする
    public mutating func set(_ name: String, for slot: Int) {
        let trimmed = Self.normalized(name)
        if trimmed.isEmpty || trimmed == Self.defaultName(for: slot) {
            names[slot] = nil
        } else {
            names[slot] = trimmed
        }
    }

    /// 同じ名前でのReturnと既定への復帰も、人による確認として会議中は保持する。
    public mutating func confirm(_ name: String, for slot: Int) {
        set(name, for: slot)
        humanTouched.insert(slot)
        attributions[slot] = nil
    }

    public func unresolvedSlots(detected: [Int], mapping: [Int: Int]) -> [Int] {
        guard diarizationEnabled else { return [] }
        return Set(detected).filter {
            Self.letters.indices.contains($0) && customName(for: $0) == nil && !humanTouched.contains($0)
                && (mapping[$0] ?? $0) == $0
        }.sorted()
    }

    /// 名前は固定した候補か、会話の本文に出てきた人名に限る。会話に出てこない名前をAIに作らせないため。
    /// 確度の低い推定は、会議にいたとは限らない台帳とよく使う名前を候補として使えない。消去法で外れやすいため。
    /// `texts` は発言の本文。整形した `lines` は根拠の時刻の照合に使う。
    public mutating func identify(_ event: AISpeakerEvent, participant: String, fixed: SpeakerIdentification?, detected: [Int],
                                 mapping: [Int: Int], lines: [String], texts: [String]) throws {
        let candidates = event.isLowConfidence ? fixed?.lowConfidenceCandidates ?? [] : fixed?.candidates ?? []
        guard let slot = Self.letters.firstIndex(of: event.slot),
              unresolvedSlots(detected: detected, mapping: mapping).contains(slot),
              otherSlot(using: event.name, excluding: slot) == nil,
              !Self.letters.indices.contains(where: { Self.defaultName(for: $0) == event.name }),
              candidates.contains(event.name) || SpeakerEvidence.mentions(event.name, in: texts),
              SpeakerEvidence.exists(event.evidence, in: lines) else {
            throw AIError.invalid("speaker current state or evidence")
        }
        set(event.name, for: slot)
        attributions[slot] = SpeakerAttribution(event: event, participant: participant)
    }

    public static func normalized(_ name: String) -> String {
        name
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func otherSlot(using name: String, excluding slot: Int) -> Int? {
        let name = Self.normalized(name)
        return (0..<Self.slotCount).first { $0 != slot && self.name(for: $0) == name }
    }

    private enum CodingKeys: String, CodingKey { case names, diarizationEnabled, humanTouched, attributions }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        names = try values.decode([Int: String].self, forKey: .names)
        diarizationEnabled = try values.decodeIfPresent(Bool.self, forKey: .diarizationEnabled) ?? true
        humanTouched = try values.decodeIfPresent(Set<Int>.self, forKey: .humanTouched) ?? []
        attributions = try values.decodeIfPresent([Int: SpeakerAttribution].self, forKey: .attributions) ?? [:]
        guard humanTouched.allSatisfy(Self.letters.indices.contains), attributions.allSatisfy({ slot, value in
            Self.letters.indices.contains(slot) && !humanTouched.contains(slot)
                && value.event.slot == Self.letter(for: slot) && names[slot] == value.event.name
        }) else { throw AIError.invalid("speaker names attribution") }
    }
}
