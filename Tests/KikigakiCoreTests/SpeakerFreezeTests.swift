import Testing

@testable import KikigakiCore

@Suite struct SpeakerFreezeTests {
    @Test func モデル未判定のトークンを固定しない() {
        // 条件5のため、間を空けた次の文も確定済みにする
        let tokens = [TimedToken(text: "はい。", phraseId: 0, start: 0, end: 0.1),
                      TimedToken(text: "次", phraseId: 1, start: 0.6, end: 0.8)]
        let waiting = SpeakerFreeze.advanceByPhrase(frozen: [], speakers: [nil, nil], tokens: tokens, accurateFinalCount: 2,
                                                    judgedUntil: 0)
        #expect(waiting.isEmpty)
        let judged = SpeakerFreeze.advanceByPhrase(frozen: waiting, speakers: [1, 1], tokens: tokens, accurateFinalCount: 2,
                                                   judgedUntil: 27.2)
        #expect(judged == [1])
        // 判定済みの範囲で区間が無ければ不明のまま固定する
        let silent = SpeakerFreeze.advanceByPhrase(frozen: [], speakers: [nil, nil], tokens: tokens, accurateFinalCount: 2,
                                                   judgedUntil: 27.2)
        #expect(silent.count == 1)
    }

    @Test func 後続確定結果が来るまで長い語頭の凍結を待つ() {
        let first = TimedToken(text: "僕", phraseId: 1, start: 185.46, end: 187.20)
        // 後続が長い1文字だと、それ自体の後続も待つ。ここでは短くする
        let next = TimedToken(text: "の。", phraseId: 1, start: 187.20, end: 187.50)
        #expect(SpeakerFreeze.advanceByPhrase(frozen: [], speakers: [1], tokens: [first], accurateFinalCount: 1,
                                              judgedUntil: 220).isEmpty)
        #expect(SpeakerFreeze.advanceByPhrase(frozen: [], speakers: [1, 2], tokens: [first, next], accurateFinalCount: 1,
                                              judgedUntil: 220).isEmpty)
        let segments: [SpeakerSegment] = [.init(speaker: 1, start: 185.36, end: 185.84),
                                         .init(speaker: 2, start: 186.96, end: 188.20)]
        // 条件5: 後続の文との間の有無を、次のトークンの確定で確かめる。ここでは間を空ける
        let after = TimedToken(text: "次", phraseId: 2, start: 188.0, end: 188.3)
        let speakers = Aligner.speakers(for: [first, next, after], segments: segments)
        #expect(SpeakerFreeze.advanceByPhrase(frozen: [], speakers: speakers, tokens: [first, next, after], accurateFinalCount: 3,
                                              judgedUntil: 220).first == 2)
    }

    /// 1秒ずつの5トークン。「t1。」「t3。」で3フレーズに分かれる
    /// 文と文の間は0.5秒空ける。間が無いと条件5で後続の文の確定も待つ
    private let toks = [("t0", 0.0), ("t1。", 1), ("t2", 2.5), ("t3。", 3.5), ("t4", 5)].map { text, start in
        TimedToken(text: text, phraseId: 1, start: start, end: start + 1)
    }
    private let judged: [Int?] = [0, 1, 0, 1, 0]

    @Test func 暫定結果のトークンを含むフレーズは凍結しない() {
        // 先頭3個だけが確定結果。2番目のフレーズは途中までしか確定していない
        let result = SpeakerFreeze.advanceByPhrase(frozen: [], speakers: judged, tokens: toks, accurateFinalCount: 3,
                                                   judgedUntil: 100)
        #expect(result == [0, 1])
    }

    @Test func 確定が進めば続きが凍る() {
        // 各文の後の文頭まで確定すると、その文が凍る(条件5)
        let first = SpeakerFreeze.advanceByPhrase(frozen: [], speakers: judged, tokens: toks, accurateFinalCount: 3,
                                                  judgedUntil: 100)
        let second = SpeakerFreeze.advanceByPhrase(frozen: first, speakers: judged, tokens: toks, accurateFinalCount: 5,
                                                   judgedUntil: 100)
        #expect(first == [0, 1])
        #expect(second == [0, 1, 0, 1])
    }

    @Test func 凍結は縮まない() {
        let result = SpeakerFreeze.advanceByPhrase(frozen: [3, 3, 3], speakers: judged, tokens: toks, accurateFinalCount: 5,
                                                   judgedUntil: 0)
        #expect(result == [0, 1, 0])
    }

    @Test func トークンが減っても落ちない() {
        let result = SpeakerFreeze.advanceByPhrase(
            frozen: [0, 0, 0, 0, 0, 0, 0], speakers: [1, 1], tokens: Array(toks.prefix(2)), accurateFinalCount: 9, judgedUntil: 0)
        #expect(result == [1, 1])
    }
}
