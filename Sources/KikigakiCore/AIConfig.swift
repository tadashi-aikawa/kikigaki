import Foundation
import TOMLKit

public enum AIProvider: String, Codable, Equatable, Sendable { case codex, claude }

/// 利用者のCodex設定のうち、会議セッションの起動で引き継ぐ値だけを読む。設定ファイルは書き換えない。
public enum CodexUserConfig {
    private struct File: Decodable {
        struct Sandbox: Decodable { let writable_roots: [String]? }
        let sandbox_workspace_write: Sandbox?
    }
    /// `[sandbox_workspace_write].writable_roots`。読めない・無い場合は空。
    /// Codexの `-c` は同じキーを置き換えるため、会議用の受信箱を足すときは既存の許可先を先に写す。
    public static func writableRoots(at url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
              let file = try? TOMLDecoder().decode(File.self, from: text) else { return [] }
        return (file.sandbox_workspace_write?.writable_roots ?? []).filter { $0.hasPrefix("/") && !$0.contains("\0") }
    }
}

/// nilと空の[ai]を区別する。環境のPATH探索・実行可能性・ディレクトリ存在確認はアプリ側。
public struct AIConfig: Codable, Equatable, Sendable {
    /// プロファイルの表示名。省略時は address から導く参加者名を使う
    public var name: String?
    public var cli: AIProvider?
    public var command: String?
    /// herdr CLIの絶対パス。GUI起動はシェルのPATHを持たないため、省略時はPATHと既知の置き場を探す
    public var herdrCommand: String?
    public var model: String?
    /// 推論の強さ。CLIごとの引数へ翻訳する。extraArgs との二重指定は拒否する
    public var effort: String?
    public var address: String?
    public var cwd: String?
    /// 稼働中herdrペインの display_agent。cwd と併せて接続先を絞る
    public var displayAgent: String?
    public var extraArgs: [String]?
    public var prompt: String?
    public var notifySound: Bool?
    public var allowWork: Bool?
    public var autoPrompt: String?
    public var autoIntervalMinutes: Int?
    /// 録音開始で自動送信を始める。配列全体で1つまで
    public var autoStart: Bool?
    public var hotkey: KikigakiConfig.Hotkey?

    public init(name: String? = nil, cli: AIProvider? = nil, command: String? = nil, herdrCommand: String? = nil, model: String? = nil,
                effort: String? = nil, address: String? = nil, cwd: String? = nil, displayAgent: String? = nil,
                extraArgs: [String]? = nil, prompt: String? = nil, notifySound: Bool? = nil,
                hotkey: KikigakiConfig.Hotkey? = nil, allowWork: Bool? = nil,
                autoPrompt: String? = nil, autoIntervalMinutes: Int? = nil, autoStart: Bool? = nil) {
        self.name = name
        self.cli = cli; self.command = command; self.herdrCommand = herdrCommand; self.model = model; self.effort = effort
        self.address = address
        self.cwd = cwd; self.displayAgent = displayAgent; self.extraArgs = extraArgs; self.prompt = prompt
        self.notifySound = notifySound; self.hotkey = hotkey
        self.allowWork = allowWork
        self.autoPrompt = autoPrompt; self.autoIntervalMinutes = autoIntervalMinutes; self.autoStart = autoStart
    }

    /// address から導く既定のプロファイル名。設定の name を省略したときのキーにもなる
    public var resolvedName: String {
        if let name { return name.trimmingCharacters(in: .whitespaces) }
        let value = (address ?? "迅雷へ").trimmingCharacters(in: .whitespaces)
        return value.hasSuffix("へ") ? String(value.dropLast()) : value
    }

