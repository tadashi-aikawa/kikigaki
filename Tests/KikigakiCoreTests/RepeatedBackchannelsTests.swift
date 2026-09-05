import Testing
@testable import KikigakiCore

@Suite struct RepeatedBackchannelsTests {
    // 前セッションの 2026-09-05_1412.wav replay、phrases.log の74.58〜76.20秒。
    // rawは窓判定の観測値であり、人手で正解付けした話者ラベルではない。
    private let observed: [TimedToken] = [
        .init(text: "う", phraseId: 501, start: 74.58, end: 74.76),
        .init(text: "ん", phraseId: 501, start: 74.76, end: 74.88),
        .init(text: "う", phraseId: 501, start: 74.88, end: 75.00),
        .init(text: "ん", phraseId: 501, start: 75.00, end: 75.06),
        .init(text: "先", phraseId: 501, start: 75.06, end: 75.42),
        .init(text: "週", phraseId: 501, start: 75.42, end: 75.54),
        .init(text: "も", phraseId: 501, start: 75.54, end: 75.66),
        .init(text: "言", phraseId: 501, start: 75.66, end: 75.78),
        .init(text: "っ", phraseId: 501, start: 75.78, end: 75.84),
        .init(text: "て", phraseId: 501, start: 75.84, end: 75.90),
        .init(text: "ま", phraseId: 501, start: 75.90, end: 75.96),
        .init(text: "し", phraseId: 501, start: 75.96, end: 76.02),
        .init(text: "た", phraseId: 501, start: 76.02, end: 76.08),
        .init(text: "。", phraseId: 501, start: 76.08, end: 76.20),
    ]
    private var raw: [Int?] { [0, 1, 1, 1, 1] + Array(repeating: 0, count: 9) }
    private var aligned: [Int?] { Array(repeating: 0, count: observed.count) }

    @Test func 実録の相槌と同じ塊に入った先を消さない() {
        let ranges = RepeatedBackchannels.candidates(tokens: observed, rawSpeakers: raw, speakers: aligned)
        #expect(ranges == [0..<4])
        let result = RepeatedBackchannels.utterances(tokens: observed, speakers: aligned, omitting: ranges)
        #expect(result.map(\.text) == ["先週も言ってました。"])
        #expect(result.first?.start == 75.06)
        #expect(result.first?.end == 76.20)
    }

    @Test func 同じ話者の繰り返しを残す() {
        #expect(RepeatedBackchannels.candidates(tokens: observed, rawSpeakers: aligned, speakers: aligned).isEmpty)
    }

    @Test func 不明話者や時間重みの同点なら残す() {
        var unknown = raw
        unknown[0] = nil
        #expect(RepeatedBackchannels.candidates(tokens: observed, rawSpeakers: unknown, speakers: aligned).isEmpty)
        // 0.18+0.06秒と0.12+0.12秒の同点。浮動小数点の丸めも同点と扱う。
        var tie = raw
        tie[3] = 0
        #expect(RepeatedBackchannels.candidates(tokens: observed, rawSpeakers: tie, speakers: aligned).isEmpty)
    }

    @Test func 窓内同点を省略の根拠にしない() {
        let segments = [SpeakerSegment(speaker: 0, start: 0, end: 1), SpeakerSegment(speaker: 1, start: 1, end: 2)]
        #expect(Aligner.speaker(at: 1, segments: segments) == 0)
        #expect(Aligner.speaker(at: 1, segments: segments, tiesAreUnknown: true) == nil)
    }

    @Test func 本文と一つのトークンなら分割して消さない() {
        let toks = [TimedToken(text: "うんうん先", phraseId: 1, start: 0, end: 0.5),
                    TimedToken(text: "週", phraseId: 1, start: 0.5, end: 1)]
        #expect(RepeatedBackchannels.candidates(tokens: toks, rawSpeakers: [1, 0], speakers: [0, 0]).isEmpty)
    }

    @Test func 長い反復の末尾だけを短い候補として拾わない() {
        let texts = ["うん", "うん", "うん", "うん", "本文"]
        let toks = texts.enumerated().map { TimedToken(text: $0.element, phraseId: 1, start: Double($0.offset) * 0.5, end: Double($0.offset + 1) * 0.5) }
        #expect(RepeatedBackchannels.candidates(tokens: toks, rawSpeakers: [1, 1, 1, 1, 0], speakers: [0, 0, 0, 0, 0]).isEmpty)
    }

    @Test(arguments: ["うん", "うんそう", "はいはい", "うん、うん", "そうそうたる"])
    func 対象外の文字列は残す(_ text: String) {
        let toks = [TimedToken(text: text, phraseId: 1, start: 0, end: 0.5), TimedToken(text: "本文", phraseId: 1, start: 0.5, end: 1)]
        #expect(RepeatedBackchannels.candidates(tokens: toks, rawSpeakers: [1, 0], speakers: [0, 0]).isEmpty)
    }

    @Test func そうそうそうも候補になる() {
        let toks = [TimedToken(text: "そうそうそう", phraseId: 1, start: 0, end: 0.6), TimedToken(text: "本文", phraseId: 1, start: 0.6, end: 1)]
        #expect(RepeatedBackchannels.candidates(tokens: toks, rawSpeakers: [1, 0], speakers: [0, 0]) == [0..<1])
    }

    @Test func 文末や別話者の直前は独立した返事として残す() {
        #expect(RepeatedBackchannels.candidates(tokens: Array(observed.prefix(4)), rawSpeakers: Array(raw.prefix(4)), speakers: Array(aligned.prefix(4))).isEmpty)
        var speakers = aligned
        speakers[4] = 1
        #expect(RepeatedBackchannels.candidates(tokens: observed, rawSpeakers: raw, speakers: speakers).isEmpty)
        var punct = observed
        punct[4].text = "。"
        #expect(RepeatedBackchannels.candidates(tokens: punct, rawSpeakers: raw, speakers: aligned).isEmpty)
    }

    @Test func 無音で分かれた反復は結合しない() {
        let toks = [TimedToken(text: "うん", phraseId: 1, start: 0, end: 0.2), TimedToken(text: "うん", phraseId: 1, start: 1, end: 1.2), TimedToken(text: "本文", phraseId: 1, start: 1.2, end: 2)]
        #expect(RepeatedBackchannels.candidates(tokens: toks, rawSpeakers: [1, 1, 0], speakers: [0, 0, 0]).isEmpty)
    }
}
