import Foundation
import TOMLKit

/// `~/.config/kikigaki/config.toml` に対応する設定。設定UIは持たず、ファイルを直接編集する
public struct KikigakiConfig: Codable, Equatable, Sendable {
    public struct Speaker: Codable, Equatable, Sendable {
        public var name: String
        public var avatar: String?
        public init(name: String, avatar: String? = nil) { self.name = name; self.avatar = avatar }
    }
    public struct Hotkey: Codable, Equatable, Sendable {
        public var modifiers: [String]
        public var key: String

        public init(modifiers: [String], key: String) {
            self.modifiers = modifiers
            self.key = key
        }
    }

    public struct Hotkeys: Codable, Equatable, Sendable {
        /// 録音の開始・停止(トグル)
        public var toggleRecording: Hotkey?
        /// 一時停止・再開(トグル)
        public var togglePause: Hotkey?

        public init(toggleRecording: Hotkey? = nil, togglePause: Hotkey? = nil) {
            self.toggleRecording = toggleRecording
            self.togglePause = togglePause
        }
    }

    /// Markdown(と録音WAV)の保存先。`~` を使える
    public var outputDir: String?
    /// 録音WAVを Markdown と並べて残すか
    public var saveRecording: Bool?
    /// 停止時に短い繰り返し相槌を省き、省略前のMarkdownも残す実験機能
    public var dropRepeatedBackchannels: Bool?
    public var hotkeys: Hotkeys?
    public var speakers: [Speaker]?
    /// 単数の `[ai]` と配列の `[[ai]]` の両方を読む
    public var ai: AIProfileList?

    public init(outputDir: String? = nil, saveRecording: Bool? = nil, hotkeys: Hotkeys? = nil, dropRepeatedBackchannels: Bool? = nil,
                speakers: [Speaker]? = nil, ai: AIProfileList? = nil) {
        self.outputDir = outputDir
        self.saveRecording = saveRecording
        self.hotkeys = hotkeys
        self.dropRepeatedBackchannels = dropRepeatedBackchannels
        self.speakers = speakers
        self.ai = ai
    }
}

/// 既定値を解決した設定
public struct ResolvedConfig: Equatable, Sendable {
    /// 既定の保存先。人が開く Markdown なので隠しディレクトリではなく書類フォルダに置く
    public static let defaultOutputDir = "~/Documents/KIKIGAKI"
    /// 既定のショートカット。ctrl+alt+cmd は他アプリのショートカットとまず衝突しない組み合わせ
    public static let defaultToggleRecording = KikigakiConfig.Hotkey(modifiers: ["ctrl", "alt", "cmd"], key: "k")
    public static let defaultTogglePause = KikigakiConfig.Hotkey(modifiers: ["ctrl", "alt", "cmd"], key: "p")

    public var outputDir: URL
    /// 録音WAVは既定では残さない。通常利用では不要でディスクを食うだけで、要るのはデバッグや
    /// 別エンジンでの再処理のとき(タダシの決定)
    public var saveRecording: Bool
    public var dropRepeatedBackchannels: Bool
    public var toggleRecording: KikigakiConfig.Hotkey
    public var togglePause: KikigakiConfig.Hotkey
    public var speakers: [KikigakiConfig.Speaker]
    /// 設定順のプロファイル。slotは1始まりで、この並びが宛先ポップアップの並びになる
    public var aiProfiles: [ResolvedAIConfig]
    /// 既定のプロファイル。ホットキーと設定の有無の判定はこれを見る。
    /// 代入は1つ目の差し替えで、nilは全プロファイルの取り消し
    public var ai: ResolvedAIConfig? {
        get { aiProfiles.first }
        set {
            guard let newValue else { aiProfiles = []; return }
            aiProfiles = [newValue] + aiProfiles.dropFirst()
        }
    }
    /// 録音開始で自動送信を始めるプロファイル。設定で1つまでに制限している
    public var aiAutoStart: ResolvedAIConfig? { aiProfiles.first { $0.autoStart } }

    public init(config: KikigakiConfig, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        outputDir = Self.expand(config.outputDir ?? Self.defaultOutputDir, home: home)
        saveRecording = config.saveRecording ?? false
        dropRepeatedBackchannels = config.dropRepeatedBackchannels ?? false
        toggleRecording = config.hotkeys?.toggleRecording ?? Self.defaultToggleRecording
        togglePause = config.hotkeys?.togglePause ?? Self.defaultTogglePause
        speakers = (config.speakers ?? []).map { speaker in
            var speaker = speaker
            speaker.name = SpeakerNames.normalized(speaker.name)
            if let avatar = speaker.avatar, !avatar.hasPrefix("http://"), !avatar.hasPrefix("https://") {
                speaker.avatar = Self.expand(avatar, home: home).path
            }
            return speaker
        }
        aiProfiles = (config.ai?.profiles ?? []).enumerated().map {
            ResolvedAIConfig(config: $1, home: home, slot: $0 + 1)
        }
    }

