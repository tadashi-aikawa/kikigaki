import Foundation
import Testing

@testable import KikigakiCore

@Suite struct TranscriptRendererTests {
    private let timeline = MeetingTimeline(startedAt: Date(timeIntervalSince1970: 0))
    private let utc = TimeZone(secondsFromGMT: 0)!
    @Test func 表示の既定も発話と手入力の秒を出す() throws {
        let voice = Utterance(speaker: 0, start: 61, end: 62, text: "確認します")
        let typed = try Utterance(typedText: "確認しました", at: 61, postedAt: Date(timeIntervalSince1970: 67))
        #expect(TranscriptRenderer.clock(for: voice, timeline: timeline, timeZone: utc) == "00:01:01")
        #expect(TranscriptRenderer.clock(for: typed, timeline: timeline, timeZone: utc) == "00:01:07")
    }
    @Test func 経過時刻はmmss() {
        #expect(TranscriptRenderer.elapsed(0) == "00:00")
        #expect(TranscriptRenderer.elapsed(65.9) == "01:05")
        #expect(TranscriptRenderer.elapsed(3725) == "62:05")
        #expect(TranscriptRenderer.elapsed(-1) == "00:00")
    }

    @Test func 行は時刻と話者名とテキスト() {
        let names = SpeakerNames([0: "田中"])
        let u = Utterance(speaker: 0, start: 61, end: 63, text: "こんにちは")
        #expect(TranscriptRenderer.line(u, names: names, timeline: timeline, timeZone: utc) == "[00:01:01] 田中: こんにちは")
        let unknown = Utterance(speaker: nil, start: 0, end: 1, text: "…")
        #expect(TranscriptRenderer.line(unknown, names: names, timeline: timeline, timeZone: utc) == "[00:00:00] ?: …")
    }

    @Test func テキスト中の改行は空白にする() {
        let u = Utterance(speaker: 0, start: 0, end: 1, text: "一行目\n二行目")
        #expect(TranscriptRenderer.line(u, names: SpeakerNames(), timeline: timeline, timeZone: utc) == "[00:00:00] 話者A: 一行目 二行目")
    }

    @Test func 複数行は改行で繋ぐ() {
        let us = [
            Utterance(speaker: 0, start: 0, end: 1, text: "a"),
            Utterance(speaker: 1, start: 1, end: 2, text: "b"),
        ]
        #expect(TranscriptRenderer.text(us, names: SpeakerNames()) == "[00:00] 話者A: a\n[00:01] 話者B: b")
    }
}
