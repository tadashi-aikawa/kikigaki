import Testing

@testable import KikigakiCore

/// 連続するトークンを等間隔で作る補助。`phrase` は phraseId、`at` は開始秒、1トークン `step` 秒
private func tokens(_ texts: [String], phrase: Int = 1, at start: Double = 0, step: Double = 0.2) -> [TimedToken] {
    texts.enumerated().map { i, t in
        TimedToken(text: t, phraseId: phrase, start: start + Double(i) * step, end: start + Double(i + 1) * step)
    }
}

@Suite struct AlignerArgmaxTests {
    @Test func 同点は番号の小さい話者に倒す() {
        #expect(Aligner.argmax([2: 1.0, 0: 1.0, 1: 1.0]) == 0)
        #expect(Aligner.argmax([3: 1.0, 1: 1.0]) == 1)
    }

    @Test func 重み最大の話者を返す() {
        #expect(Aligner.argmax([0: 0.5, 1: 2.0, 2: 1.0]) == 1)
        #expect(Aligner.argmax([:]) == nil)
    }
}

@Suite struct AlignerSpeakerAtTests {
    @Test func 窓との重なりが最大の話者を採る() {
        let segments = [
            SpeakerSegment(speaker: 0, start: 0, end: 10),
            SpeakerSegment(speaker: 1, start: 4.9, end: 5.2),  // 細切れの区間
        ]
        #expect(Aligner.speaker(at: 5.0, segments: segments) == 0)
    }

    @Test func どの区間にも当たらなければnil() {
        let segments = [SpeakerSegment(speaker: 0, start: 0, end: 1)]
        #expect(Aligner.speaker(at: 5.0, segments: segments) == nil)
    }
}

@Suite struct AlignerPhraseRangesTests {
    @Test func フレーズidの変化と無音と句点で切る() {
        var toks = tokens(["あ", "い", "う"], phrase: 1)
        toks += tokens(["え", "お。", "か"], phrase: 2, at: 0.6)
        toks += tokens(["き"], phrase: 2, at: 2.0)  // 0.35秒以上の無音
        let ranges = Aligner.phraseRanges(toks)
        #expect(ranges == [0..<3, 3..<5, 5..<6, 6..<7])
    }

    @Test func 語の途中で取り残された短い1トークンは次のフレーズへ寄せる() {
        var toks = tokens(["ま"], phrase: 1)
        toks += tokens(["あ", "結局"], phrase: 2, at: 0.25)  // 無音 0.05秒
        #expect(Aligner.phraseRanges(toks) == [0..<3])
    }

    @Test func 空のトークン列は空() {
        #expect(Aligner.phraseRanges([]) == [])
    }

    @Test func 句点で終わる短いトークンは次のフレーズへ寄せない() {
        var toks = tokens(["はい。"], phrase: 1)
        toks += tokens(["そ", "れ", "で"], phrase: 1, at: 0.25)  // 無音 0.05秒だが文末
        #expect(Aligner.phraseRanges(toks) == [0..<1, 1..<4])
    }
}

@Suite struct AlignerSentenceBoundaryTests {
    @Test func 句点直後の別話者の短い返事は塗り替えられない() {
        // 話者A「はい。」(0.3秒)のすぐ後に話者Bが長く話す
        var toks = tokens(["はい。"], phrase: 1, step: 0.3)
        toks += tokens(Array(repeating: "x", count: 10), phrase: 1, at: 0.45)  // 無音 0.15秒
        let segments = [
            SpeakerSegment(speaker: 0, start: 0, end: 0.3),
            SpeakerSegment(speaker: 1, start: 0.45, end: 3.0),
        ]
        let result = Aligner.speakers(for: toks, segments: segments)
        #expect(result[0] == 0)
        #expect(result.dropFirst().allSatisfy { $0 == 1 })
    }
}

@Suite struct AlignerSpeakersTests {
    @Test func フレーズ内の短い別話者は多数派に揃える() {
        let toks = tokens(["い", "や", "本", "当", "に"])  // 0〜1.0秒
        let segments = [
            SpeakerSegment(speaker: 1, start: 0, end: 0.3),  // 「い」だけ話者B
            SpeakerSegment(speaker: 0, start: 0.3, end: 1.0),
        ]
        #expect(Aligner.speakers(for: toks, segments: segments) == [0, 0, 0, 0, 0])
    }

    @Test func 別話者が長く続く塊は独立させる() {
        let toks = tokens(Array(repeating: "x", count: 20))  // 0〜4.0秒
        let segments = [
            SpeakerSegment(speaker: 0, start: 0, end: 2.0),
            SpeakerSegment(speaker: 1, start: 2.0, end: 4.0),  // 2秒 ≥ keepIslandSeconds
        ]
        let result = Aligner.speakers(for: toks, segments: segments)
        #expect(result.prefix(9).allSatisfy { $0 == 0 })
        #expect(result.suffix(9).allSatisfy { $0 == 1 })
    }

    @Test func 凍結済みの先頭は再判定しない() {
        let toks = tokens(["a", "b", "c", "d"])
        let segments = [SpeakerSegment(speaker: 0, start: 0, end: 1)]
        let result = Aligner.speakers(for: toks, segments: segments, frozen: [1, 1])
        #expect(result == [1, 1, 0, 0])
    }

    @Test func 同じ入力なら何度呼んでも同じ結果() {
        let toks = tokens(["a", "b", "c", "d"])
        let segments = [
            SpeakerSegment(speaker: 2, start: 0, end: 0.4),
            SpeakerSegment(speaker: 1, start: 0.4, end: 0.8),
        ]
        let first = Aligner.speakers(for: toks, segments: segments)
        for _ in 0..<5 {
            #expect(Aligner.speakers(for: toks, segments: segments) == first)
        }
    }
}

@Suite struct AlignerUtterancesTests {
    @Test func 同じ話者は繋げ話者が変われば行を分ける() {
        let toks = tokens(["こん", "にちは", "はい"])
        let result = Aligner.utterances(tokens: toks, speakers: [0, 0, 1])
        #expect(result == [
            Utterance(speaker: 0, start: 0, end: 0.4, text: "こんにちは"),
            Utterance(speaker: 1, start: 0.4, end: 0.6000000000000001, text: "はい"),
        ])
    }

    @Test func 同じ話者でも無音が長ければ行を分ける() {
        var toks = tokens(["前"])
        toks += tokens(["後"], at: 2.0)
        let result = Aligner.utterances(tokens: toks, speakers: [0, 0])
        #expect(result.count == 2)
        #expect(result.map(\.text) == ["前", "後"])
    }

    @Test func 前後の空白を落とす() {
        let toks = tokens([" a", "b "])
        #expect(Aligner.utterances(tokens: toks, speakers: [nil, nil]).map(\.text) == ["ab"])
    }
}
