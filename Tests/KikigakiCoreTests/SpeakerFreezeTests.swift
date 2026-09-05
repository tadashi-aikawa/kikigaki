import Testing

@testable import KikigakiCore

@Suite struct SpeakerFreezeTests {
    @Test func 後続確定結果が来るまで長い語頭の凍結を待つ() {
        let first = TimedToken(text: "僕", phraseId: 1, start: 185.46, end: 187.20)
        let next = TimedToken(text: "の", phraseId: 2, start: 187.20, end: 188.04)
        #expect(SpeakerFreeze.advance(frozen: [], speakers: [1], tokens: [first], elapsed: 200, finalCount: 1).isEmpty)
        #expect(SpeakerFreeze.advance(frozen: [], speakers: [1, 2], tokens: [first, next], elapsed: 200, finalCount: 1).isEmpty)
        let segments: [SpeakerSegment] = [.init(speaker: 1, start: 185.36, end: 185.84),
                                         .init(speaker: 2, start: 186.96, end: 188.20)]
        let speakers = Aligner.speakers(for: [first, next], segments: segments)
        #expect(SpeakerFreeze.advance(frozen: [], speakers: speakers, tokens: [first, next], elapsed: 200, finalCount: 2).first == 2)
    }

    private let toks = (0..<5).map { i in
        TimedToken(text: "t\(i)", phraseId: 1, start: Double(i), end: Double(i + 1))
    }
    private let judged: [Int?] = [0, 1, 0, 1, 0]

    @Test func 猶予より前に終わるトークンまで凍結する() {
        // elapsed 11 - grace 8 = 3.0 より前に終わるのは end=1,2 の2個(end < 3.0 なので end=3 は含まない)
        let result = SpeakerFreeze.advance(frozen: [], speakers: judged, tokens: toks, elapsed: 11, finalCount: 5)
        #expect(result == [0, 1])
    }

    @Test func 暫定結果のトークンは猶予を過ぎても凍結しない() {
        // 先頭3個だけが確定結果。全部が猶予を過ぎていても確定分までしか凍らない
        let result = SpeakerFreeze.advance(frozen: [], speakers: judged, tokens: toks, elapsed: 100, finalCount: 3)
        #expect(result == [0, 1, 0])
    }

    @Test func 確定が進めば続きが凍る() {
        let first = SpeakerFreeze.advance(frozen: [], speakers: judged, tokens: toks, elapsed: 100, finalCount: 2)
        let second = SpeakerFreeze.advance(frozen: first, speakers: judged, tokens: toks, elapsed: 100, finalCount: 5)
        #expect(first == [0, 1])
        #expect(second == judged)
    }

    @Test func 凍結は縮まない() {
        let result = SpeakerFreeze.advance(frozen: [3, 3, 3], speakers: judged, tokens: toks, elapsed: 0, finalCount: 5)
        #expect(result == [0, 1, 0])
    }

    @Test func トークンが減っても落ちない() {
        let result = SpeakerFreeze.advance(
            frozen: [0, 0, 0, 0, 0, 0, 0], speakers: [1, 1], tokens: Array(toks.prefix(2)), elapsed: 0, finalCount: 9)
        #expect(result == [1, 1])
    }
}
