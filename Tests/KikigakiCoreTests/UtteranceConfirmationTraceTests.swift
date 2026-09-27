import Testing
@testable import KikigakiCore

@Suite struct UtteranceConfirmationTraceTests {
    @Test func 画面の未確定と停止後の全確定をtraceで確認でき通常は出さない() {
        let tokens = [TimedToken(text: "発言", phraseId: 0, start: 0, end: 1),
                      TimedToken(text: "続き", phraseId: 1, start: 3, end: 4)]
        let live = LiveTranscript(tokens: tokens, speakers: [0, 1], finalCount: 1)
        let rows = live.unconfirmedRows(accurateFinalCount: 0)
        let enabled = Diagnostics(environment: ["KIKIGAKI_DEBUG_LIVE_TRACE": "1"])
        #expect(enabled.utteranceConfirmationLines(unconfirmedRows: rows, hasTentative: live.tentativeText != nil,
            utterances: live.utterances, elapsed: 2, diarizationEnabled: true, finalized: false)
            == ["[utterance-confirmation at=2.00 mode=on finalized=false] rows=0.00:未確定 tentative=未確定"])
        #expect(enabled.utteranceConfirmationLines(unconfirmedRows: [], hasTentative: false, utterances: live.utterances,
            elapsed: 3, diarizationEnabled: false, finalized: true)
            == ["[utterance-confirmation at=3.00 mode=off finalized=true] rows=0.00:確定 tentative=なし"])
        #expect(Diagnostics(environment: [:]).utteranceConfirmationLines(unconfirmedRows: rows, hasTentative: true,
            utterances: live.utterances, elapsed: 2, diarizationEnabled: true, finalized: false).isEmpty)
    }
}
