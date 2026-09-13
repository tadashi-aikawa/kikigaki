import Foundation

/// AIの返事行の名前行へ添える「どのモデルへ・どの強さで・どこで動いているものへ頼んだか」の表記。
///
/// 値は会議開始時に固定したプロファイルだけから採る。CLIの既定モデルは推測しない
/// (`~/.codex/config.toml` などを読まない)。推測した名前を出すと、実際に動いたモデルと
/// 画面の表記が食い違ったときに気づけなくなる。分からない項目は黙って飛ばす。
///
/// 表記は名前行の一部なので折り返さない。幅が足りないときは
/// 末端ディレクトリ → エフォート の順に落とし、時刻と所要時間の場所を先に守る。
public struct AIModelLabel: Equatable, Sendable {
    public static let separator = " · "
    /// プロファイルの `model`。未設定のときはCLI名 (`codex` / `claude`)。
    public let model: String
    /// プロファイルの `effort`。未設定ならnil。
    public let effort: String?
    /// 解決済み `cwd` の末端ディレクトリ名。既定cwdでも出す。
    public let directory: String?

    public init(model: String, effort: String? = nil, directory: String? = nil) {
        self.model = AIModelLabel.clean(model) ?? ""
        self.effort = AIModelLabel.clean(effort)
        self.directory = AIModelLabel.clean(directory)
    }

    /// 会議開始時に固定したプロファイル。過去会議の保存済みプロファイルも同じ経路で読む。
    public init(profile: ResolvedAIConfig) {
        self.init(model: AIModelLabel.clean(profile.model) ?? profile.cli.rawValue,
                  effort: profile.effort,
                  // 「/」しか残らないルート直下は末端ディレクトリとして意味を持たない。
                  directory: profile.cwd.lastPathComponent == "/" ? nil : profile.cwd.lastPathComponent)
    }

    /// 広い順の候補。先頭が全部入りで、以降は末端ディレクトリ→エフォートの順に落ちる。
    /// 項目が元から無い段は重複するので畳む。
    public var stages: [String] {
        let candidates = [[model, effort, directory], [model, effort], [model]]
        var stages: [String] = []
        for candidate in candidates {
            let text = candidate.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: AIModelLabel.separator)
            if !text.isEmpty, stages.last != text { stages.append(text) }
        }
        return stages
    }

    /// 幅を気にしないときの表記。tooltipにも使う。
    public var text: String { stages.first ?? "" }

    /// `available` に収まる最も広い候補。どれも収まらなければnilで、行は表記ごと出さない。
    /// 時刻を押し出してまで一部を出すより、モデルを出さないほうが画面の意味が崩れない。
    public static func fit(_ stages: [String], available: Double, measure: (String) -> Double) -> String? {
        guard available > 0 else { return nil }
        return stages.first { measure($0) <= available }
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
