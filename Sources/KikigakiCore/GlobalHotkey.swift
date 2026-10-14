import Foundation

/// どのアプリが前面でも効くキー。書式は parliament の `[voice] global_hotkey` と同じ `modifier+key`。
///
/// ファンクションキー以外は ctrl・alt・cmd のどれかを要る。全アプリでキーを横取りするので、
/// 単独キーやshiftだけの組だと、どのアプリでもその文字が打てなくなる。
/// キー本体は仮想キーコードへ写せるもの(英数字・space・enter・tab・escape・F1〜F20)だけ。
public struct GlobalHotkey: Equatable, Sendable {
    /// 並びは表示順。macOSのメニューと同じ ⌃⌥⇧⌘
    public enum Modifier: String, CaseIterable, Sendable {
        case ctrl, alt, shift, cmd
        var symbol: String {
            switch self {
            case .ctrl: "⌃"
            case .alt: "⌥"
            case .shift: "⇧"
            case .cmd: "⌘"
            }
        }
    }

    public let modifiers: Set<Modifier>
    /// 小文字の英数字、または `space` `enter` `tab` `escape` `f1`〜`f20`
    public let key: String

    private static let aliases: [String: Modifier] = [
        "ctrl": .ctrl, "control": .ctrl,
        "alt": .alt, "option": .alt,
        "shift": .shift,
        "cmd": .cmd, "command": .cmd, "meta": .cmd,
    ]
    private static let functionKeys = Set((1...20).map { "f\($0)" })
    private static let namedKeys: Set<String> = ["space", "enter", "tab", "escape"]

    /// 書式に合わなければnil。理由は設定読み込み側がまとめて示す
    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var modifiers = Set<Modifier>()
        var key: String?
        for part in parts {
            guard !part.isEmpty else { return nil }
            if let modifier = Self.aliases[part] {
                guard modifiers.insert(modifier).inserted else { return nil }
                continue
            }
            guard key == nil else { return nil }
            key = part == "esc" ? "escape" : part == "return" ? "enter" : part
        }
        guard let key else { return nil }
        let single = key.count == 1 && key.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        let function = Self.functionKeys.contains(key)
        guard single || function || Self.namedKeys.contains(key) else { return nil }
        guard function || !modifiers.isDisjoint(with: [.ctrl, .alt, .cmd]) else { return nil }
        self.modifiers = modifiers
        self.key = key
    }

    /// 通知とログに出す表記。例: `cmd+shift+space` は `⇧⌘Space`
    public var display: String {
        let symbols = Modifier.allCases.filter(modifiers.contains).map(\.symbol).joined()
        let name = switch key {
        case "space": "Space"
        case "enter": "Return"
        case "tab": "Tab"
        case "escape": "Esc"
        default: key.uppercased()
        }
        return symbols + name
    }
}
