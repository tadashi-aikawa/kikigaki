import Foundation
import Testing

@testable import KikigakiCore

@Suite struct TranscriptMergeTests {
    private func token(_ text: String, _ start: Double, _ end: Double, phrase: Int = 1) -> TimedToken {
        TimedToken(text: text, phraseId: phrase, start: start, end: end)
    }

    @Test func 境界をまたぐ速報を除き同時刻からの速報を残す() {
        let accurate = [token("のラグなんで", 0, 2), token("高精度の暫定", 2, 4)]
        let fast = [token("ならなんで", 0, 1.9), token("重なり", 1.9, 2.1),
                    token("次の確定", 2, 3), token("次の暫定", 3, 4)]
        let result = TranscriptMerge.combine(accurate: accurate, accurateFinalCount: 1, fast: fast, fastFinalCount: 3)
        #expect(result.tokens.map(\.text) == ["のラグなんで", "次の確定", "次の暫定"])
        #expect(result.finalCount == 2)
        #expect(result.accurateFinalCount == 1)
        #expect(result.tokens.first == accurate.first)
    }

    @Test func 高精度が空なら速報の確定と暫定をすべて表示する() {
        let fast = [token("速報", 0, 1), token("暫定", 1, 2)]
        let result = TranscriptMerge.combine(accurate: [], accurateFinalCount: 0, fast: fast, fastFinalCount: 1)
        #expect(result.tokens.map(\.text) == ["速報", "暫定"])
        #expect(result.finalCount == 1)
        #expect(result.accurateFinalCount == 0)
    }

    @Test func 高精度が追い越せば速報は残らない() {
        let accurate = [token("出てこないよね", 0, 3)]
        let result = TranscriptMerge.combine(accurate: accurate, accurateFinalCount: 1,
                                             fast: [token("出てこないとね", 0, 2.9)], fastFinalCount: 1)
        #expect(result.tokens == accurate)
        #expect(result.finalCount == 1 && result.accurateFinalCount == 1)
    }

    @Test func 空配列と範囲外の確定数を安全に扱う() {
        let empty = TranscriptMerge.combine(accurate: [], accurateFinalCount: 8, fast: [], fastFinalCount: -1)
        #expect(empty.tokens.isEmpty && empty.finalCount == 0 && empty.accurateFinalCount == 0)
        let result = TranscriptMerge.combine(accurate: [token("暫定", 0, 1)], accurateFinalCount: -1,
                                             fast: [token("速報", 0, 1)], fastFinalCount: 8)
        #expect(result.tokens.map(\.text) == ["速報"])
        #expect(result.finalCount == 1 && result.accurateFinalCount == 0)
    }

    @Test func フレーズはエンジン間で衝突せず同じ速報フレーズは同じIDになる() {
        let result = TranscriptMerge.combine(accurate: [token("高精度", 0, 1, phrase: 1_000_001)], accurateFinalCount: 1,
            fast: [token("速報の", 1, 2), token("続き", 2, 3), token("別", 3, 4, phrase: 2)], fastFinalCount: 3)
        #expect(result.tokens[0].phraseId != result.tokens[1].phraseId)
        #expect(result.tokens[1].phraseId == result.tokens[2].phraseId)
        #expect(result.tokens[2].phraseId != result.tokens[3].phraseId)
    }

    @Test func 高精度が長く遅れても速報を凍結せず訂正後の話者を再判定できる() {
        let accurate = [token("確定。", 0, 1)]
        let first = TranscriptMerge.combine(accurate: accurate, accurateFinalCount: 1,
            fast: [token("粗い", 1, 2), token("速報。", 2, 3)], fastFinalCount: 2)
        let frozen = SpeakerFreeze.advance(frozen: [], speakers: [0, 1, 1], tokens: first.tokens,
                                          elapsed: 100, finalCount: first.accurateFinalCount)
        #expect(frozen == [0])
        let corrected = TranscriptMerge.combine(accurate: accurate + [token("正確な文字。", 1, 3, phrase: 2)],
            accurateFinalCount: 2, fast: [token("粗い", 1, 2), token("速報。", 2, 3)], fastFinalCount: 2)
        let labels = Aligner.speakers(for: corrected.tokens,
            segments: [.init(speaker: 2, start: 1, end: 3)], frozen: frozen)
        #expect(labels == [0, 2])
        let next = SpeakerFreeze.advance(frozen: frozen, speakers: labels, tokens: corrected.tokens,
                                        elapsed: 100, finalCount: corrected.accurateFinalCount)
        #expect(next == [0, 2])
    }

    @Test(arguments: [false, true]) func 速報が通常行とAIに出て高精度へ差し替わる(diarization: Bool) throws {
        let first = TranscriptMerge.combine(accurate: [], accurateFinalCount: 0,
            fast: [token("始めはちょっと", 0, 1)], fastFinalCount: 1)
        let live = LiveTranscript(tokens: first.tokens, speakers: [0], finalCount: first.finalCount,
                                  diarizationEnabled: diarization)
        #expect(live.utterances.map(\.text) == ["始めはちょっと"])
        #expect(live.tentativeText == nil)
        var names = SpeakerNames()
        names.diarizationEnabled = diarization
        let capture = try AICapture(tokens: first.tokens, speakers: [0], finalCount: first.finalCount,
            processedUntil: 2, cutoff: 2, names: names, timeline: .init(startedAt: Date()))
        #expect(capture.lines.joined().contains("始めはちょっと"))
        let corrected = TranscriptMerge.combine(accurate: [token("初めはちょっと", 0, 1)], accurateFinalCount: 1,
            fast: first.tokens, fastFinalCount: 1)
        let final = LiveTranscript(tokens: corrected.tokens, speakers: [0], finalCount: corrected.finalCount,
                                   diarizationEnabled: diarization)
        #expect(final.utterances.map(\.text) == ["初めはちょっと"])
    }
}
