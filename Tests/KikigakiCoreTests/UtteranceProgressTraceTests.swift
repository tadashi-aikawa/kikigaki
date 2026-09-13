import Testing
@testable import KikigakiCore

@Suite struct UtteranceProgressTraceTests {
    @Test func 画面の段と停止後の消去をtraceで確認でき通常は出さない() {
        let tokens = [TimedToken(text: "発言", phraseId: 0, start: 0, end: 1)]
        let live = LiveTranscript(tokens: tokens, speakers: [0], finalCount: 1)
        let progress = live.progress(accurateFinalCount: 0)
        let enabled = Diagnostics(environment: ["KIKIGAKI_DEBUG_LIVE_TRACE": "1"])
        #expect(enabled.utteranceProgressLines(progress, utterances: live.utterances, elapsed: 2,
            diarizationEnabled: true, finalized: false) == ["[utterance-progress at=2.00 mode=on finalized=false] rows=0.00:速報の確定 tentative=非表示"])
        #expect(enabled.utteranceProgressLines(nil, utterances: live.utterances, elapsed: 3,
            diarizationEnabled: false, finalized: true) == ["[utterance-progress at=3.00 mode=off finalized=true] rows=0.00:非表示 tentative=非表示"])
        #expect(Diagnostics(environment: [:]).utteranceProgressLines(progress, utterances: live.utterances, elapsed: 2,
            diarizationEnabled: true, finalized: false).isEmpty)
    }
}
