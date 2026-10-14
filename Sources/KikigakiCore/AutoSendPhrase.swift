import Foundation

/// 声の合図の比較。NFKCとかなの統一だけを使い、漢字の読みには変換しない。
public enum AutoSendPhrase {
    public static func validate(_ phrases: [String], label: String = "autoSendPhrases") throws {
        guard phrases.count <= 20 else { throw ConfigError.invalid(description: "\(label) allows at most 20 phrases") }
        var normalized = Set<String>()
        for phrase in phrases {
            let value = normalize(phrase)
            guard phrase.count <= 64, !value.isEmpty, normalized.insert(value).inserted else {
                throw ConfigError.invalid(description: "\(label) must be non-empty and unique after normalization, with at most 64 characters per phrase")
            }
        }
    }

    public static func normalize(_ text: String) -> String {
        let compatible = text.precomposedStringWithCompatibilityMapping
        let hiragana = compatible.applyingTransform(.hiraganaToKatakana, reverse: true) ?? compatible
        return String(String.UnicodeScalarView(hiragana.unicodeScalars.filter { scalar in
            if scalar.properties.isWhitespace { return false }
            switch scalar.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .otherPunctuation,
                 .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol,
                 .spaceSeparator, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }))
    }
}

/// 会議ごとの合図の判定。確定行を入力し、時計・音・送信はアプリ側で扱う。
public struct AutoSendPhraseState: Sendable {
    public enum Decision: String, Equatable, Sendable { case fire, unavailable, cooldown, watermark }
    public struct Event: Equatable, Sendable {
        public let decision: Decision
        public let phrase: String
        public let start: Double
        public let end: Double
        public let at: TimeInterval
    }
    private struct Observation: Equatable, Sendable { let end: Double; let text: String }
    private var phrases: [String]
    private var observed: [Double: Observation] = [:]
    /// 無効・10秒以内に認識した合図も、後の表示更新から再試行しない。
    private var handledStarts: Set<Double> = []
    public private(set) var watermark: Double?
    public private(set) var lastFiredAt: TimeInterval?

    public init(phrases: [String]) { self.phrases = phrases.map(AutoSendPhrase.normalize).filter { !$0.isEmpty } }

    /// 宛先が替わっても判定済みの行・水位・10秒の無視を引き継ぎ、同じ発話を再試行しない。
    public mutating func replacePhrases(_ phrases: [String]) {
        self.phrases = phrases.map(AutoSendPhrase.normalize).filter { !$0.isEmpty }
    }

    public mutating func observe(_ row: Utterance, now: TimeInterval,
                                 automaticActive: Bool, canFireNow: Bool) -> Event? {
        guard row.kind == .voice, row.start.isFinite, row.end.isFinite, now.isFinite else { return nil }
        let observation = Observation(end: row.end, text: row.text)
        guard observed[row.start] != observation else { return nil }
        observed[row.start] = observation
        guard automaticActive, !phrases.isEmpty, !handledStarts.contains(row.start) else { return nil }
        let text = AutoSendPhrase.normalize(row.text)
        guard let phrase = phrases.first(where: { text.contains($0) }) else { return nil }
        handledStarts.insert(row.start)
        let decision: Decision
        if let watermark, row.start <= watermark { decision = .watermark }
        else if let lastFiredAt, now - lastFiredAt < 10 { decision = .cooldown }
        else if !canFireNow { decision = .unavailable }
        else {
            watermark = row.end
            lastFiredAt = now
            decision = .fire
        }
        return Event(decision: decision, phrase: phrase, start: row.start, end: row.end, at: now)
    }
}
