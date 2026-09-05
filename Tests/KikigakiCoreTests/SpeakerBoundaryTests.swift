import Testing
@testable import KikigakiCore

@Suite struct SpeakerBoundaryTests {
    @Test func 実録のじゃあを戻しそうの語頭を次の話者へ返す() {
        // 2026-09-05_1529.wav の観測トークンと窓判定。長い同話者部分だけ集約。
        let text = [" 11日目", "じ", "ゃ", "あ", "も", "う", " 10", "分", "の", " 1", "そ", "う", "なんですよ。"]
        let times = [187.26, 188.34, 188.76, 188.82, 188.94, 189.06, 189.18, 189.36, 189.48, 189.54, 189.66, 190.20, 190.26, 190.80]
        let tokens = text.enumerated().map { TimedToken(text: $0.element, phraseId: 1220, start: times[$0.offset], end: times[$0.offset + 1]) }
        let raw: [Int?] = [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0]
        let result = Aligner.smoothSpeakers(tokens: tokens, speakers: raw)
        #expect(result == [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0])
        #expect(Aligner.utterances(tokens: tokens, speakers: result).map(\.text) == ["11日目", "じゃあもう 10分の 1", "そうなんですよ。"])
        // 次が第三話者なら、その語頭を離れた多数派へ戻さない。
        var threeSpeakers = raw
        threeSpeakers[11] = 2
        threeSpeakers[12] = 2
        var threeTokens = tokens
        // Aを多数派、Cを従来から独立する長い発話にして、新しい端補正だけを検査する。
        threeTokens[0].start -= 5
        threeTokens[12].end += 2
        let three = Aligner.smoothSpeakers(tokens: threeTokens, speakers: threeSpeakers)
        #expect(three[10] == 1)
        #expect(three[11] == 2)
        #expect(three[12] == 2)
        var longer = tokens
        longer[10].end += 0.4
        for i in 11..<longer.count { longer[i].start += 0.4; longer[i].end += 0.4 }
        // 元から1.5秒以上の島の端は、この短島救済では削らない。
        #expect(Aligner.smoothSpeakers(tokens: longer, speakers: raw)[10] == 1)
    }

    @Test func 長い語頭を補正してもフレーズの多数派を逆転させない() {
        let text = ["す", "ご", "い", "ですよ"]
        let times = [0.0, 0.6, 1.0, 1.4, 1.8]
        let tokens = text.enumerated().map { TimedToken(text: $0.element, phraseId: 1, start: times[$0.offset], end: times[$0.offset + 1]) }
        #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: [0, 1, 1, 0]) == [1, 1, 1, 0])
    }

    @Test func 同点と不明と三話者の過半数なしは語内を統一しない() {
        let two = [TimedToken(text: "そ", phraseId: 1, start: 0, end: 0.54), TimedToken(text: "う", phraseId: 1, start: 0.54, end: 0.60)]
        #expect(Aligner.smoothSpeakers(tokens: two, speakers: [1, 0], keepIslandSeconds: 0) == [1, 0])
        let three = ["す", "ご", "い"].enumerated().map { TimedToken(text: $0.element, phraseId: 1, start: Double($0.offset), end: Double($0.offset + 1)) }
        #expect(Aligner.smoothSpeakers(tokens: three, speakers: [nil, 1, 1], keepIslandSeconds: 0) == [nil, 1, 1])
        #expect(Aligner.smoothSpeakers(tokens: three, speakers: [0, 1, 2], keepIslandSeconds: 0) == [0, 1, 2])
        #expect(Aligner.smoothSpeakers(tokens: three, speakers: [0, 1, 1], frozenCount: 1, keepIslandSeconds: 0) == [0, 1, 1])
    }

    @Test func 一つのASRトークンに複数語がある場合は分割しない() {
        let tokens = [TimedToken(text: "11日目じ", phraseId: 1, start: 0, end: 2), TimedToken(text: "ゃあ", phraseId: 1, start: 2, end: 2.3)]
        #expect(WordBoundaries(tokens: tokens).tokenRanges.isEmpty)
    }

    @Test func 区間内部の語補正だけで文中の複数語を保護しない() {
        let texts = ["一応", "経過", "す", "ご", "い", "報告", "をさせていただきます"]
        let times = [0.0, 3.0, 3.2, 3.3, 3.4, 3.5, 3.7, 7.0]
        let tokens = texts.enumerated().map { TimedToken(text: $0.element, phraseId: 1, start: times[$0.offset], end: times[$0.offset + 1]) }
        #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: [0, 1, 0, 1, 1, 1, 0]) == Array(repeating: 0, count: texts.count))
    }
}
