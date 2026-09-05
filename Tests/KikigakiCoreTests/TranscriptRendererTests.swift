import Testing

@testable import KikigakiCore

@Suite struct TranscriptRendererTests {
    @Test func 経過時刻はmmss() {
        #expect(TranscriptRenderer.clock(0) == "00:00")
        #expect(TranscriptRenderer.clock(65.9) == "01:05")
        #expect(TranscriptRenderer.clock(3725) == "62:05")
        #expect(TranscriptRenderer.clock(-1) == "00:00")
    }

    @Test func 行は時刻と話者名とテキスト() {
        let names = SpeakerNames([0: "田中"])
        let u = Utterance(speaker: 0, start: 61, end: 63, text: "こんにちは")
        #expect(TranscriptRenderer.line(u, names: names) == "[01:01] 田中: こんにちは")
        let unknown = Utterance(speaker: nil, start: 0, end: 1, text: "…")
        #expect(TranscriptRenderer.line(unknown, names: names) == "[00:00] ?: …")
    }

    @Test func テキスト中の改行は空白にする() {
        let u = Utterance(speaker: 0, start: 0, end: 1, text: "一行目\n二行目")
        #expect(TranscriptRenderer.line(u, names: SpeakerNames()) == "[00:00] 話者A: 一行目 二行目")
    }

    @Test func 複数行は改行で繋ぐ() {
        let us = [
            Utterance(speaker: 0, start: 0, end: 1, text: "a"),
            Utterance(speaker: 1, start: 1, end: 2, text: "b"),
        ]
        #expect(TranscriptRenderer.text(us, names: SpeakerNames()) == "[00:00] 話者A: a\n[00:01] 話者B: b")
    }
}
