import Testing
@testable import KikigakiCore

@Suite struct SpeechTailTests {
    @Test func 発話前の間を含むいと僕を後続話者へつなぐ() {
        // 原音をユーザーが確認。「いや」「僕の場合は」はともに話者2。
        let tokens = RecordedSpeakerFixtures.iBoku.tokens
        let segments = RecordedSpeakerFixtures.iBoku.segments
        #expect(SpeechTail.speakers(tokens: tokens, segments: segments) == [2, 2, 2, 2])
        #expect(Aligner.speakers(for: tokens, segments: segments, frozen: [1])[0] == 1)
    }

    @Test func 連続発話と複数文字トークンを末尾話者へ付け替えない() {
        let continuous = [TimedToken(text: "あ", phraseId: 1, start: 0, end: 2),
                          TimedToken(text: "い", phraseId: 1, start: 2, end: 2.2)]
        let segments = [SpeakerSegment(speaker: 0, start: 0, end: 1.9), SpeakerSegment(speaker: 1, start: 1.9, end: 3)]
        #expect(SpeechTail.speakers(tokens: continuous, segments: segments)[0] == 0)
        var mixed = continuous
        mixed[0].text = "私の意見です"
        let separated = [SpeakerSegment(speaker: 0, start: 0, end: 1.1), SpeakerSegment(speaker: 1, start: 1.8, end: 3)]
        #expect(SpeechTail.speakers(tokens: mixed, segments: separated)[0] == 0)
    }

    @Test func 尾部が重複話者または後続が遠い場合は不明を保持する() {
        var tokens = [TimedToken(text: "い", phraseId: 1, start: 0, end: 2),
                      TimedToken(text: "や", phraseId: 1, start: 2, end: 2.2)]
        let overlapping = [SpeakerSegment(speaker: 0, start: 1.8, end: 2),
                           SpeakerSegment(speaker: 1, start: 1.8, end: 3)]
        #expect(SpeechTail.speakers(tokens: tokens, segments: overlapping)[0] == nil)
        tokens[1].start = 2.5
        tokens[1].end = 2.7
        #expect(SpeechTail.speakers(tokens: tokens, segments: [overlapping[1]])[0] == nil)
        #expect(SpeechTail.speakers(tokens: Array(tokens.prefix(1)), segments: [overlapping[1]])[0] == nil)
    }

    @Test func 後続話者と尾部が違う場合や区間外しか声がない場合は推測で埋めない() {
        let tokens = [TimedToken(text: "い", phraseId: 1, start: 0, end: 2),
                      TimedToken(text: "や", phraseId: 1, start: 2, end: 2.3)]
        let segments = [SpeakerSegment(speaker: 0, start: 1.8, end: 2),
                        SpeakerSegment(speaker: 1, start: 2, end: 3)]
        #expect(SpeechTail.speakers(tokens: tokens, segments: segments)[0] == nil)
        #expect(SpeechTail.speakers(tokens: tokens, segments: Array(segments.suffix(1)))[0] == nil)
    }
}
