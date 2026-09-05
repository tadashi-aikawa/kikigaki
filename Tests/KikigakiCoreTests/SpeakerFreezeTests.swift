import Testing

@testable import KikigakiCore

@Suite struct SpeakerFreezeTests {
    private let toks = (0..<5).map { i in
        TimedToken(text: "t\(i)", phraseId: 1, start: Double(i), end: Double(i + 1))
    }

    @Test func 猶予より前に終わるトークンまで凍結する() {
        // elapsed 11 - grace 8 = 3.0 より前に終わるのは end=1,2,3 の3個(end < 3.0 なので end=3 は含まない)
        let result = SpeakerFreeze.advance(frozen: [], speakers: [0, 1, 0, 1, 0], tokens: toks, elapsed: 11)
        #expect(result == [0, 1])
    }

    @Test func 凍結は縮まない() {
        let result = SpeakerFreeze.advance(frozen: [3, 3, 3], speakers: [0, 1, 0, 1, 0], tokens: toks, elapsed: 0)
        #expect(result == [0, 1, 0])
    }

    @Test func 全部凍結できる() {
        let result = SpeakerFreeze.advance(frozen: [], speakers: [0, 1, 0, 1, 0], tokens: toks, elapsed: 100)
        #expect(result == [0, 1, 0, 1, 0])
    }

    @Test func トークンが減っても落ちない() {
        let result = SpeakerFreeze.advance(frozen: [0, 0, 0, 0, 0, 0, 0], speakers: [1, 1], tokens: Array(toks.prefix(2)), elapsed: 0)
        #expect(result == [1, 1])
    }
}
