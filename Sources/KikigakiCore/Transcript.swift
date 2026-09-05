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
public struct Utterance: Equatable, Sendable {
    /// nil = どの話者区間にも当たらなかった
    public var speaker: Int?
    public var start: Double
    public var end: Double
    public var text: String

    public init(speaker: Int?, start: Double, end: Double, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}
