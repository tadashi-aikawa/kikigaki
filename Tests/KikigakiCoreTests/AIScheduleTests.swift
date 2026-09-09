import Foundation
import Testing
import KikigakiCore

@Suite struct AIScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_000)
    @Test func 即時実行は送った時点から期限を打ち直しスキップは期限を変えない() throws {
        var state = try started()
        let immediate = now.addingTimeInterval(42)
        for availability in [AIScheduleAvailability.awaitingResult, .busy, .confirmation, .disconnected] {
            #expect(state.fireNow(now: immediate, availability: availability, hasChanges: true) == .skipped(.unavailable))
            #expect(state.nextFire == now.addingTimeInterval(180))
        }
        #expect(state.fireNow(now: immediate, availability: .ready, hasChanges: false) == .skipped(.noChange))
        #expect(state.nextFire == now.addingTimeInterval(180))
        #expect(state.fireNow(now: immediate, availability: .ready, hasChanges: true) == .send(final: false))
        #expect(state.nextFire == now.addingTimeInterval(222))
        #expect(state.tick(now: now.addingTimeInterval(180), availability: .ready, hasChanges: true) == .none)
        state.recordingStopped()
        #expect(state.fireNow(now: immediate, availability: .ready, hasChanges: true) == .none)
        state.stop()
        #expect(state.fireNow(now: immediate, availability: .ready, hasChanges: true) == .none)
    }
    private func started(final: Bool = true) throws -> AIScheduleState {
        var state = AIScheduleState(meetingID: UUID())
        try state.start(options: .init(prompt: "議事録を更新", interval: 180, workAllowed: false, sendFinal: final), now: now, runID: UUID())
        return state
    }

    @Test func 期限と遅延でも一度だけ判定し元の周期へ戻る() throws {
        var state = try started()
        #expect(state.options?.workAllowed == false)
        #expect(state.tick(now: now.addingTimeInterval(179), availability: .ready, hasChanges: true) == .none)
        #expect(state.tick(now: now.addingTimeInterval(180), availability: .ready, hasChanges: true) == .send(final: false))
        #expect(state.tick(now: now.addingTimeInterval(180), availability: .ready, hasChanges: true) == .none)
        #expect(state.tick(now: now.addingTimeInterval(721), availability: .ready, hasChanges: true) == .send(final: false))
        #expect(state.nextFire == now.addingTimeInterval(900))
    }

    @Test(arguments: [AIScheduleAvailability.awaitingResult, .busy, .confirmation, .disconnected])
    func 通常回は送れなければ溜めず次回へ進む(availability: AIScheduleAvailability) throws {
        var state = try started()
        #expect(state.tick(now: now.addingTimeInterval(180), availability: availability, hasChanges: true) == .skipped(.unavailable))
        #expect(state.nextFire == now.addingTimeInterval(360))
        #expect(state.consecutiveFailures == 0)
        #expect(state.tick(now: now.addingTimeInterval(360), availability: .ready, hasChanges: false) == .skipped(.noChange))
    }

    @Test(arguments: [AIScheduleAvailability.ready, .confirmation])
    func 最終回は返事待ちを期限なく保留し到着後一回だけ送る(afterReply: AIScheduleAvailability) throws {
        var state = try started()
        state.recordingStopped()
        #expect(state.nextFire == nil && state.phase == .awaitingSave)
        #expect(state.finalDecision(availability: .ready, hasChanges: true) == .none)
        #expect(state.finalSaveCompleted(succeeded: true) == .none)
        for _ in 0..<3 {
            #expect(state.finalDecision(availability: .awaitingResult, hasChanges: false) == .none)
            #expect(state.finalDecision(availability: .busy, hasChanges: true) == .none)
            #expect(state.tick(now: now.addingTimeInterval(99_999), availability: .ready, hasChanges: true) == .none)
        }
        #expect(state.phase == .awaitingFinal)
        #expect(state.finalDecision(availability: afterReply, hasChanges: true) == .send(final: true))
        #expect(state.finalSaveCompleted(succeeded: true) == .none)
        #expect(state.finalDecision(availability: afterReply, hasChanges: true) == .none)
    }

    @Test func 最終回の失敗と停止と差分なしは再送しない() throws {
        var disabled = try started(final: false)
        disabled.recordingStopped()
        #expect(disabled.phase == .stopped)
        var failed = try started()
        failed.recordingStopped()
        #expect(failed.finalSaveCompleted(succeeded: false) == .skipped(.saveFailed))
        #expect(failed.finalSaveCompleted(succeeded: true) == .none)
        for availability in [AIScheduleAvailability.disconnected, .ready] {
            var state = try started()
            state.recordingStopped(); _ = state.finalSaveCompleted(succeeded: true)
            #expect(state.finalDecision(availability: availability, hasChanges: false)
                    == .skipped(availability == .disconnected ? .disconnected : .noChange))
            #expect(state.finalDecision(availability: .ready, hasChanges: true) == .none)
        }
        var cancelled = try started()
        cancelled.recordingStopped(); _ = cancelled.finalSaveCompleted(succeeded: true); cancelled.stop()
        #expect(cancelled.finalDecision(availability: .ready, hasChanges: true) == .none)
    }

    @Test func 三連続失敗で停止し送達不明と後着結果を二重計上しない() throws {
        var state = try started()
        let run = try #require(state.runID), meeting = state.meetingID
        let ids = (0..<3).map { _ in UUID() }
        for id in ids { state.register(requestID: id, meetingID: meeting, runID: run) }
        #expect(state.observe(requestID: UUID(), meetingID: meeting, runID: run, outcome: .failed) == .none)
        #expect(state.observe(requestID: ids[0], meetingID: UUID(), runID: run, outcome: .failed) == .none)
        #expect(state.observe(requestID: ids[0], meetingID: meeting, runID: UUID(), outcome: .failed) == .none)
        _ = state.observe(requestID: ids[0], meetingID: meeting, runID: run, outcome: .deliveryUnknown)
        _ = state.observe(requestID: ids[0], meetingID: meeting, runID: run, outcome: .failed)
        _ = state.observe(requestID: ids[0], meetingID: meeting, runID: run, outcome: .failed)
        #expect(state.consecutiveFailures == 1)
        _ = state.observe(requestID: ids[1], meetingID: meeting, runID: run, outcome: .failed)
        #expect(state.observe(requestID: ids[2], meetingID: meeting, runID: run, outcome: .deliveryUnknown) == .stoppedAfterFailures)
        #expect(state.consecutiveFailures == 3 && state.phase == .stopped)
        _ = state.observe(requestID: ids[2], meetingID: meeting, runID: run, outcome: .answered)
        #expect(state.consecutiveFailures == 0 && state.phase == .stopped)
        try state.start(options: .init(prompt: "再開"), now: now, runID: UUID())
        _ = state.observe(requestID: ids[2], meetingID: meeting, runID: run, outcome: .failed)
        #expect(state.consecutiveFailures == 0)
    }

    @Test(arguments: [AIScheduleState.Outcome.answered, .needsInput])
    func 成功した回が連続失敗を切る(success: AIScheduleState.Outcome) throws {
        var state = try started()
        let run = try #require(state.runID), meeting = state.meetingID
        for outcome in [AIScheduleState.Outcome.failed, success, .failed] {
            let id = UUID(); state.register(requestID: id, meetingID: meeting, runID: run)
            _ = state.observe(requestID: id, meetingID: meeting, runID: run, outcome: outcome)
        }
        #expect(state.consecutiveFailures == 1 && state.phase == .running)
    }

    @Test func 受領本文との比較はsnapshot再利用と末尾削除を区別する() throws {
        var history = try AIStreamHistory(meetingID: UUID())
        let root = URL(fileURLWithPath: "/tmp/scheduled")
        #expect(!history.hasChanges(lines: []))
        let lines = ["行1", "行2"]
        let snapshot = try history.prepare(lines: lines, outputDirectory: root)
        #expect(history.hasChanges(lines: lines))
        try history.acknowledge(snapshotID: snapshot.id, streamID: history.streamID, sessionGeneration: 1)
        #expect(!history.hasChanges(lines: lines))
        #expect(try history.prepare(lines: lines, outputDirectory: root).readLineCount == 2)
        for changed in [["行1"], [], ["行1", "訂正"], lines + ["追加"]] { #expect(history.hasChanges(lines: changed)) }
        let deletion = try history.prepare(lines: ["行1"], outputDirectory: root)
        #expect(deletion.readLineCount == 0)
        #expect(!history.hasChanges(lines: lines)) // 未受領のprepareを基準にしない
        #expect(history.received?.id == snapshot.id)
    }

    @Test func 開始値を検証し標準外の設定間隔を保持する() throws {
        for prompt in ["", " \n", "a\0", String(repeating: "あ", count: 11_000)] {
            #expect(throws: (any Error).self) { try AIScheduleOptions(prompt: prompt) }
        }
        for interval in [0.0, -1, .infinity, .nan] {
            #expect(throws: (any Error).self) { try AIScheduleOptions(prompt: "更新", interval: interval) }
        }
        #expect(AIScheduleOptions.minuteChoices(including: 7) == [1, 2, 3, 5, 7, 10])
        #expect(AIScheduleOptions.minuteChoices(including: 3) == [1, 2, 3, 5, 10])
    }
}
