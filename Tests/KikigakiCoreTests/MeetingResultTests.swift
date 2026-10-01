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
    // 相槌の位置だけ別話者。吸収をせず、別話者の行に残す。
    private let segments = [
        SpeakerSegment(speaker: 0, start: 70.00, end: 74.80),
        SpeakerSegment(speaker: 1, start: 74.80, end: 75.35),
        SpeakerSegment(speaker: 0, start: 75.35, end: 80.00),
    ]

    @Test func 最終判定でも繰り返しの相槌と本文を全て残す() {
        let result = MeetingResult.make(tokens: tokens, segments: segments)
        #expect(result.speakers == Aligner.speakers(for: tokens, segments: segments))
        #expect(result.utterances.map(\.text).joined() == "うんうん先週も言ってました。")
        #expect(result.utterances.contains { $0.speaker == 1 })
    }

    @Test func 統合と解除で原判定から再計算し全文を保つ() {
        let merged = MeetingResult.make(tokens: tokens, segments: segments, mapping: .init(overrides: [1: 0]))
        #expect(merged.speakers == Array(repeating: 0, count: tokens.count))
        #expect(merged.utterances.map(\.text) == ["うんうん先週も言ってました。"])
        let restored = MeetingResult.make(tokens: tokens, segments: segments)
        #expect(restored.utterances.map(\.text).joined() == merged.utterances.map(\.text).joined())
        #expect(restored.utterances.contains { $0.speaker == 1 })
    }

    @Test func 発話がなければ空() {
        let result = MeetingResult.make(tokens: [], segments: [])
        #expect(result.speakers.isEmpty && result.utterances.isEmpty)
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

    @Test func フレーズ出力は区間と窓判定から補正後への変化を並べる() {
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
