import Testing
@testable import KikigakiCore

@Suite struct UtteranceConfirmationMergeTests {
    @Test func 手入力の併合は未確定と話者未確定を同じ添字へ移し手入力を含めない() throws {
        let tokens = [TimedToken(text: "一つ目", phraseId: 0, start: 0, end: 1),
                      TimedToken(text: "二つ目", phraseId: 1, start: 3, end: 4)]
        let live = LiveTranscript(tokens: tokens, speakers: [0, 1], finalCount: 2, frozenCount: 1)
        let timeline = MeetingTimeline(startedAt: .distantPast)
        let typed = try Utterance(typedText: "追記", at: 2, postedAt: timeline.date(at: 2))
        let merged = TranscriptEntries.merge(voice: live.utterances, typed: [typed], timeline: timeline,
            pendingVoiceRows: live.pendingSpeakerRows, unconfirmedVoiceRows: live.unconfirmedRows(accurateFinalCount: 1))
        #expect(merged.utterances.map(\.text) == ["一つ目", "追記", "二つ目"])
        #expect(merged.unconfirmedRows == [2])
        #expect(merged.pendingSpeakerRows == [2])
        let saved = TranscriptEntries.merge(voice: live.utterances, typed: [typed], timeline: timeline)
        #expect(saved.unconfirmedRows.isEmpty)
        #expect(saved.utterances == merged.utterances)
    }
}
