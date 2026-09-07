import Foundation

/// 文字起こしエンジンが返す時刻付きトークン。エンジン固有の型(FluidAudio の TokenTiming 等)を
/// Core 層へ持ち込まないための自前の型
public struct TimedToken: Equatable, Sendable {
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

/// 話者判別が返す区間。話者は Sortformer の出力スロット(0〜3)
public struct SpeakerSegment: Equatable, Sendable {
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
    public enum Kind: String, Codable, Sendable { case voice, typed }
    public enum ValidationError: Error, Equatable { case invalidTypedEntry }
    public let kind: Kind
    /// 声には日時を重ねて持たない。手入力は一時停止の境界でも投稿日時を変えない。
    public let postedAt: Date?
    /// voiceのnil = どの話者区間にも当たらなかった。typedは常にnil。
    public var speaker: Int?
    public var start: Double
    public var end: Double
    public var text: String

    public init(speaker: Int?, start: Double, end: Double, text: String) {
        kind = .voice
        postedAt = nil
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }

    public init(typedText: String, at audioTime: Double, postedAt: Date) throws {
        kind = .typed
        speaker = nil
        start = audioTime
        end = audioTime
        self.postedAt = postedAt
        text = Self.normalizedTypedText(typedText)
        guard validTypedEntry else { throw ValidationError.invalidTypedEntry }
    }

    public static func normalizedTypedText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validTypedEntry: Bool {
        speaker == nil && start.isFinite && start >= 0 && end == start
            && postedAt?.timeIntervalSinceReferenceDate.isFinite == true
            && !text.isEmpty && !text.contains("\0") && text == Self.normalizedTypedText(text)
    }

    private enum CodingKeys: String, CodingKey { case kind, postedAt, speaker, start, end, text }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // kindだけを省略できる。未知のkindや欠損したtypedの投稿日時は音声へ読み替えない。
        kind = values.contains(.kind) ? try values.decode(Kind.self, forKey: .kind) : .voice
        postedAt = try values.decodeIfPresent(Date.self, forKey: .postedAt)
        speaker = try values.decodeIfPresent(Int.self, forKey: .speaker)
        start = try values.decode(Double.self, forKey: .start)
        end = try values.decode(Double.self, forKey: .end)
        text = try values.decode(String.self, forKey: .text)
        guard kind == .typed ? validTypedEntry : postedAt == nil else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid utterance origin or postedAt"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard kind == .typed ? validTypedEntry : postedAt == nil else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Invalid utterance origin or postedAt"))
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encodeIfPresent(postedAt, forKey: .postedAt)
        try values.encodeIfPresent(speaker, forKey: .speaker)
        try values.encode(start, forKey: .start)
        try values.encode(end, forKey: .end)
        try values.encode(text, forKey: .text)
    }
}
