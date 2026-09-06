import Foundation
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct AIConfirmationWaitTests {
    private func value(final: Bool) throws -> AICapture {
        try AICapture(tokens: [.init(text: "質問", phraseId: 0, start: 0, end: 1)], speakers: [0], finalCount: final ? 1 : 0,
            processedUntil: 1, cutoff: 1, names: SpeakerNames(), timeline: .init(startedAt: Date()))
    }
    @Test func 確定した時点で待ちを終え上限では最新の暫定を返す() async throws {
        var polls = 0
        let ready = try await AIConfirmationWait.capture(maximumWait: 1, latest: { polls += 1; return try value(final: polls == 2) }, progress: { _ in })
        #expect(polls == 2 && ready.tail == nil)
        let waiting = try await AIConfirmationWait.capture(maximumWait: 0.01, latest: { try value(final: false) }, progress: { _ in })
        #expect(waiting.tail?.text == "質問")
    }
    @Test func 取消後に確定しても次の送信へ進まない() async throws {
        var sent = false
        let task = Task {
            _ = try await AIConfirmationWait.capture(latest: { try value(final: false) }, progress: { _ in })
            sent = true
        }
        try await Task.sleep(for: .milliseconds(10)); task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!sent)
    }
}
