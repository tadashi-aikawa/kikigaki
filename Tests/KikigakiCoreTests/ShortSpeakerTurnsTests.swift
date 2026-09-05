import Testing
@testable import KikigakiCore

@Suite struct ShortSpeakerTurnsTests {
    // 2026-09-05_1529.wavの再処理ログ。rawは窓判定の観測値で、正解ラベルではない。
    @Test func 実録のはいとすごいねを多数派へ吸収しない() {
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
        let speakers = Aligner.smoothSpeakers(tokens: tokens, speakers: raw)
        #expect(speakers == raw)
        #expect(Aligner.utterances(tokens: tokens, speakers: speakers).map(\.text)
                == ["一応経過報告させていただきますと", "はい", "それから毎日続いてまして", "すごいね。"])
    }

    @Test func 複数語を含むASRトークンの境界は補完しない() {
        let texts = ["11日目じ", "ゃあもう10分の1そ", "うなんですよ。"]
        let times = [187.26, 188.76, 190.20, 190.80]
        let tokens = texts.enumerated().map { TimedToken(text: $0.element, phraseId: 1220, start: times[$0.offset], end: times[$0.offset + 1]) }
        #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: [0, 1, 0]) == [0, 0, 0])
    }

    @Test(arguments: [
        ["読", "みやすい", "し"],
        ["一応", "経過報告", "をさせていただきます"],
        ["続いてまし", "て", "すごいです"],
    ])
    func 語途中と文中の複数語と一文字は従来通り吸収する(_ texts: [String]) {
        let times = [0.0, 2.0, 2.5, 5.0]
        let tokens = texts.enumerated().map { TimedToken(text: $0.element, phraseId: 1, start: times[$0.offset], end: times[$0.offset + 1]) }
        #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: [0, 1, 0]) == [0, 0, 0])
    }

    @Test func 不明話者は語境界でも吸収し凍結済みは変えない() {
        let tokens = [TimedToken(text: "はい", phraseId: 1, start: 0, end: 0.3), TimedToken(text: "続いてます", phraseId: 1, start: 0.3, end: 3)]
        #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: [nil, 0]) == [0, 0])
        #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: [nil, 0], frozenCount: 1) == [nil, 0])
    }

    @Test func 絵文字や句読点を含む前文でもUTF16の境界がずれない() {
        let tokens = [TimedToken(text: "😀続いてまして", phraseId: 1, start: 0, end: 3), TimedToken(text: " すごいね。 ", phraseId: 1, start: 3, end: 3.8)]
        #expect(Aligner.smoothSpeakers(tokens: tokens, speakers: [0, 1]) == [0, 1])
    }
}
