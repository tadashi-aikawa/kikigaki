import Testing
@testable import KikigakiCore

@Suite struct PendingSpeakerTests {
    private let tokens: [TimedToken] = [
        .init(text: "前の発言。", phraseId: 0, start: 0, end: 2),
        .init(text: "次の", phraseId: 1, start: 4, end: 5),
        .init(text: "発言。", phraseId: 1, start: 5, end: 6),
        .init(text: "聞き取り中", phraseId: 2, start: 8, end: 9)
    ]

    @Test func 行の一部が未凍結なら確認中とし文字の暫定行は含めない() {
        let live = LiveTranscript(tokens: tokens, speakers: [0, 1, 1, 2], finalCount: 3, frozenCount: 2)
        #expect(live.pendingSpeakerRows == [1])
        #expect(live.utterances.map(\.text) == ["前の発言。", "次の発言。"])
        #expect(live.tentativeText == "聞き取り中")
        let frozen = LiveTranscript(tokens: tokens, speakers: [0, 1, 1, 2], finalCount: 3, frozenCount: 3)
        #expect(frozen.pendingSpeakerRows.isEmpty)
        #expect(frozen.utterances == live.utterances)
    }

    @Test func 手動統合で行がつながっても未凍結を見失わない() {
        let close = [TimedToken(text: "はい", phraseId: 0, start: 0, end: 1),
                     TimedToken(text: "続き", phraseId: 0, start: 1, end: 2)]
        let split = LiveTranscript(tokens: close, speakers: [0, 1], finalCount: 2, frozenCount: 1)
        #expect(split.pendingSpeakerRows == [1])
        let merged = LiveTranscript(tokens: close, speakers: [0, 0], finalCount: 2, frozenCount: 1)
        #expect(merged.pendingSpeakerRows == [0])
    }

    @Test func 長い語頭の凍結保留を時刻だけで確定扱いしない() {
        let long = [TimedToken(text: "あ", phraseId: 0, start: 0, end: 10)]
        let frozen = SpeakerFreeze.advance(frozen: [], speakers: [0], tokens: long, elapsed: 100, finalCount: 1)
        let live = LiveTranscript(tokens: long, speakers: [0], finalCount: 1, frozenCount: frozen.count)
        #expect(live.pendingSpeakerRows == [0])
    }
}