    public func validate(label: String = "ai") throws {
        func invalid(_ message: String) -> ConfigError { .invalid(description: label + ": " + message) }
        if let name, !AIValidation.singleLine(name) || name.trimmingCharacters(in: .whitespaces).isEmpty
            || name.utf8.count > AILimits.profileNameBytes {
            throw invalid("name must be non-empty, single-line and at most \(AILimits.profileNameBytes) bytes")
        }
        if let command, !AIValidation.absolutePath(command) { throw invalid("command must be absolute") }
        if let herdrCommand, !AIValidation.absolutePath(herdrCommand) { throw invalid("herdrCommand must be absolute") }
        if let cwd, !AIValidation.absolutePath(cwd), !(cwd.hasPrefix("~/") && !cwd.contains("\0")) {
            throw invalid("cwd must be absolute or start with ~/")
        }
        if let model, !AIValidation.singleLine(model) { throw invalid("model must be non-empty and single-line") }
        if let address, !AIValidation.singleLine(address) || address.trimmingCharacters(in: .whitespaces) == "へ" {
            throw invalid("address must contain one non-empty participant name")
        }
        if let displayAgent, !AIValidation.singleLine(displayAgent)
            || displayAgent.trimmingCharacters(in: .whitespaces).isEmpty {
            throw invalid("displayAgent must be non-empty and single-line")
        }
        if let effort, !AIEffort.values(for: cli ?? .codex).contains(effort) {
            throw invalid("effort must be one of " + AIEffort.values(for: cli ?? .codex).joined(separator: ", "))
        }
        if let prompt, prompt.utf8.count > AILimits.questionBytes || prompt.contains("\0") {
            throw invalid("prompt exceeds limit or contains NUL")
        }
        try AIExtraArguments.validate(extraArgs ?? [], provider: cli ?? .codex, label: label)
        if let autoPrompt, autoPrompt.utf8.count > AILimits.questionBytes || autoPrompt.contains("\0") {
            throw invalid("autoPrompt exceeds limit or contains NUL")
        }
        if let autoIntervalMinutes, !(1...60).contains(autoIntervalMinutes) {
            throw invalid("autoIntervalMinutes must be 1...60")
        }
        if autoStart == true, (autoPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw invalid("autoStart requires a non-empty autoPrompt")
        }
    }
}

/// 単数の `[ai]` と配列の `[[ai]]` を同じ型で読む。並び順が既定の優先順位になり、1つ目が既定。
public struct AIProfileList: Codable, Equatable, Sendable {
    public var profiles: [AIConfig]
    /// 配列表記で書かれたか。単数表記の互換読みと区別して診断へ出す
    public let isArrayForm: Bool
    public var first: AIConfig? { profiles.first }

    public init(_ profiles: [AIConfig], isArrayForm: Bool = true) {
        self.profiles = profiles; self.isArrayForm = isArrayForm
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // 単数のテーブルは全キーが省略可能なので配列としては復号できない。配列を先に試す。
        if let list = try? container.decode([AIConfig].self) { profiles = list; isArrayForm = true }
        else { profiles = [try container.decode(AIConfig.self)]; isArrayForm = false }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if isArrayForm { try container.encode(profiles) } else { try container.encode(profiles.first) }
    }

    public func validate() throws {
        func invalid(_ message: String) -> ConfigError { .invalid(description: "ai: " + message) }
        guard !profiles.isEmpty else { throw invalid("must contain at least one profile") }
        var names = Set<String>()
        for (index, profile) in profiles.enumerated() {
            try profile.validate(label: isArrayForm ? "ai[\(index)]" : "ai")
            guard names.insert(profile.resolvedName).inserted else {
                throw invalid("name must be unique: \(profile.resolvedName)")
            }
            // ホットキーはプロファイルごとに持たない。録音・一時停止との衝突検証が組み合わせで増えるため。
            guard index == 0 || profile.hotkey == nil else { throw invalid("hotkey is only allowed on the first profile") }
        }
        guard profiles.filter({ $0.autoStart == true }).count <= 1 else {
            throw invalid("autoStart is allowed on at most one profile")
        }
    }
}

