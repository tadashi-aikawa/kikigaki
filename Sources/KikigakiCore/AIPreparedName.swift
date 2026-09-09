import Foundation

/// 表示とenvelopeで共有する、準備済みセッションの任意の名前。
public enum AIPreparedName {
    public static func parse(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        guard raw.utf8.count <= 64, !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else {
            throw AIError.invalid("名前は改行なし・64バイト以内で入力してください")
        }
        let name = raw.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
