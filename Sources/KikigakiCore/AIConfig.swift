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
    public var cli: AIProvider?
    public var command: String?
    public var model: String?
    public var address: String?
    public var cwd: String?
    public var extraArgs: [String]?
    public var prompt: String?
    public var notifySound: Bool?
    public var hotkey: KikigakiConfig.Hotkey?

    public init(cli: AIProvider? = nil, command: String? = nil, model: String? = nil,
                address: String? = nil, cwd: String? = nil, extraArgs: [String]? = nil,
                prompt: String? = nil, notifySound: Bool? = nil, hotkey: KikigakiConfig.Hotkey? = nil) {
        self.cli = cli; self.command = command; self.model = model; self.address = address
        self.cwd = cwd; self.extraArgs = extraArgs; self.prompt = prompt
        self.notifySound = notifySound; self.hotkey = hotkey
    }

    public func validate() throws {
        func invalid(_ message: String) -> ConfigError { .invalid(description: "ai: " + message) }
        if let command, !AIValidation.absolutePath(command) { throw invalid("command must be absolute") }
        if let cwd, !AIValidation.absolutePath(cwd), !(cwd.hasPrefix("~/") && !cwd.contains("\0")) {
            throw invalid("cwd must be absolute or start with ~/")
        }
        if let model, !AIValidation.singleLine(model) { throw invalid("model must be non-empty and single-line") }
        if let address, !AIValidation.singleLine(address) || address.trimmingCharacters(in: .whitespaces) == "へ" {
            throw invalid("address must contain one non-empty participant name")
        }
        if let prompt, prompt.utf8.count > AILimits.questionBytes || prompt.contains("\0") {
            throw invalid("prompt exceeds limit or contains NUL")
        }
        try AIExtraArguments.validate(extraArgs ?? [], provider: cli ?? .codex)
    }
}

public struct ResolvedAIConfig: Codable, Equatable, Sendable {
    public static let defaultCWD = "~/Library/Application Support/KIKIGAKI/ai-work/"
    public static let defaultHotkey = KikigakiConfig.Hotkey(modifiers: ["ctrl", "alt", "cmd"], key: "a")
    public let cli: AIProvider
    public let command: String?
    public let model: String?
    public let address: String
    public let cwd: URL
    public let extraArgs: [String]
    public let prompt: String
    public let notifySound: Bool
    public let hotkey: KikigakiConfig.Hotkey
    public var participantName: String { address.hasSuffix("へ") ? String(address.dropLast()) : address }

    public init(config: AIConfig, home: URL) {
        cli = config.cli ?? .codex; command = config.command; model = config.model
        address = config.address?.trimmingCharacters(in: .whitespaces) ?? "迅雷へ"
        cwd = ResolvedConfig.expand(config.cwd ?? Self.defaultCWD, home: home)
        extraArgs = config.extraArgs ?? []; prompt = config.prompt ?? ""
        notifySound = config.notifySound ?? false; hotkey = config.hotkey ?? Self.defaultHotkey
    }
}

/// 未知の引数を通すと値と起動時promptを区別できないため、対応済みの追加指定だけを受け付ける。
/// 設定・接続先・hooksの自由上書きは受け付けない。権限モードの選択は利用者が明示した場合だけ。
public enum AIExtraArguments {
    public static func validate(_ arguments: [String], provider: AIProvider) throws {
        let flags: Set<String> = provider == .codex ? ["--search", "--no-alt-screen", "--strict-config"] : ["--verbose"]
        let options: [String: Set<String>?] = provider == .codex
            ? ["--sandbox": ["read-only", "workspace-write", "danger-full-access"],
               "-s": ["read-only", "workspace-write", "danger-full-access"],
               "--ask-for-approval": ["on-request", "never"], "-a": ["on-request", "never"], "--add-dir": nil]
            : ["--effort": ["low", "medium", "high", "xhigh", "max"],
               "--permission-mode": ["default", "manual", "acceptEdits", "plan", "auto", "dontAsk"], "--add-dir": nil]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard !argument.contains("\0") else { throw ConfigError.invalid(description: "ai.extraArgs contains NUL") }
            if flags.contains(argument) { index += 1; continue }
            let pair = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let key = pair[0]
            guard options.keys.contains(key) else { throw ConfigError.invalid(description: "unsupported ai.extraArgs: \(key)") }
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