public struct ResolvedAIConfig: Codable, Equatable, Sendable {
    public static let defaultCWD = "~/Library/Application Support/KIKIGAKI/ai-work/"
    public static let defaultHotkey = KikigakiConfig.Hotkey(modifiers: ["ctrl", "alt", "cmd"], key: "a")
    /// 会議開始時に割り当てる1始まりの通し番号。`ai/sessions/<slot>/` の枝名になる
    public let slot: Int
    public let name: String
    public let cli: AIProvider
    public let command: String?
    public let herdrCommand: String?
    public let model: String?
    public let effort: String?
    public let address: String
    public let cwd: URL
    /// cwd が設定に明示されたか。接続先の絞り込みに使えるのは明示された場合だけ
    public let cwdSpecified: Bool
    public let displayAgent: String?
    public let extraArgs: [String]
    public let prompt: String
    public let notifySound: Bool
    public let allowWork: Bool
    public let autoPrompt: String
    public let autoIntervalMinutes: Int
    public let autoStart: Bool
    public let hotkey: KikigakiConfig.Hotkey
    public var participantName: String { address.hasSuffix("へ") ? String(address.dropLast()) : address }
    /// 稼働中ペインへ接続するプロファイル。KIKIGAKIは workspace を作らず agent も起こさない
    public var connectsToExistingPane: Bool { criteria != nil }
    /// 接続先の絞り込み条件。cwd と displayAgent の少なくとも一方が要る
    public var criteria: AIAgentCriteria? {
        AIAgentCriteria(cwd: cwdSpecified ? cwd.path : nil, displayAgent: displayAgent)
    }
    /// 起動引数へ翻訳した effort。接続型ではKIKIGAKIが起動しないので渡せない
    public var effortArguments: [String] { AIEffort.arguments(effort, provider: cli) }

    public init(config: AIConfig, home: URL, slot: Int = 1) {
        self.slot = slot
        name = config.resolvedName
        cli = config.cli ?? .codex; command = config.command; herdrCommand = config.herdrCommand; model = config.model
        effort = config.effort
        address = config.address?.trimmingCharacters(in: .whitespaces) ?? "迅雷へ"
        cwd = ResolvedConfig.expand(config.cwd ?? Self.defaultCWD, home: home)
        cwdSpecified = config.cwd != nil
        displayAgent = config.displayAgent?.trimmingCharacters(in: .whitespaces)
        extraArgs = config.extraArgs ?? []; prompt = config.prompt ?? ""
        notifySound = config.notifySound ?? false; hotkey = config.hotkey ?? Self.defaultHotkey
        allowWork = config.allowWork ?? true
        autoPrompt = config.autoPrompt ?? ""; autoIntervalMinutes = config.autoIntervalMinutes ?? 3
        autoStart = config.autoStart ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case cli, command, herdrCommand, model, address, cwd, extraArgs, prompt, notifySound, hotkey, allowWork
        case autoPrompt, autoIntervalMinutes
        case slot, name, effort, cwdSpecified, displayAgent, autoStart
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cli = try values.decode(AIProvider.self, forKey: .cli)
        command = try values.decodeIfPresent(String.self, forKey: .command)
        herdrCommand = try values.decodeIfPresent(String.self, forKey: .herdrCommand)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        address = try values.decode(String.self, forKey: .address)
        cwd = try values.decode(URL.self, forKey: .cwd)
        extraArgs = try values.decode([String].self, forKey: .extraArgs)
        prompt = try values.decode(String.self, forKey: .prompt)
        notifySound = try values.decode(Bool.self, forKey: .notifySound)
        hotkey = try values.decode(KikigakiConfig.Hotkey.self, forKey: .hotkey)
        // 旧会議のmanifestにこのキーが無い場合だけ、以前の作業可能な契約を引き継ぐ。
        allowWork = try values.contains(.allowWork) ? values.decode(Bool.self, forKey: .allowWork) : true
        autoPrompt = try values.contains(.autoPrompt) ? values.decode(String.self, forKey: .autoPrompt) : ""
        autoIntervalMinutes = try values.contains(.autoIntervalMinutes) ? values.decode(Int.self, forKey: .autoIntervalMinutes) : 3
        // 複数プロファイル以前のmanifestは1つ目の新規起動プロファイルとして読む。
        slot = try values.contains(.slot) ? values.decode(Int.self, forKey: .slot) : 1
        effort = try values.decodeIfPresent(String.self, forKey: .effort)
        displayAgent = try values.decodeIfPresent(String.self, forKey: .displayAgent)
        cwdSpecified = try values.contains(.cwdSpecified) ? values.decode(Bool.self, forKey: .cwdSpecified) : false
        autoStart = try values.contains(.autoStart) ? values.decode(Bool.self, forKey: .autoStart) : false
        let fallbackName = address.hasSuffix("へ") ? String(address.dropLast()) : address
        name = try values.contains(.name) ? values.decode(String.self, forKey: .name) : fallbackName
        guard slot > 0, !name.isEmpty else { throw AIError.invalid("profile slot/name") }
        try AIConfig(name: name, cli: cli, effort: effort, autoPrompt: autoPrompt,
                     autoIntervalMinutes: autoIntervalMinutes).validate()
    }
}

