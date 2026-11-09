import Foundation

/// 文字起こしエンジンが返す時刻付きトークン。エンジン固有の型(FluidAudio の TokenTiming 等)を
/// Core 層へ持ち込まないための自前の型
public struct TimedToken: Codable, Equatable, Sendable {
    public var text: String
    /// エンジンのフレーズ id。同じ確定結果に属するトークンは同じ値を持ち、話者の突き合わせで
    /// フレーズ境界として使う(Apple の確定結果は10秒超で複数の発話交代をまたぐため、
    /// 境界そのものではなく「この中でさらに切る」単位)
    public var phraseId: Int
    public var start: Double
    public var end: Double

    public init(text: String, phraseId: Int, start: Double, end: Double) {
        self.text = text
        self.phraseId = phraseId
        self.start = start
        self.end = end
    }

    public var midpoint: Double { (start + end) / 2 }
    public var duration: Double { end - start }
}

/// 話者判別が返す区間。話者は Nemotron 3 の出力スロット(0〜7)
public struct SpeakerSegment: Codable, Equatable, Sendable {
    public var speaker: Int
    public var start: Double
    public var end: Double

    public init(speaker: Int, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// 話者ごとにまとめた発話行
public struct Utterance: Codable, Equatable, Sendable {
    /// - voice: 声。話者判別と小音量の除外の対象
    /// - typed: 手入力
    /// - screen: 画面の記録。画像1枚の行か、記録の停止・再開・取得不能を示すイベントの行
    /// 声以外の行の扱いは [画面の記録](docs/screen-capture.md) の「経路ごとの扱い」で3分類する。
    public enum Kind: String, Codable, Sendable { case voice, typed, screen }
    public enum ValidationError: Error, Equatable { case invalidTypedEntry, invalidScreenEntry }
    /// 画面の記録のイベントの行の本文。保存物の契約なので文言を変えない。
    public enum ScreenEvent: Equatable, Sendable {
        case stopped
        case resumed
        case unavailable(String)

        public var text: String {
            switch self {
            case .stopped: return "記録を停止"
            case .resumed: return "記録を再開"
            case let .unavailable(reason): return Self.unavailablePrefix + reason
            }
        }

        static let unavailablePrefix = "記録できません: "

        public init?(text: String) {
            switch text {
            case Self.stopped.text: self = .stopped
            case Self.resumed.text: self = .resumed
            default:
                guard text.hasPrefix(Self.unavailablePrefix), text.count > Self.unavailablePrefix.count else { return nil }
                self = .unavailable(String(text.dropFirst(Self.unavailablePrefix.count)))
            }
        }
    }

    public let kind: Kind
    /// 声には日時を重ねて持たない。手入力は一時停止の境界でも投稿日時を変えない。
    /// 画面の行は画像を観測した実時刻。
    public let postedAt: Date?
    /// 投稿時に会議の保存先へコピーした画像。旧archiveでは省略される。画面の画像の行はちょうど1つ。
    public let imagePaths: [String]
    /// voiceのnil = どの話者区間にも当たらなかった。typed・screenは常にnil。
    public var speaker: Int?
    public var start: Double
    public var end: Double
    public var text: String

    public init(speaker: Int?, start: Double, end: Double, text: String) {
        kind = .voice
        postedAt = nil
        imagePaths = []
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }

    public init(typedText: String, at audioTime: Double, postedAt: Date, imagePaths: [String] = []) throws {
        kind = .typed
        speaker = nil
        start = audioTime
        end = audioTime
        self.postedAt = postedAt
        self.imagePaths = imagePaths
        text = Self.normalizedTypedText(typedText)
        guard validTypedEntry else { throw ValidationError.invalidTypedEntry }
    }

    /// 画面の画像の行。`label` はディスプレイ名と最前面のウィンドウの題で、1行に収める。
    public init(screenLabel label: String, imagePath: String, at audioTime: Double, postedAt: Date) throws {
        kind = .screen
        speaker = nil
        start = audioTime
        end = audioTime
        self.postedAt = postedAt
        imagePaths = [imagePath]
        text = Self.normalizedScreenLabel(label)
        guard validScreenEntry else { throw ValidationError.invalidScreenEntry }
    }

    /// 画面の記録のイベントの行。画像を持たない。
    public init(screenEvent event: ScreenEvent, at audioTime: Double, postedAt: Date) throws {
        kind = .screen
        speaker = nil
        start = audioTime
        end = audioTime
        self.postedAt = postedAt
        imagePaths = []
        text = event.text
        guard validScreenEntry else { throw ValidationError.invalidScreenEntry }
    }

    /// 声以外の行。手入力と画面の記録で共通にする経路(併合・退避・AI送信の固定)が使う。
    public var isEntry: Bool { kind != .voice }

    /// 画面のイベントの行なら、その中身。
    public var screenEvent: ScreenEvent? {
        kind == .screen && imagePaths.isEmpty ? ScreenEvent(text: text) : nil
    }

    /// ウィンドウの題は利用者のアプリが決める。改行と制御文字を空白へ寄せ、1行の見出しに収める。
    public static func normalizedScreenLabel(_ label: String) -> String {
        String(String.UnicodeScalarView(label.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
        })).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    public static func normalizedTypedText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validTypedEntry: Bool {
        speaker == nil && start.isFinite && start >= 0 && end == start
            && postedAt?.timeIntervalSinceReferenceDate.isFinite == true
            && (!text.isEmpty || !imagePaths.isEmpty) && !text.contains("\0") && text == Self.normalizedTypedText(text)
            && imagePaths.allSatisfy(Self.validImagePath)
    }

    /// 画像の行は画像1枚と空でない見出し、イベントの行は画像なしと決まった文言のどちらか。
    private var validScreenEntry: Bool {
        guard speaker == nil, start.isFinite, start >= 0, end == start,
              postedAt?.timeIntervalSinceReferenceDate.isFinite == true else { return false }
        if imagePaths.isEmpty { return ScreenEvent(text: text) != nil && text == Self.normalizedScreenLabel(text) }
        return imagePaths.count == 1 && imagePaths.allSatisfy(Self.validImagePath)
            && !text.isEmpty && text == Self.normalizedScreenLabel(text)
    }

    private static func validImagePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("`")
            && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
    }

    private var validOrigin: Bool {
        switch kind {
        case .voice: return postedAt == nil && imagePaths.isEmpty
        case .typed: return validTypedEntry
        case .screen: return validScreenEntry
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, postedAt, speaker, start, end, text, imagePaths }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // kindだけを省略できる。未知のkindや欠損したtypedの投稿日時は音声へ読み替えない。
        kind = values.contains(.kind) ? try values.decode(Kind.self, forKey: .kind) : .voice
        postedAt = try values.decodeIfPresent(Date.self, forKey: .postedAt)
        imagePaths = try values.decodeIfPresent([String].self, forKey: .imagePaths) ?? []
        speaker = try values.decodeIfPresent(Int.self, forKey: .speaker)
        start = try values.decode(Double.self, forKey: .start)
        end = try values.decode(Double.self, forKey: .end)
        text = try values.decode(String.self, forKey: .text)
        guard validOrigin else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid utterance origin or postedAt"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard validOrigin else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Invalid utterance origin or postedAt"))
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encodeIfPresent(postedAt, forKey: .postedAt)
        if !imagePaths.isEmpty { try values.encode(imagePaths, forKey: .imagePaths) }
        try values.encodeIfPresent(speaker, forKey: .speaker)
        try values.encode(start, forKey: .start)
        try values.encode(end, forKey: .end)
        try values.encode(text, forKey: .text)
    }
}