    /// 先頭の `~` をホームに置き換える。`~user` 形式は扱わない
    static func expand(_ path: String, home: URL) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }
}

public enum ConfigError: Error, Equatable {
    case unreadable(path: String)
    case invalid(description: String)
}

public enum ConfigLoader {
    /// 既定の設定ファイルパス(KOKUKOKU と同じ ~/.config/<product>/ 配下)
    public static func defaultPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("kikigaki")
            .appendingPathComponent("config.toml")
    }

    /// TOML文字列から設定を読み込む
    public static func parse(toml: String) throws -> KikigakiConfig {
        let config: KikigakiConfig
        do {
            config = try TOMLDecoder().decode(KikigakiConfig.self, from: toml)
        } catch {
            throw ConfigError.invalid(description: String(describing: error))
        }
        try validate(config)
        return config
    }

    /// 修飾キー名(KeyCodes が解釈できるもの)
    public static let modifierNames: Set<String> = ["cmd", "command", "alt", "option", "ctrl", "control", "shift"]

    private static func validate(_ config: KikigakiConfig) throws {
        try config.ai?.validate()
        var speakerNames = Set<String>()
        for speaker in config.speakers ?? [] {
            let name = SpeakerNames.normalized(speaker.name)
            guard !name.isEmpty, speakerNames.insert(name).inserted else {
                throw ConfigError.invalid(description: "speakers.name must be non-empty and unique: \(name)")
            }
        }
        if let dir = config.outputDir {
            if dir.trimmingCharacters(in: .whitespaces).isEmpty {
                throw ConfigError.invalid(description: "outputDir must be a non-empty string")
            }
            // 相対パスは実行時のカレントディレクトリ次第で保存先が変わるので受け付けない
            if !dir.hasPrefix("/"), !dir.hasPrefix("~") {
                throw ConfigError.invalid(description: "outputDir must be an absolute path or start with ~ (got: \(dir))")
            }
        }
        let resolved = ResolvedConfig(config: config)
        // 同じ条件の2プロファイルは同じペインへ解決する。streamと世代が別のまま会話が混ざるので止める。
        var criteria = Set<String>()
        for profile in resolved.aiProfiles {
            guard let target = profile.criteria else { continue }
            let key = (target.cwd ?? "") + "\n" + (target.displayAgent ?? "")
            guard criteria.insert(key).inserted else {
                throw ConfigError.invalid(description: "ai: two profiles resolve to the same pane: \(profile.name)")
            }
        }
        var hotkeys = [("toggleRecording", resolved.toggleRecording), ("togglePause", resolved.togglePause)]
        if let ai = resolved.ai { hotkeys.append(("ai", ai.hotkey)) }
        for (label, hotkey) in hotkeys {
            if hotkey.key.trimmingCharacters(in: .whitespaces).isEmpty {
                throw ConfigError.invalid(description: "hotkeys.\(label).key must be a non-empty string")
            }
            for modifier in hotkey.modifiers where !modifierNames.contains(modifier.lowercased()) {
                throw ConfigError.invalid(description: "hotkeys.\(label).modifiers contains unknown modifier: \(modifier)")
            }
        }
        // 2操作に同じキーを割り当てると後の登録が失敗して片方を失うので、読み込み時に止める
        if Self.normalized(resolved.toggleRecording) == Self.normalized(resolved.togglePause) {
            throw ConfigError.invalid(description: "hotkeys.toggleRecording and hotkeys.togglePause must differ")
        }
        if let ai = resolved.ai,
           [resolved.toggleRecording, resolved.togglePause].contains(where: { Self.normalized($0) == Self.normalized(ai.hotkey) }) {
            throw ConfigError.invalid(description: "ai.hotkey must differ from recording hotkeys")
        }
    }

    private static func normalized(_ hotkey: KikigakiConfig.Hotkey) -> String {
        let modifiers = hotkey.modifiers.map { name -> String in
            switch name.lowercased() {
            case "command": return "cmd"
            case "option": return "alt"
            case "control": return "ctrl"
            default: return name.lowercased()
            }
        }
        return Set(modifiers).sorted().joined(separator: "+") + "+" + hotkey.key.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// 設定ファイルを読み込む。ファイルが存在しない場合は既定設定を返す
    public static func load(from url: URL = defaultPath()) throws -> KikigakiConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return KikigakiConfig()
        }
        guard let toml = try? String(contentsOf: url, encoding: .utf8) else {
            throw ConfigError.unreadable(path: url.path)
        }
        return try parse(toml: toml)
    }
}
