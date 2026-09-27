import Testing
@testable import KikigakiCore

@Suite struct UtteranceConfirmationTests {
    private let tokens: [TimedToken] = [
        .init(text: "前の発言。", phraseId: 0, start: 0, end: 2),
        .init(text: "次の", phraseId: 1, start: 4, end: 5),
        .init(text: "発言。", phraseId: 1, start: 5, end: 6),
        .init(text: "聞き取り中", phraseId: 2, start: 8, end: 9)
    ]

    @Test func 話者オンは高精度の文字と話者固定が揃うまで未確定() {
        let token = Array(tokens.prefix(1))
        let tentative = LiveTranscript(tokens: token, speakers: [0], finalCount: 0)
        #expect(tentative.checkedUnconfirmed(accurateFinalCount: 0).isEmpty)
        #expect(tentative.tentativeText != nil)
        let final = LiveTranscript(tokens: token, speakers: [0], finalCount: 1)
        #expect(final.checkedUnconfirmed(accurateFinalCount: 0) == [0])
        #expect(final.checkedUnconfirmed(accurateFinalCount: 1) == [0])
        let fixed = LiveTranscript(tokens: token, speakers: [0], finalCount: 1, frozenCount: 1)
        #expect(fixed.checkedUnconfirmed(accurateFinalCount: 0) == [0])
        #expect(fixed.checkedUnconfirmed(accurateFinalCount: 1).isEmpty)
    }

    @Test func 行の一部でも未確定なら行全体を未確定にする() {
        let live = LiveTranscript(tokens: tokens, speakers: [0, 1, 1, 2], finalCount: 3, frozenCount: 2)
        #expect(live.checkedUnconfirmed(accurateFinalCount: 2) == [1])
        #expect(live.checkedUnconfirmed(accurateFinalCount: 3) == [1])
        #expect(live.utterances.map(\.text) == ["前の発言。", "次の発言。"])
        let fixed = LiveTranscript(tokens: tokens, speakers: [0, 1, 1, 2], finalCount: 3, frozenCount: 3)
        #expect(fixed.checkedUnconfirmed(accurateFinalCount: 3).isEmpty)
    }

    @Test func 確定した行へ後続の文字が伸びたら再び未確定にする() {
        let close = [TimedToken(text: "はい", phraseId: 0, start: 0, end: 1),
                     TimedToken(text: "続き", phraseId: 0, start: 1, end: 2)]
        let before = LiveTranscript(tokens: Array(close.prefix(1)), speakers: [0], finalCount: 1, frozenCount: 1)
        #expect(before.checkedUnconfirmed(accurateFinalCount: 1).isEmpty)
        let grown = LiveTranscript(tokens: close, speakers: [0, 0], finalCount: 2, frozenCount: 1)
        #expect(grown.utterances.count == 1)
        #expect(grown.checkedUnconfirmed(accurateFinalCount: 1) == [0])
    }

    @Test func 話者の手動統合で行がつながったら未確定も統合する() {
        let close = [TimedToken(text: "はい", phraseId: 0, start: 0, end: 1),
                     TimedToken(text: "続き", phraseId: 0, start: 1, end: 2)]
        let split = LiveTranscript(tokens: close, speakers: [0, 1], finalCount: 2, frozenCount: 1)
        let merged = LiveTranscript(tokens: close, speakers: [0, 0], finalCount: 2, frozenCount: 1)
        #expect(split.checkedUnconfirmed(accurateFinalCount: 2) == [1])
        #expect(merged.checkedUnconfirmed(accurateFinalCount: 2) == [0])
    }

    @Test func 話者オフは高精度の文字だけで確定し凍結を見ない() {
        let live = LiveTranscript(tokens: tokens, speakers: [], finalCount: 3, diarizationEnabled: false)
        #expect(live.checkedUnconfirmed(accurateFinalCount: 2) == [1])
        #expect(live.checkedUnconfirmed(accurateFinalCount: 3).isEmpty)
        #expect(live.tentativeText != nil)
        #expect(live.pendingSpeakerRows.isEmpty)
    }

    @Test func 話者オフの長い発話境界も表示行と揃う() {
        let long = [TimedToken(text: "長い発言", phraseId: 0, start: 0, end: 31),
                    TimedToken(text: "続き", phraseId: 1, start: 31, end: 32)]
        let live = LiveTranscript(tokens: long, speakers: [], finalCount: 2, diarizationEnabled: false)
        #expect(live.utterances.count == 2)
        #expect(live.checkedUnconfirmed(accurateFinalCount: 1) == [1])
    }

    @Test func 過大な高精度数でも未凍結なら確定にしない() {
        let live = LiveTranscript(tokens: tokens, speakers: [0, 1, 1, 2], finalCount: 3)
        #expect(live.checkedUnconfirmed(accurateFinalCount: Int.max) == [0, 1])
    }

    @Test func 不正な境界数で速報を確定扱いせず空入力にも対応する() {
        let live = LiveTranscript(tokens: tokens, speakers: [0, 1, 1, 2], finalCount: 3,
                                  frozenCount: Int.max)
        #expect(live.checkedUnconfirmed(accurateFinalCount: -1) == [0, 1])
        #expect(live.checkedUnconfirmed(accurateFinalCount: 2) == [1])
        #expect(live.checkedUnconfirmed(accurateFinalCount: Int.max).isEmpty)
        let empty = LiveTranscript(tokens: [], speakers: [], finalCount: Int.max)
        #expect(empty.checkedUnconfirmed(accurateFinalCount: Int.max).isEmpty && empty.tentativeText == nil)
        let negative = LiveTranscript(tokens: tokens, speakers: [], finalCount: -1, frozenCount: -1)
        #expect(negative.checkedUnconfirmed(accurateFinalCount: -1).isEmpty && negative.tentativeText != nil)
    }

    @Test func 話者不明も固定済みなら確定し短い話者列では実在する行だけを見る() {
        let unknown = LiveTranscript(tokens: tokens, speakers: [nil, nil, nil], finalCount: 3,
                                     frozenCount: 3)
        #expect(unknown.checkedUnconfirmed(accurateFinalCount: 3).isEmpty)
        let short = LiveTranscript(tokens: tokens, speakers: [0], finalCount: 3)
        #expect(short.checkedUnconfirmed(accurateFinalCount: 1) == [0])
        #expect(short.utterances.count == 1)
    }
}

private extension LiveTranscript {
    func checkedUnconfirmed(accurateFinalCount: Int, sourceLocation: SourceLocation = #_sourceLocation) -> Set<Int> {
        let result = unconfirmedRows(accurateFinalCount: accurateFinalCount)
        #expect(result.allSatisfy { utterances.indices.contains($0) }, sourceLocation: sourceLocation)
        return result
    }
}
