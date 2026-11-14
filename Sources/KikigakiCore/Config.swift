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
    /// 会議の手動宛先へ下書きを送る、OS全体で効くキー。空文字は未割り当て
    public var manualSendHotkey: String?
    /// 録音中の画面の記録を止める・入れ直す、OS全体で効くキー。空文字は未割り当て
    public var screenCaptureHotkey: String?
    /// 録音中に会議Markdownへ途中の記録を書く間隔(秒)
    public var autoSaveIntervalSeconds: Int?
    public var speakers: [Speaker]?
    /// 配列の `[[ai]]`
    public var ai: AIProfileList?

    public init(outputDir: String? = nil, saveRecording: Bool? = nil,
                speakers: [Speaker]? = nil, ai: AIProfileList? = nil, measureAudioLevels: Bool? = nil,
                participantsKey: String? = nil, autoSendPhrases: [String]? = nil, manualSendHotkey: String? = nil,
                autoSaveIntervalSeconds: Int? = nil, screenCaptureHotkey: String? = nil) {
        self.outputDir = outputDir
        self.screenCaptureHotkey = screenCaptureHotkey
        self.saveRecording = saveRecording
        self.measureAudioLevels = measureAudioLevels
        self.participantsKey = participantsKey
        self.autoSendPhrases = autoSendPhrases
        self.manualSendHotkey = manualSendHotkey
        self.autoSaveIntervalSeconds = autoSaveIntervalSeconds
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
    /// 日本語の会話に紛れない短い外国語。正規化はヴァとバを揃えないので両方の表記を持つ
    public static let defaultAutoSendPhrases = ["アバンティ", "アヴァンティ"]
    /// 異常終了で失うのを最大1分に抑える。1時間の会議でも本文は百KB前後で、書き込みの負担にならない
    public static let defaultAutoSaveIntervalSeconds = 60
    public static let autoSaveIntervalRange = 10...3600

    public var outputDir: URL
    /// 録音WAVは既定では残さない。通常利用では不要でディスクを食うだけで、要るのはデバッグや
    /// 別エンジンでの再処理のとき(タダシの決定)
    public var saveRecording: Bool
    public var measureAudioLevels: Bool
    public var participantsKey: String
    public var autoSendPhrases: [String]
    /// 既定は未割り当て。どのキーも誰かのOS・アプリの既定とぶつかりうる
    public var manualSendHotkey: GlobalHotkey?
    /// 既定は未割り当て。理由は `manualSendHotkey` と同じ
    public var screenCaptureHotkey: GlobalHotkey?
    /// 録音開始時に会議へ固定する。進行中の会議の間隔は再読込で変えない
    public var autoSaveIntervalSeconds: Int
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
        // 保存先はここで1回だけ字句上で正規化する。会議Markdown・画像の置き場・AIへ渡す会話ファイルと `image_dirs` は
        // この値から導き、後から正規化し直さない。途中で正規化すると表記がずれ、Skillの文字列の照合が外れる。
        // `~` の展開も文字列だけで行い、ファイルシステムへ問い合わせない。
        outputDir = LexicalPath.directory(Self.expandedPath(config.outputDir ?? Self.defaultOutputDir, home: home))
        saveRecording = config.saveRecording ?? false
        measureAudioLevels = config.measureAudioLevels ?? false
        participantsKey = config.participantsKey ?? Self.defaultParticipantsKey
        autoSendPhrases = config.autoSendPhrases ?? Self.defaultAutoSendPhrases
        manualSendHotkey = config.manualSendHotkey.flatMap(GlobalHotkey.init)
        screenCaptureHotkey = config.screenCaptureHotkey.flatMap(GlobalHotkey.init)
        autoSaveIntervalSeconds = config.autoSaveIntervalSeconds ?? Self.defaultAutoSaveIntervalSeconds
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
    /// `~` と `~/` だけを家のディレクトリへ置き換えた文字列。`URL` を作らないので、在るかどうかを見ない。
    static func expandedPath(_ path: String, home: URL) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.path + "/" + path.dropFirst(2) }
        return path
    }

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
            try AutoSendPhrase.validate(phrases)
        }
        let hotkeys = [("manualSendHotkey", config.manualSendHotkey), ("screenCaptureHotkey", config.screenCaptureHotkey)]
        for case let (key, text?) in hotkeys where !text.isEmpty && GlobalHotkey(text) == nil {
            // 単独キーやshiftだけの組は、全アプリでその文字を打てなくする
            throw ConfigError.invalid(description:
                "\(key) must be modifier+key with ctrl, alt or cmd (F1-F20 may stand alone) (got: \(text))")
        }
        // 同じキーは2つ目の登録が必ず失敗する。どちらが効くかを登録の順で決めない
        if let manual = config.manualSendHotkey.flatMap(GlobalHotkey.init),
           manual == config.screenCaptureHotkey.flatMap(GlobalHotkey.init) {
            throw ConfigError.invalid(description:
                "screenCaptureHotkey must differ from manualSendHotkey (got: \(manual.display))")
        }
        if let seconds = config.autoSaveIntervalSeconds, !ResolvedConfig.autoSaveIntervalRange.contains(seconds) {
            throw ConfigError.invalid(description: "autoSaveIntervalSeconds must be 10...3600 (got: \(seconds))")
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
            try validateOutputDirParentReference(dir)
        }
    }

    /// `outputDir` の要素に `..` があれば設定エラーにする。
    ///
    /// 仮決め(タダシの承認待ち)。外すときはこの関数の呼び出しと、`Resources/config.schema.json` の `outputDir` の説明、
    /// docs/config.md と site の設定リファレンスの1文を消す。`LexicalPath` は `..` を畳まないので、外しても保存先は変わらない。
    /// - スキーマの `pattern` では表さない。Taploの正規表現は先読みを持たず、`not` は補完を止めるため使えない
    /// - 外す場合の注意: 下の理由のとおり、残した `..` は `AIEnvelope.validate` が拒む。AIへ渡すには別の手当てが要る
    /// - 理由: `..` は字句上では安全に畳めない。直前の要素がシンボリックリンクだと、字句上で戻した場所とOSが辿る場所が違い、
    ///   既存の設定の保存先が黙って変わる。かといって畳まずに残すと、会話ファイルのパスの検証が `..` を拒み、AIへ渡せない
    static func validateOutputDirParentReference(_ dir: String) throws {
        guard LexicalPath.containsParentReference(dir) else { return }
        throw ConfigError.invalid(description:
            "outputDir must not contain '..'; write an absolute path or a path starting with ~ without '..' (got: \(dir))")
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
