import Foundation

/// 話者スロット(Sortformer の出力 0〜3 = 枡 A〜D)に付ける名前。
/// 名前を付けていない枡は「話者A」のように枡の記号で表示する
public struct SpeakerNames: Equatable, Sendable {
    public static let letters = ["A", "B", "C", "D"]
    public static var slotCount: Int { letters.count }

    private var names: [Int: String] = [:]

    public init() {}

    public init(_ names: [Int: String]) {
        for (slot, name) in names { set(name, for: slot) }
    }

    /// 枡の記号。Sortformer は最大4話者だが、想定外のスロットが来ても落ちないよう番号で返す
    public static func letter(for slot: Int) -> String {
        letters.indices.contains(slot) ? letters[slot] : String(slot + 1)
    }

    public static func defaultName(for slot: Int) -> String {
        "話者" + letter(for: slot)
    }

    /// 表示名。nil(どの話者区間にも当たらなかった)は "?"
    public func name(for slot: Int?) -> String {
        guard let slot else { return "?" }
        return names[slot] ?? Self.defaultName(for: slot)
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
}
