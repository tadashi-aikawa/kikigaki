import Foundation

/// AIの返事行の本文の下へ置く「どのモデルへ・どの強さで・どこで動いているものへ頼んだか」の表記。
///
/// 値は会議開始時に固定したプロファイルだけから採る。CLIの既定モデルは推測しない
/// (`~/.codex/config.toml` などを読まない)。推測した名前を出すと、実際に動いたモデルと
/// 画面の表記が食い違ったときに気づけなくなる。分からない項目は黙って飛ばす。
///
/// 表記はモデルと作業場所の2つの塊に分かれる。頼んだ相手と頼んだ場所は意味が違うので、
/// 中黒で1つに繋がず、塊ごとにアイコンを付けて離して置く。フッターの1行は折り返さないので、
/// 幅が足りないときは 作業場所の塊 → エフォート の順に落とす。
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

    /// フッター1行の中身。2つの塊をそれぞれ別のアイコンで出すので、1本の文字列にしない。
    public struct Stage: Equatable, Sendable {
        /// `cpu` のアイコンを付ける前の塊。「gpt-6-astra · high」。
        public let model: String
        /// `folder` のアイコンを付ける後ろの塊。落とした段ではnil。
        public let directory: String?
        public init(model: String, directory: String? = nil) {
            self.model = model
            self.directory = directory
        }
        /// 幅を気にしないときの全部入り。tooltipと読み上げに使う。
        public var text: String { [model, directory].compactMap { $0 }.joined(separator: AIModelLabel.separator) }
    }

    /// 広い順の候補。先頭が全部入りで、以降は 作業場所の塊 → エフォート の順に落ちる。
    /// 項目が元から無い段は重複するので畳む。
    public var stages: [Stage] {
        let withEffort = [model, effort].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: AIModelLabel.separator)
        let candidates = [Stage(model: withEffort, directory: directory), Stage(model: withEffort), Stage(model: model)]
        var stages: [Stage] = []
        for candidate in candidates where !candidate.model.isEmpty {
            if stages.last != candidate { stages.append(candidate) }
        }
        return stages
    }

    /// 幅を気にしないときの表記。tooltipにも使う。
    public var text: String { stages.first?.text ?? "" }

    /// `available` に収まる最も広い候補。どれも収まらなければnilで、行は表記ごと出さない。
    /// 本文の幅を超えてまで一部を出すより、モデルを出さないほうが画面の意味が崩れない。
    public static func fit(_ stages: [Stage], available: Double, measure: (Stage) -> Double) -> Stage? {
        guard available > 0 else { return nil }
        return stages.first { measure($0) <= available }
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
