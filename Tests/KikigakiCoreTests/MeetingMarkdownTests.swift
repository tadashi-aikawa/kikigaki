import Foundation
import Testing

@testable import KikigakiCore

@Suite struct MeetingMarkdownTests {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    // 2026-09-05 12:40 JST
    private let startedAt = Date(timeIntervalSince1970: 1_788_579_600)

    @Test func 見出しとメタ情報と箇条書きの書き起こし() {
        let meeting = MeetingMarkdown.Meeting(
            startedAt: startedAt,
            duration: 2712,
            utterances: [
                Utterance(speaker: 0, start: 0, end: 2, text: "始めます"),
                Utterance(speaker: 1, start: 3, end: 5, text: "はい"),
                Utterance(speaker: nil, start: 6, end: 7, text: "…"),
            ],
            names: SpeakerNames([1: "田中"]))
        let expected = """
            # KIKIGAKI 2026-09-05 12:40

            - 開始: 2026-09-05 12:40
            - 長さ: 45:12
            - 話者: A=話者A, B=田中

            ## 書き起こし

            - [12:40:00] 話者A: 始めます
            - [12:40:03] 田中: はい
            - [12:40:06] ?: …

            """
        #expect(MeetingMarkdown.render(meeting, timeZone: tokyo) == expected)
    }

    @Test func 発話がなければ話者行を出さない() {
        let meeting = MeetingMarkdown.Meeting(startedAt: startedAt, duration: 0, utterances: [], names: SpeakerNames())
        let text = MeetingMarkdown.render(meeting, timeZone: tokyo)
        #expect(!text.contains("- 話者:"))
        #expect(text.hasSuffix("## 書き起こし\n\n"))
    }
}
