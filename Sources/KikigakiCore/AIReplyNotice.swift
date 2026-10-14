import Foundation

/// 届いた返事を音とOS通知で知らせるための材料。仕様は docs/ai-participant.md の「返事の知らせ」
public struct AIReplyNotice: Equatable, Sendable {
    /// 返事が届いたプロファイルの枠
    public let slot: Int
    public let kind: AIReceiveEvent.Kind
    /// 人が待っている依頼か。手動の依頼と、手動で追記した自動送信の依頼
    public let awaited: Bool
    public let body: String

    public init(slot: Int, kind: AIReceiveEvent.Kind, awaited: Bool, body: String) {
        self.slot = slot; self.kind = kind; self.awaited = awaited; self.body = body
    }

    /// `notifySound` と `notifyBanner` の共通の判定。書けば手動・自動とも従い、
    /// 書かなければ人が待つ返事と確認質問だけ知らせる。自動送信の返事は間隔ごとに来るため
    public static func enabled(_ setting: Bool?, kind: AIReceiveEvent.Kind, awaited: Bool) -> Bool {
        guard kind != .accept else { return false }
        return setting ?? (awaited || kind == .needsInput)
    }

    public func enabled(_ setting: Bool?) -> Bool { Self.enabled(setting, kind: kind, awaited: awaited) }

    /// 通知の本文。返事の冒頭をMarkdownの記号を外して載せ、長い分はOSに省かせる
    public var text: String {
        let excerpt = Self.plain(body)
        switch kind {
        case .needsInput: return "確認: " + excerpt
        case .failed: return "失敗: " + excerpt
        case .accept, .answered: return excerpt
        }
    }

    static let excerptLimit = 200

    /// 行頭の見出し・箇条・引用の記号と、強調・コード・リンクの記法を外して1行へ詰める
    static func plain(_ markdown: String) -> String {
        var lines: [String] = []
        var fenced = false
        for raw in markdown.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle(); continue }
            if !fenced {
                line = line.replacingOccurrences(of: #"^(#{1,6}\s+|>\s*|[-*+]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+)"#,
                                                 with: "", options: .regularExpression)
                line = line.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
                line = line.replacingOccurrences(of: #"\[\[([^\]|]*\|)?([^\]]*)\]\]"#, with: "$2", options: .regularExpression)
                line = line.replacingOccurrences(of: #"(\*\*|__|~~|`)"#, with: "", options: .regularExpression)
                if line.range(of: #"^\|?[\s:|-]+\|?$"#, options: .regularExpression) != nil, line.contains("-") { continue }
            }
            if !line.isEmpty { lines.append(line) }
        }
        let joined = lines.joined(separator: " ")
        return joined.count > excerptLimit ? String(joined.prefix(excerptLimit)) + "…" : joined
    }
}
