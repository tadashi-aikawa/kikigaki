import Foundation
import Testing
@testable import KikigakiCore

@Suite struct AICaptureTests {
    @Test func 後続の語を除き確定と暫定を分ける() throws {
        let tokens = [TimedToken(text: "本文。", phraseId: 0, start: 0, end: 1), TimedToken(text: "質問", phraseId: 1, start: 1, end: 2), TimedToken(text: "後の発言", phraseId: 2, start: 2, end: 3)]
        let timeline = MeetingTimeline(startedAt: Date(timeIntervalSince1970: 0))
        let waiting = try AICapture(tokens: tokens, speakers: [0, 0, 0], finalCount: 1, processedUntil: 3, cutoff: 2, names: SpeakerNames(), timeline: timeline)
        #expect(waiting.lines.count == 1 && waiting.tail?.text == "質問")
        #expect(waiting.needsConfirmation)
        let ready = try AICapture(tokens: tokens, speakers: [0, 0, 0], finalCount: 3, processedUntil: 3, cutoff: 2, names: SpeakerNames(), timeline: timeline)
        #expect(!ready.needsConfirmation && ready.tail == nil)
        #expect(!ready.lines.joined().contains("後の発言"))
    }
    @Test func 境界をまたぐ語は確定snapshotに入れない() throws {
        let capture = try AICapture(tokens: [.init(text: "確認する", phraseId: 0, start: 1, end: 3)], speakers: [0], finalCount: 1,
            processedUntil: 3, cutoff: 2, names: SpeakerNames(), timeline: .init(startedAt: Date()))
        #expect(capture.lines.isEmpty && capture.tail?.text == "確認する")
        #expect(capture.tail?.endSeconds == 2 && capture.needsConfirmation)
    }
    @Test func 消費側が追いつかない場合と壊れた境界を区別する() throws {
        let capture = try AICapture(tokens: [], speakers: [], finalCount: 0, processedUntil: 1, cutoff: 2, names: SpeakerNames(), timeline: .init(startedAt: Date()))
        #expect(capture.needsConfirmation)
        #expect(throws: AIError.invalid("capture boundary")) {
            try AICapture(tokens: [], speakers: [], finalCount: 1, processedUntil: 1, cutoff: 2, names: SpeakerNames(), timeline: .init(startedAt: Date()))
        }
    }
}
