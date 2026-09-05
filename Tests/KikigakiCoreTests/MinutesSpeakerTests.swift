import Testing
@testable import KikigakiCore

@Suite struct MinutesSpeakerTests {
    @Test func 再録音で重なった語頭と文末を本筋へつなぐ() {
        let texts = ["思", "い", "通", "り", "行", "き", "ま", "す", "。", "住", "吉", "さ", "ん", "仕", "事", "っ", "て", "行", "か", "な", "い", "と", "思", "い", "ま", "す", "よ", "。"]
        let times = [48.18, 49.98, 50.10, 50.28, 50.40, 50.52, 50.58, 50.70, 50.76, 50.88, 51.06, 51.24, 51.36, 51.48, 51.72, 51.84, 52.02, 52.08, 53.40, 53.46, 53.58, 53.64, 53.70, 53.82, 53.94, 54.00, 54.06, 54.12, 54.24]
        let tokens = texts.enumerated().map { TimedToken(text: $0.element, phraseId: 295, start: times[$0.offset], end: times[$0.offset + 1]) }
        let segments: [SpeakerSegment] = [
            .init(speaker: 2, start: 46.16, end: 48.48), .init(speaker: 1, start: 48.16, end: 48.96),
            .init(speaker: 1, start: 49.60, end: 49.84), .init(speaker: 2, start: 49.76, end: 52.48),
            .init(speaker: 2, start: 52.72, end: 54.48), .init(speaker: 1, start: 53.12, end: 55.52),
        ]
        #expect(Aligner.speakers(for: tokens, segments: segments) == Array(repeating: 2, count: tokens.count))
    }

    @Test func 重複中でも一語の返答と独立した質問は保持する() {
        for text in ["はい", "あ、本当ですか"] {
            let tokens = [TimedToken(text: "説明です", phraseId: 1, start: 0, end: 3),
                          TimedToken(text: "。", phraseId: 1, start: 3, end: 3.01),
                          TimedToken(text: text, phraseId: 1, start: 3.01, end: 3.81),
                          TimedToken(text: "続きの説明です", phraseId: 1, start: 3.81, end: 7)]
            let result = Aligner.smoothSpeakers(tokens: tokens, speakers: [0, 0, 1, 0],
                                                segments: [.init(speaker: 0, start: 0, end: 7), .init(speaker: 1, start: 3, end: 4)])
            #expect(result[2] == 1)
        }
    }

    @Test func 丁寧語尾を重ねて思いますですという語を作らない() {
        let texts = ["そう", "思い", "ます", "です", "よ", "ね"]
        let times = [0.0, 0.3, 0.6, 0.9, 1.2, 1.35, 1.5]
        let tokens = texts.enumerated().map { TimedToken(text: $0.element, phraseId: 1, start: times[$0.offset], end: times[$0.offset + 1]) }
        let words = WordBoundaries(tokens: tokens).tokenRanges.map { tokens[$0].map(\.text).joined() }
        #expect(!words.contains("思いますです"))
    }

    @Test func 文中のかどうかを独立した質問として保護しない() {
        let texts = ["これって", "使え", "ます", "か", "どうかわからないんですけど"]
        let times = [0.0, 0.8, 1.1, 1.4, 1.5, 4.0]
        let tokens = texts.enumerated().map { TimedToken(text: $0.element, phraseId: 1, start: times[$0.offset], end: times[$0.offset + 1]) }
        #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: [0, 1, 1, 1, 0]) == Array(repeating: 0, count: 5))
    }

    @Test func 質問の保護は下限時間と後続のどうかを確認する() {
        for span in [0.59, 0.6] {
            let tokens = [TimedToken(text: "あ、本当ですか", phraseId: 1, start: 0, end: span),
                          TimedToken(text: "なくて目にしました", phraseId: 1, start: span, end: 3)]
            #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: [1, 0])[0] == (span < 0.6 ? 0 : 1))
        }
        let tokens = [TimedToken(text: "使えますか", phraseId: 1, start: 0, end: 0.8),
                      TimedToken(text: "どうかわかりません", phraseId: 1, start: 0.8, end: 3)]
        #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: [1, 0]) == [0, 0])
    }

    @Test func 自己肯定ですよの長い語頭だけで文全体の話者を反転させない() {
        // 原音で全体がイチローと確認済み。「自」の1.26秒のうちBの検出は0.64秒。
        let texts = ["自", "己", "肯", "定", "で", "す", "よ", "。"]
        let times = [107.46, 108.72, 108.90, 109.20, 109.38, 109.56, 109.62, 109.74, 109.86]
        let tokens = texts.enumerated().map {
            TimedToken(text: $0.element, phraseId: 545, start: times[$0.offset], end: times[$0.offset + 1])
        }
        let segments: [SpeakerSegment] = [
            .init(speaker: 2, start: 106.64, end: 107.12),
            .init(speaker: 1, start: 107.76, end: 108.40),
            .init(speaker: 2, start: 108.40, end: 109.76),
            .init(speaker: 0, start: 109.92, end: 110.56),
        ]
        #expect(Aligner.speakers(for: tokens, segments: segments) == Array(repeating: 2, count: tokens.count))
        #expect(Aligner.speakers(for: tokens, segments: segments, frozen: [1, 1]).prefix(2) == [1, 1])
        let duplicated = segments + [segments[1]]
        let weights = SpeechTail.evidenceWeights(tokens: tokens, speakers: Array(repeating: 1, count: tokens.count), segments: duplicated)
        #expect(abs(weights[0] - 0.64) < 0.000001)
    }

    @Test func 句点のない本当ですかを後続の長い発話に吸収しない() {
        // 原音で質問者と確認済み。Appleは質問の末尾に疑問符を付けていなかった。
        let texts = ["あ", "、", "本", "当", "で", "す", "か", "なくて目にしました。"]
        let times = [82.20, 82.32, 82.50, 82.62, 82.80, 82.98, 83.04, 83.10, 85.56]
        let tokens = texts.enumerated().map {
            TimedToken(text: $0.element, phraseId: 1, start: times[$0.offset], end: times[$0.offset + 1])
        }
        let raw: [Int?] = [1, 1, 1, 1, 1, 1, 1, 2]
        #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: raw) == raw)
    }

    @Test func なりますの語尾だけを隣の話者へ返さない() {
        let texts = ["気持ち悪い", "な", "ん", "か", "こ", "う", "い", "う", "感", "じ", "に", "な", "り", "ま", "す", "。"]
        let times = [95.88, 97.20, 97.56, 97.62, 97.74, 97.86, 97.98, 98.04, 98.10, 98.22, 98.28, 98.34, 98.46, 98.52, 98.64, 98.70, 98.82]
        let tokens = texts.enumerated().map {
            TimedToken(text: $0.element, phraseId: 1, start: times[$0.offset], end: times[$0.offset + 1])
        }
        let raw: [Int?] = [1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1]
        let result = Aligner.smoothSpeakers(tokens: tokens, speakers: raw)
        #expect(Aligner.utterances(tokens: tokens, speakers: result).map(\.text)
                == ["気持ち悪い", "なんかこういう感じになります。"])
    }

    @Test func 異なる文と空白を越えて丁寧語尾を連結しない() {
        for text in ["言葉。です", "言葉 です"] {
            let tokens = text.enumerated().map { TimedToken(text: String($0.element), phraseId: 1, start: Double($0.offset), end: Double($0.offset + 1)) }
            let words = WordBoundaries(tokens: tokens).tokenRanges.map { tokens[$0].map(\.text).joined() }
            #expect(words == ["言葉", "です"])
        }
    }
}
