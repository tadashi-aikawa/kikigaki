import Testing
@testable import KikigakiCore

@Suite struct BackchannelPresetTests {
    private func tokens(_ middle: String, duration: Double = 0.4) -> [TimedToken] {
        [TimedToken(text: "説明を続けます、", phraseId: 1, start: 0, end: 3),
         TimedToken(text: middle, phraseId: 1, start: 3, end: 3 + duration),
         TimedToken(text: "次の資料を見てください", phraseId: 1, start: 3 + duration, end: 7 + duration)]
    }

    @Test(arguments: ["はい", "うん", "はいはい", "うんうん", "ええ", "なるほど", "確かに", "そうですね",
                      "そうです", "そうですよね", "なるほどね", "わかりました", "分かりました", "承知しました",
                      "  はい、 ", "　うん！　"])
    func 前後が同じ主話者でも定番の相槌は保持する(_ word: String) {
        #expect(Aligner.smoothSpeakers(tokens: tokens(word), speakers: [0, 1, 0]) == [0, 1, 0])
    }

    @Test(arguments: ["代表", "資料", "担当", "はいの意味"])
    func 前後が同じ主話者の一般語とプリセットの部分一致は吸収する(_ word: String) {
        #expect(Aligner.smoothSpeakers(tokens: tokens(word), speakers: [0, 1, 0]) == [0, 0, 0])
    }

    @Test func 全プリセットを重複発話でも保持する() {
        let segments = [SpeakerSegment(speaker: 0, start: 0, end: 8),
                        SpeakerSegment(speaker: 1, start: 3, end: 3.4)]
        for word in WordBoundaries.backchannelWords.sorted() {
            #expect(Aligner.smoothSpeakers(tokens: tokens(word), speakers: [0, 1, 0], segments: segments) == [0, 1, 0],
                    "相槌が吸収された: \(word)")
            #expect(Aligner.smoothSpeakers(tokens: tokens(word), speakers: [0, 1, 0]) == [0, 1, 0],
                    "前後の連続性によって相槌が吸収された: \(word)")
        }
    }

    @Test func 凍結済みの一般語を後から吸収しない() {
        #expect(Aligner.smoothSpeakers(tokens: tokens("代表"), speakers: [0, 1, 0], frozenCount: 2) == [0, 1, 0])
    }

    @Test func 凍結境界をまたぐ一般語の後半だけを吸収しない() {
        let values = [TimedToken(text: "説明を続けます", phraseId: 1, start: 0, end: 3),
                      TimedToken(text: "代", phraseId: 1, start: 3, end: 3.2),
                      TimedToken(text: "表", phraseId: 1, start: 3.2, end: 3.4),
                      TimedToken(text: "の話です", phraseId: 1, start: 3.4, end: 7)]
        #expect(Aligner.smoothSpeakers(tokens: values, speakers: [0, 1, 1, 0], frozenCount: 2) == [0, 1, 1, 0])
    }

    @Test func 句点だけの多数派を後続の発話と見なさない() {
        let values = [TimedToken(text: "説明します、", phraseId: 1, start: 0, end: 3),
                      TimedToken(text: "反対", phraseId: 1, start: 3, end: 3.4),
                      TimedToken(text: "。", phraseId: 1, start: 3.4, end: 3.5)]
        #expect(Aligner.smoothSpeakers(tokens: values, speakers: [0, 1, 0]) == [0, 1, 1])
    }

    @Test func プリセットに一致しても語の断片は保護しない() {
        let values = [TimedToken(text: "今日は", phraseId: 1, start: 0, end: 3),
                      TimedToken(text: "そう", phraseId: 1, start: 3, end: 3.4),
                      TimedToken(text: "めんです", phraseId: 1, start: 3.4, end: 7)]
        let words = WordBoundaries(tokens: values)
        #expect(!words.isBackchannel(1..<2))
    }

    @Test(arguments: [1.49, 1.5, 1.6])
    func 長い発話交代は一般語でも維持する(_ duration: Double) {
        #expect(Aligner.smoothSpeakers(tokens: tokens("代表", duration: duration), speakers: [0, 1, 0])
                == [0, duration < 1.5 ? 0 : 1, 0])
    }

    @Test func 前後が第三話者なら一般語を離れた多数派に寄せない() {
        var values = tokens("代表")
        values[0].start = -5
        #expect(Aligner.smoothSpeakers(tokens: values, speakers: [0, 1, 2]) == [0, 1, 2])
    }

    @Test func 直前の不明区間を吸収した結果で次の一般語まで連鎖吸収しない() {
        let values = [TimedToken(text: "説明を続けます", phraseId: 1, start: 0, end: 3),
                      TimedToken(text: "で", phraseId: 1, start: 3, end: 3.1),
                      TimedToken(text: "代表", phraseId: 1, start: 3.1, end: 3.5),
                      TimedToken(text: "の話です", phraseId: 1, start: 3.5, end: 7)]
        #expect(Aligner.smoothSpeakers(tokens: values, speakers: [0, nil, 1, 0]) == [0, 0, 1, 0])
    }

    @Test func 無音で分かれた返答や文末の返答は保持する() {
        var separate = tokens("代表")
        separate[1].start += 0.4
        separate[1].end += 0.4
        separate[2].start += 0.8
        separate[2].end += 0.8
        #expect(Aligner.smoothSpeakers(tokens: separate, speakers: [0, 1, 0]) == [0, 1, 0])
        #expect(Aligner.smoothSpeakers(tokens: tokens("すごいね。"), speakers: [0, 1, 0]) == [0, 1, 0])
    }
}
