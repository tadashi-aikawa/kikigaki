@testable import KikigakiCore

/// 実録由来の話者補正の回帰事例。既存テストと、補正を外した比較の行列テストが共有する。
/// 区間と窓判定は Sortformer 時代のもので、Nemotron での補正の要否の根拠にはしない。
/// 期待値は各テストが確かめてきた現行の出力で、話者の正解を全て人手で付けたものではない
struct RecordedSpeakerFixture {
    let name: String
    let recording: String
    let tokens: [TimedToken]
    /// 窓判定の観測値。区間がある事例では区間から判定し直す
    let raw: [Int?]
    let segments: [SpeakerSegment]
    let expected: [Int?]
}

enum RecordedSpeakerFixtures {
    /// 「じゃあもう10分の1」と「そうなんですよ。」の語頭の分断
    static let jaa: RecordedSpeakerFixture = {
        let text = [" 11日目", "じ", "ゃ", "あ", "も", "う", " 10", "分", "の", " 1", "そ", "う", "なんですよ。"]
        let times = [187.26, 188.34, 188.76, 188.82, 188.94, 189.06, 189.18, 189.36, 189.48, 189.54, 189.66, 190.20, 190.26, 190.80]
        let tokens = text.enumerated().map { TimedToken(text: $0.element, phraseId: 1220, start: times[$0.offset], end: times[$0.offset + 1]) }
        return RecordedSpeakerFixture(name: "じゃあ/そう", recording: "2026-09-05_1529", tokens: tokens,
                                      raw: [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0], segments: [],
                                      expected: [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0])
    }()

    /// 別話者の「はい」「すごいね。」
    static let haiSugoine: RecordedSpeakerFixture = {
        let tokens: [TimedToken] = [
            .init(text: "一応経過報告させていただきますと", phraseId: 1146, start: 180.12, end: 182.82),
            .init(text: "は", phraseId: 1146, start: 182.82, end: 183.06),
            .init(text: "い", phraseId: 1146, start: 183.06, end: 183.18),
            .init(text: "それから毎日続いてまして", phraseId: 1146, start: 183.18, end: 185.22),
            .init(text: "す", phraseId: 1146, start: 185.22, end: 185.58),
            .init(text: "ご", phraseId: 1146, start: 185.58, end: 185.70),
            .init(text: "い", phraseId: 1146, start: 185.70, end: 185.76),
            .init(text: "ね", phraseId: 1146, start: 185.76, end: 185.88),
            .init(text: "。", phraseId: 1146, start: 185.88, end: 186.06),
        ]
        let raw: [Int?] = [0, 1, 1, 0, 1, 1, 1, 1, 1]
        return RecordedSpeakerFixture(name: "はい/すごいね。", recording: "2026-09-05_1529", tokens: tokens, raw: raw,
                                      segments: [], expected: raw)
    }()

    /// 相槌が重なり区間が交互に出る場面で、文中の「代表」だけが相手へ倒れた
    static let daihyou: RecordedSpeakerFixture = {
        let texts = ["は", "い", "管", "理", "の", "プ", "ロ", "代", "表", "の", "松", "村", "で", "す", "。"]
        let times = [24.60, 24.78, 24.90, 25.14, 25.32, 25.44, 25.56, 25.62, 25.80, 25.92, 26.10, 26.28, 26.46, 26.64, 26.70, 26.82]
        let tokens = texts.enumerated().map { TimedToken(text: $0.element, phraseId: 81, start: times[$0.offset], end: times[$0.offset + 1]) }
        let segments = [
            SpeakerSegment(speaker: 0, start: 20.32, end: 24.96), SpeakerSegment(speaker: 1, start: 24.96, end: 25.20),
            SpeakerSegment(speaker: 0, start: 25.04, end: 25.44), SpeakerSegment(speaker: 1, start: 25.44, end: 25.92),
            SpeakerSegment(speaker: 0, start: 25.92, end: 26.40), SpeakerSegment(speaker: 1, start: 26.40, end: 26.88),
        ]
        return RecordedSpeakerFixture(name: "代表", recording: "2026-09-06_1416_2", tokens: tokens,
                                      raw: [0, 0, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1], segments: segments,
                                      expected: Array(repeating: 1, count: tokens.count))
    }()

    /// 発話前の間を含んで長くなった語頭の「い」「僕」。原音をユーザーが確認し、ともに話者2
    static let iBoku: RecordedSpeakerFixture = {
        let tokens = [
            TimedToken(text: "い", phraseId: 1, start: 38.46, end: 40.56),
            TimedToken(text: "や", phraseId: 1, start: 40.56, end: 40.68),
            TimedToken(text: "僕", phraseId: 2, start: 185.46, end: 187.20),
            TimedToken(text: "の", phraseId: 2, start: 187.20, end: 188.04),
        ]
        let segments = [
            SpeakerSegment(speaker: 1, start: 30.32, end: 38.88),
            SpeakerSegment(speaker: 2, start: 40.32, end: 41.28),
            SpeakerSegment(speaker: 1, start: 185.36, end: 185.84),
            SpeakerSegment(speaker: 2, start: 186.96, end: 187.60),
            SpeakerSegment(speaker: 2, start: 187.92, end: 188.88),
        ]
        return RecordedSpeakerFixture(name: "い/僕", recording: "SpeechTailの実録", tokens: tokens,
                                      raw: tokens.map { Aligner.speaker(at: $0.midpoint, segments: segments) },
                                      segments: segments, expected: [2, 2, 2, 2])
    }()

    static let all = [jaa, haiSugoine, daihyou, iBoku]
}
