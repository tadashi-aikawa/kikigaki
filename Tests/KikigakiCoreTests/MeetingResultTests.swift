import Testing

@testable import KikigakiCore

@Suite struct MeetingResultTests {
    // 2026-09-05_1412.wav の replay で観測した74.58〜76.20秒。相槌の直後に本文が続く1フレーズ
    private let tokens: [TimedToken] = [
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
    // 相槌の位置だけ別話者。窓判定は別話者に振れるが、フレーズの多数決では吸収される長さ
    private let segments = [
        SpeakerSegment(speaker: 0, start: 70.00, end: 74.80),
        SpeakerSegment(speaker: 1, start: 74.80, end: 75.35),
        SpeakerSegment(speaker: 0, start: 75.35, end: 80.00),
    ]

    @Test func 省略が無効なら発話行だけを返す() {
        let result = MeetingResult.make(tokens: tokens, segments: segments, dropRepeatedBackchannels: false)
        #expect(result.speakers == Array(repeating: 0, count: tokens.count))
        #expect(result.utterances.map(\.text) == ["うんうん先週も言ってました。"])
        #expect(result.processed == nil)
        #expect(result.candidates.isEmpty)
    }

    @Test func 省略が有効なら候補と省略後の行も返す() {
        let result = MeetingResult.make(tokens: tokens, segments: segments, dropRepeatedBackchannels: true)
        #expect(result.candidates == [0..<4])
        // 省略前の行は無効時と同じものを残す(`.raw.md` と、原文が保存できないときの `.md` に使う)
        #expect(result.utterances.map(\.text) == ["うんうん先週も言ってました。"])
        #expect(result.processed?.map(\.text) == ["先週も言ってました。"])
        #expect(result.processed?.first?.start == 75.06)
    }

    @Test func 統合後は同じ人の相槌を消さず解除すると原判定から再計算する() {
        let mapping = SpeakerMapping(overrides: [1: 0])
        let merged = MeetingResult.make(tokens: tokens, segments: segments, dropRepeatedBackchannels: true, mapping: mapping)
        #expect(merged.candidates.isEmpty)
        #expect(merged.processed?.map(\.text) == ["うんうん先週も言ってました。"])
        let restored = MeetingResult.make(tokens: tokens, segments: segments, dropRepeatedBackchannels: true)
        #expect(restored.candidates == [0..<4])
    }

    @Test func 発話がなければどちらも空() {
        for drop in [false, true] {
            let result = MeetingResult.make(tokens: [], segments: [], dropRepeatedBackchannels: drop)
            #expect(result.speakers.isEmpty)
            #expect(result.utterances.isEmpty)
            #expect(result.candidates.isEmpty)
            #expect(result.processed?.isEmpty ?? true)
        }
    }
}

@Suite struct DiagnosticsTests {
    private let tokens: [TimedToken] = [
        .init(text: "う", phraseId: 3, start: 1.0, end: 1.2),
        .init(text: "ん", phraseId: 3, start: 1.2, end: 1.4),
    ]

    @Test func 環境変数がなければ調査用の出力はしない() {
        let off = Diagnostics(environment: [:])
        #expect(off.liveLines([], names: SpeakerNames()).isEmpty)
        #expect(off.liveTraceLines([], names: SpeakerNames(), elapsed: 0).isEmpty)
        #expect(off.phraseLines(tokens: tokens, segments: [], speakers: [nil, nil]).isEmpty)
    }

    @Test func 省略候補は環境変数によらず出す() {
        let lines = Diagnostics(environment: [:]).backchannelLines(tokens: tokens, candidates: [0..<2])
        #expect(lines == ["[backchannel] 1.00-1.40 うん"])
    }

    @Test func フレーズ出力は区間と生の判定から多数決後への変化を並べる() {
        let on = Diagnostics(environment: ["KIKIGAKI_DEBUG_PHRASES": "1"])
        let segments = [SpeakerSegment(speaker: 1, start: 1.0, end: 1.4)]
        let lines = on.phraseLines(tokens: tokens, segments: segments, speakers: [0, nil])
        #expect(lines == [
            "[segment] 1 1.000-1.400",
            "[phrase id=3] う[1→0 1.00-1.20] ん[1→? 1.20-1.40]",
        ])
    }

    @Test func 停止直前の録音中表示は経過時刻で並べる() {
        let on = Diagnostics(environment: ["KIKIGAKI_DEBUG_LIVE": "1", "KIKIGAKI_DEBUG_LIVE_TRACE": "1"])
        let utterances = [Utterance(speaker: 0, start: 61, end: 62, text: "はい")]
        #expect(on.liveLines(utterances, names: SpeakerNames()) == ["[live]\n[01:01] 話者A: はい"])
        #expect(on.liveTraceLines(utterances, names: SpeakerNames(), elapsed: 62.5)
            == ["[live at=62.50]\n[01:01] 話者A: はい"])
    }
}
