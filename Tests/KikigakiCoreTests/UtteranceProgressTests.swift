import Testing
@testable import KikigakiCore

@Suite struct UtteranceProgressTests {
    private let tokens: [TimedToken] = [
        .init(text: "前の発言。", phraseId: 0, start: 0, end: 2),
        .init(text: "次の", phraseId: 1, start: 4, end: 5),
        .init(text: "発言。", phraseId: 1, start: 5, end: 6),
        .init(text: "聞き取り中", phraseId: 2, start: 8, end: 9)
    ]

    @Test func 暫定から速報と高精度を経て話者固定で消える() {
        let token = Array(tokens.prefix(1))
        let tentative = LiveTranscript(tokens: token, speakers: [0], finalCount: 0)
            .checkedProgress(accurateFinalCount: 0)
        #expect(tentative.rows.isEmpty)
        #expect(tentative.tentative == .tentative)
        let final = LiveTranscript(tokens: token, speakers: [0], finalCount: 1)
        #expect(final.checkedProgress(accurateFinalCount: 0).rows == [.fastFinal])
        #expect(final.checkedProgress(accurateFinalCount: 1).rows == [.accurateFinal])
        #expect(final.checkedProgress(accurateFinalCount: 1).tentative == nil)
        let fixed = LiveTranscript(tokens: token, speakers: [0], finalCount: 1, frozenCount: 1)
        #expect(fixed.checkedProgress(accurateFinalCount: 1).rows == [nil])
    }

    @Test func 高精度先着では速報段を経由しない() {
        let live = LiveTranscript(tokens: tokens, speakers: [0, 1, 1, 2], finalCount: 3)
        #expect(live.checkedProgress(accurateFinalCount: 3).rows == [.accurateFinal, .accurateFinal])
        #expect(live.checkedProgress(accurateFinalCount: 3).tentative == .tentative)
    }

    @Test func 速報と高精度と凍結の境界は行の最も未確定側へ寄せる() {
        let live = LiveTranscript(tokens: tokens, speakers: [0, 1, 1, 2], finalCount: 3, frozenCount: 2)
        #expect(live.checkedProgress(accurateFinalCount: 2).rows == [nil, .fastFinal])
        #expect(live.checkedProgress(accurateFinalCount: 3).rows == [nil, .accurateFinal])
        #expect(live.pendingSpeakerRows == [1])
        #expect(live.utterances.map(\.text) == ["前の発言。", "次の発言。"])
    }

    @Test func 話者の手動統合で行がつながったら段も統合する() {
        let close = [TimedToken(text: "はい", phraseId: 0, start: 0, end: 1),
                     TimedToken(text: "続き", phraseId: 0, start: 1, end: 2)]
        let split = LiveTranscript(tokens: close, speakers: [0, 1], finalCount: 2, frozenCount: 1)
        let merged = LiveTranscript(tokens: close, speakers: [0, 0], finalCount: 2, frozenCount: 1)
        #expect(split.checkedProgress(accurateFinalCount: 2).rows == [nil, .accurateFinal])
        #expect(merged.checkedProgress(accurateFinalCount: 2).rows == [.accurateFinal])
    }

    @Test func 話者オフは三段で文末と無音の行境界に従い高精度で消える() {
        let live = LiveTranscript(tokens: tokens, speakers: [], finalCount: 3, diarizationEnabled: false)
        let progress = live.checkedProgress(accurateFinalCount: 2)
        #expect(progress.steps == [.tentative, .fastFinal, .accurateFinal])
        #expect(progress.rows == [nil, .fastFinal])
        #expect(progress.tentative == .tentative)
        #expect(live.checkedProgress(accurateFinalCount: 3).rows == [nil, nil])
        #expect(live.pendingSpeakerRows.isEmpty)
    }

    @Test func 話者オフの長い発話境界も表示行と揃う() {
        let long = [TimedToken(text: "長い発言", phraseId: 0, start: 0, end: 31),
                    TimedToken(text: "続き", phraseId: 1, start: 31, end: 32)]
        let live = LiveTranscript(tokens: long, speakers: [], finalCount: 2, diarizationEnabled: false)
        #expect(live.utterances.count == 2)
        #expect(live.checkedProgress(accurateFinalCount: 1).rows == [nil, .fastFinal])
    }

    @Test func 過大な高精度数でも未凍結なら固定にしない() {
        let live = LiveTranscript(tokens: tokens, speakers: [0, 1, 1, 2], finalCount: 3)
        #expect(live.checkedProgress(accurateFinalCount: Int.max).rows == [.accurateFinal, .accurateFinal])
    }

    @Test func 凍結数は正規化して比較する() {
        let zero = LiveTranscript(tokens: tokens, speakers: [0, 1, 1, 2], finalCount: 3)
        let negative = LiveTranscript(tokens: tokens, speakers: [0, 1, 1, 2], finalCount: 3, frozenCount: -1)
        let full = LiveTranscript(tokens: tokens, speakers: [0, 1, 1, 2], finalCount: 3, frozenCount: 3)
        let excessive = LiveTranscript(tokens: tokens, speakers: [0, 1, 1, 2], finalCount: 3, frozenCount: Int.max)
        #expect(zero == negative)
        #expect(full == excessive)
        for live in [zero, negative, full, excessive] { _ = live.checkedProgress(accurateFinalCount: 3) }
    }

    @Test func 不正な境界数で速報を固定扱いせず空入力にも対応する() {
        let live = LiveTranscript(tokens: tokens, speakers: [0, 1, 1, 2], finalCount: 3,
                                  frozenCount: Int.max)
        #expect(live.checkedProgress(accurateFinalCount: -1).rows == [.fastFinal, .fastFinal])
        #expect(live.checkedProgress(accurateFinalCount: 2).rows == [nil, .fastFinal])
        #expect(live.checkedProgress(accurateFinalCount: Int.max).rows == [nil, nil])
        let empty = LiveTranscript(tokens: [], speakers: [], finalCount: Int.max)
            .checkedProgress(accurateFinalCount: Int.max)
        #expect(empty.rows.isEmpty && empty.tentative == nil)
        let negative = LiveTranscript(tokens: tokens, speakers: [], finalCount: -1)
            .checkedProgress(accurateFinalCount: -1)
        #expect(negative.rows.isEmpty && negative.tentative == .tentative)
    }

    @Test func 話者不明も固定でき短い話者列では実在する行だけに段を付ける() {
        let unknown = LiveTranscript(tokens: tokens, speakers: [nil, nil, nil], finalCount: 3,
                                     frozenCount: 3)
        #expect(unknown.checkedProgress(accurateFinalCount: 3).rows.allSatisfy { $0 == nil })
        let short = LiveTranscript(tokens: tokens, speakers: [0], finalCount: 3)
        #expect(short.checkedProgress(accurateFinalCount: 1).rows == [.accurateFinal])
        #expect(short.utterances.count == 1)
    }

    @Test func 固定は停止時の再判定を案内する() {
        let live = LiveTranscript(tokens: [], speakers: [], finalCount: 0)
        #expect(live.checkedProgress(accurateFinalCount: 0).steps == [.tentative, .fastFinal, .accurateFinal, .speakerFixed])
        #expect(UtteranceProgress.Stage.speakerFixed.tooltip == "話者固定。停止時に全体を再判定します")
    }
}

private extension LiveTranscript {
    func checkedProgress(accurateFinalCount: Int, sourceLocation: SourceLocation = #_sourceLocation) -> UtteranceProgress {
        let result = progress(accurateFinalCount: accurateFinalCount)
        #expect(result.rows.count == utterances.count, sourceLocation: sourceLocation)
        return result
    }
}
