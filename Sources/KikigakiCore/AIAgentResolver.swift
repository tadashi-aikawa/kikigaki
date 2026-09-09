import Foundation

/// `herdr agent list` が返す1件。KIKIGAKIが解釈する項目だけを持つ。
///
/// `agent start <NAME>` で付けた名前は list にも get にも返らない(実測: herdr 0.8.2)。
/// 接続先を指せるのは `pane_id` か、利用者が付けた `display_agent` か、ペインの `cwd` だけである。
public struct AIAgentCandidate: Equatable, Sendable {
    public let paneID: String
    public let workspaceID: String
    /// herdrの `agent`。CLI種別であり、agent名ではない
    public let kind: String?
    public let displayAgent: String?
    public let cwd: String?
    public let sessionID: String?
    public let terminalID: String?
    /// 候補を人が見分けるための表題。絞り込みには使わない
    public let title: String?

    public init(paneID: String, workspaceID: String, kind: String? = nil, displayAgent: String? = nil,
                cwd: String? = nil, sessionID: String? = nil, terminalID: String? = nil, title: String? = nil) {
        self.paneID = paneID; self.workspaceID = workspaceID; self.kind = kind; self.displayAgent = displayAgent
        self.cwd = cwd; self.sessionID = sessionID; self.terminalID = terminalID; self.title = title
    }
}

/// 接続先の絞り込み条件。どのキーで絞るかを差し替えられるよう、条件だけを値として持つ。
public struct AIAgentCriteria: Equatable, Sendable {
    public let cwd: String?
    public let displayAgent: String?
    /// 条件が1つも無ければ接続型ではない。全ペインから当てずっぽうに選ばない
    public init?(cwd: String?, displayAgent: String?) {
        let cwd = cwd?.isEmpty == true ? nil : cwd
        let displayAgent = displayAgent?.isEmpty == true ? nil : displayAgent
        guard cwd != nil || displayAgent != nil else { return nil }
        self.cwd = cwd; self.displayAgent = displayAgent
    }
}

public enum AIAgentResolutionFailure: Error, Equatable, Sendable {
    /// cwd も displayAgent も無い。接続先を決められない
    case noCriteria
    /// 条件に合うペインが無い。新規起動へは倒さない
    case notFound
    /// 条件に合うペインが複数ある。黙って1つを選ばない
    case ambiguous(count: Int)
    /// 一意に決まったが、設定の cli と実物のCLI種別が違う
    case kindMismatch(expected: String, found: String?)

    public var message: String {
        switch self {
        case .noCriteria: return "接続先の条件がありません。cwd か displayAgent を設定してください"
        case .notFound: return "条件に合う稼働中のペインがありません"
        case .ambiguous(let count): return "条件に合うペインが\(count)件あります。cwd か displayAgent を足して絞ってください"
        case .kindMismatch(let expected, let found):
            return "ペインのCLIが設定と違います。設定: \(expected) / 実物: \(found ?? "不明")"
        }
    }
}

/// 稼働中ペインの候補から接続先を1つに決める純関数。herdr呼び出しも副作用も持たない。
public enum AIAgentResolver {
    /// 絞り込みは cwd → displayAgent の順に行い、CLI種別は絞り込みには使わず最後の拒否条件にする。
    /// 種別で絞ると、条件が甘いまま偶然1件になった候補へ送ってしまうため。
    public static func resolve(candidates: [AIAgentCandidate], criteria: AIAgentCriteria?,
                               provider: AIProvider) -> Result<AIAgentCandidate, AIAgentResolutionFailure> {
        guard let criteria else { return .failure(.noCriteria) }
        var narrowed = candidates
        if let cwd = criteria.cwd {
            let expected = normalized(cwd)
            // herdrの `foreground_cwd` はworktreeへ入ると変わるため、ペインの `cwd` だけで比べる。
            narrowed = narrowed.filter { $0.cwd.map(normalized) == expected }
        }
        if let displayAgent = criteria.displayAgent {
            narrowed = narrowed.filter { $0.displayAgent == displayAgent }
        }
        guard let target = narrowed.first else { return .failure(.notFound) }
        guard narrowed.count == 1 else { return .failure(.ambiguous(count: narrowed.count)) }
        guard target.kind == provider.rawValue else {
            return .failure(.kindMismatch(expected: provider.rawValue, found: target.kind))
        }
        return .success(target)
    }

    /// 同じペインへ2つ以上のプロファイルが解決したら設定エラーにする。
    /// streamと世代が別なのに同じCLI文脈へ2本の会話が混ざり、受領基準がずれるため。
    public static func duplicatedPanes(_ resolved: [AIAgentCandidate]) -> [String] {
        var seen = Set<String>(), duplicated = Set<String>()
        for candidate in resolved where !seen.insert(candidate.paneID).inserted { duplicated.insert(candidate.paneID) }
        return duplicated.sorted()
    }

    /// 末尾の `/` と `.`・シンボリックリンクでない範囲の表記ゆれだけを吸収する。実体の同一性は判定しない。
    private static func normalized(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }
}
