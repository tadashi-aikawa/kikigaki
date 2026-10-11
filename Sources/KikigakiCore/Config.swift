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
    /// 小音量候補の計測・表示だけを行う。本文からの除外はしない。
    public var measureAudioLevels: Bool?
    /// 話者名の候補に使う、議事録のfrontmatterのキー
    public var participantsKey: String?
    public var autoSendPhrases: [String]?
    public var speakers: [Speaker]?
    /// 配列の `[[ai]]`
    public var ai: AIProfileList?

    public init(outputDir: String? = nil, saveRecording: Bool? = nil,
                speakers: [Speaker]? = nil, ai: AIProfileList? = nil, measureAudioLevels: Bool? = nil,
                participantsKey: String? = nil, autoSendPhrases: [String]? = nil) {
        self.outputDir = outputDir
        self.saveRecording = saveRecording
        self.measureAudioLevels = measureAudioLevels
        self.participantsKey = participantsKey
        self.autoSendPhrases = autoSendPhrases
        self.speakers = speakers
        self.ai = ai
    }
}

/// 既定値を解決した設定
public struct ResolvedConfig: Equatable, Sendable {
    /// 既定の保存先。人が開く Markdown なので隠しディレクトリではなく書類フォルダに置く
    public static let defaultOutputDir = "~/Documents/KIKIGAKI"
    /// タダシの議事録が使うキー。`attendees` などの流儀の人は設定で変える
    public static let defaultParticipantsKey = "participants"
    public static let defaultAutoSendPhrases = ["しおりを挟んで", "栞を挟んで", "しおりをはさんで", "栞をはさんで"]

    public var outputDir: URL
    /// 録音WAVは既定では残さない。通常利用では不要でディスクを食うだけで、要るのはデバッグや
    /// 別エンジンでの再処理のとき(タダシの決定)
    public var saveRecording: Bool
    public var measureAudioLevels: Bool
    public var participantsKey: String
    public var autoSendPhrases: [String]
    public var speakers: [KikigakiConfig.Speaker]
    /// 設定順のプロファイル。slotは1始まりで、この並びが宛先ポップアップの並びになる
    public var aiProfiles: [ResolvedAIConfig]
    /// 既定のプロファイル。設定の有無の判定はこれを見る。
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
        measureAudioLevels = config.measureAudioLevels ?? false
        participantsKey = config.participantsKey ?? Self.defaultParticipantsKey
        autoSendPhrases = config.autoSendPhrases ?? Self.defaultAutoSendPhrases
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
        if let phrases = config.autoSendPhrases {
            guard phrases.count <= 20 else { throw ConfigError.invalid(description: "autoSendPhrases allows at most 20 phrases") }
            var normalized = Set<String>()
            for phrase in phrases {
                let value = AutoSendPhrase.normalize(phrase)
                guard phrase.count <= 64, !value.isEmpty, normalized.insert(value).inserted else {
                    throw ConfigError.invalid(description: "autoSendPhrases must be non-empty and unique after normalization, with at most 64 characters per phrase")
                }
            }
        }
        var speakerNames = Set<String>()
        for speaker in config.speakers ?? [] {
            let name = SpeakerNames.normalized(speaker.name)
            guard !name.isEmpty, speakerNames.insert(name).inserted else {
                throw ConfigError.invalid(description: "speakers.name must be non-empty and unique: \(name)")
            }
        }
        // frontmatterの行頭で `<キー>:` と照合するため、区切りになる文字と空白を含むキーは読めない
        if let key = config.participantsKey,
           key.isEmpty || key.hasPrefix("-") || key.contains(where: { $0.isWhitespace || ":#\"'[]{},".contains($0) }) {
            throw ConfigError.invalid(description: "participantsKey must be a plain frontmatter key (got: \(key))")
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
