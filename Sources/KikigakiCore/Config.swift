import Foundation
import TOMLKit

/// `~/.config/kikigaki/config.toml` に対応する設定。設定UIは持たず、ファイルを直接編集する
public struct KikigakiConfig: Codable, Equatable, Sendable {
    public struct Speaker: Codable, Equatable, Sendable {
        public var name: String
        public var avatar: String?
        public init(name: String, avatar: String? = nil) { self.name = name; self.avatar = avatar }
    }
    /// Markdown(と録音WAV)の保存先。`~` を使える
    public var outputDir: String?
    /// 録音WAVを Markdown と並べて残すか
    public var saveRecording: Bool?
    /// 停止時に短い繰り返し相槌を省き、省略前のMarkdownも残す実験機能
    public var dropRepeatedBackchannels: Bool?
    /// 小音量候補の計測・表示だけを行う。本文からの除外はしない。
    public var measureAudioLevels: Bool?
    public var speakers: [Speaker]?
    /// 単数の `[ai]` と配列の `[[ai]]` の両方を読む
    public var ai: AIProfileList?

    public init(outputDir: String? = nil, saveRecording: Bool? = nil, dropRepeatedBackchannels: Bool? = nil,
                speakers: [Speaker]? = nil, ai: AIProfileList? = nil, measureAudioLevels: Bool? = nil) {
        self.outputDir = outputDir
        self.saveRecording = saveRecording
        self.dropRepeatedBackchannels = dropRepeatedBackchannels
        self.measureAudioLevels = measureAudioLevels
        self.speakers = speakers
        self.ai = ai
    }
}

/// 既定値を解決した設定
///
/// グローバルショートカットは廃止した。`[hotkeys]` と `[ai.hotkey]` が書かれていても
/// **読み飛ばす**。既存の設定ファイルを書き換えさせないため、エラーにも警告にもしない。
public struct ResolvedConfig: Equatable, Sendable {
    /// 既定の保存先。人が開く Markdown なので隠しディレクトリではなく書類フォルダに置く
    public static let defaultOutputDir = "~/Documents/KIKIGAKI"

    public var outputDir: URL
    /// 録音WAVは既定では残さない。通常利用では不要でディスクを食うだけで、要るのはデバッグや
    /// 別エンジンでの再処理のとき(タダシの決定)
    public var saveRecording: Bool
    public var dropRepeatedBackchannels: Bool
    public var measureAudioLevels: Bool
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
        measureAudioLevels = config.measureAudioLevels ?? false
        speakers = (config.speakers ?? []).map { speaker in
            var speaker = speaker
            speaker.name = SpeakerNames.normalized(speaker.name)
            if let avatar = speaker.avatar, !avatar.hasPrefix("http://"), !avatar.hasPrefix("https://") {
                speaker.avatar = Self.expand(avatar, home: home).path
            }
            return speaker
        }
        // herdrCommandは共通設定。省略したプロファイルは先頭の値を引き継ぐ。
        let sharedHerdr = config.ai?.profiles.first?.herdrCommand
        aiProfiles = (config.ai?.profiles ?? []).enumerated().map { index, profile in
            var inherited = profile
            if inherited.herdrCommand == nil { inherited.herdrCommand = sharedHerdr }
            return ResolvedAIConfig(config: inherited, home: home, slot: index + 1)
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