/// 推論の強さ。CLIごとに渡し方も値域も違うので、設定は専用キーで受けて起動時に翻訳する。
///
/// codexの値域は `codex-rs/protocol/src/openai_models.rs` の `ReasoningEffort` から採る。
/// 同リポジトリの `core/config.schema.json` はこのキーを「モデルが提示する非空の文字列」として
/// 定義しており、実際に通る値はモデル依存になる。ここで先に弾き、CLIが拒否したら起動失敗として扱う。
/// claudeの値域は `claude --help` の実測(2.1.266)。
public enum AIEffort {
    public static func values(for provider: AIProvider) -> [String] {
        provider == .codex
            ? ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
            : ["low", "medium", "high", "xhigh", "max"]
    }
    /// codexの `-c` の値はTOMLとして解釈されるため、文字列はクォートを付けて渡す。
    public static func arguments(_ effort: String?, provider: AIProvider) -> [String] {
        guard let effort, !effort.isEmpty else { return [] }
        return provider == .codex ? ["-c", "model_reasoning_effort=\"\(effort)\""] : ["--effort", effort]
    }
    /// 翻訳結果と衝突する追加指定。受理すると順序依存でどちらが効くか読めなくなる
    static func conflicting(_ argument: String, provider: AIProvider) -> Bool {
        let key = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)[0]
        return provider == .codex ? key == "model_reasoning_effort" : key == "--effort"
    }
}

/// 未知の引数を通すと値と起動時promptを区別できないため、対応済みの追加指定だけを受け付ける。
/// 設定・接続先・hooksの自由上書きは受け付けない。権限モードの選択は利用者が明示した場合だけ。
public enum AIExtraArguments {
    public static func validate(_ arguments: [String], provider: AIProvider, label: String = "ai") throws {
        let flags: Set<String> = provider == .codex ? ["--search", "--no-alt-screen", "--strict-config"] : ["--verbose"]
        let options: [String: Set<String>?] = provider == .codex
            ? ["--sandbox": ["read-only", "workspace-write", "danger-full-access"],
               "-s": ["read-only", "workspace-write", "danger-full-access"],
               "--ask-for-approval": ["on-request", "never"], "-a": ["on-request", "never"], "--add-dir": nil]
            : ["--permission-mode": ["default", "manual", "acceptEdits", "plan", "auto", "dontAsk"], "--add-dir": nil]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard !argument.contains("\0") else { throw ConfigError.invalid(description: "\(label).extraArgs contains NUL") }
            guard !AIEffort.conflicting(argument, provider: provider) else {
                throw ConfigError.invalid(description: "\(label).extraArgs must not set the reasoning effort. use \(label).effort instead")
            }
            if flags.contains(argument) { index += 1; continue }
            let pair = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let key = pair[0]
            guard options.keys.contains(key) else { throw ConfigError.invalid(description: "unsupported \(label).extraArgs: \(key)") }
            let value: String
            if pair.count == 2 { value = pair[1] } else {
                index += 1
                guard index < arguments.count else { throw ConfigError.invalid(description: "missing value for \(key)") }
                value = arguments[index]
            }
            guard AIValidation.singleLine(value), !value.hasPrefix("-") else {
                throw ConfigError.invalid(description: "invalid value for \(key)")
            }
            if let allowed = options[key]!, !allowed.contains(value) {
                throw ConfigError.invalid(description: "invalid value for \(key)")
            }
            if key == "--add-dir", !AIValidation.absolutePath(value) {
                throw ConfigError.invalid(description: "--add-dir must be absolute")
            }
            index += 1
        }
    }
}
