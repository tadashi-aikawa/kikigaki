import Foundation
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import Kikigaki

/// 録音停止後の後片付け。返事待ちが片付いてからherdrのペインを閉じる。
@Suite(.timeLimit(.minutes(1))) @MainActor struct AIPaneCloseTests {
    private func session(_ root: URL, herdr: @escaping AIHerdr.Run) throws -> MeetingSession {
        var config = ResolvedConfig(config: try ConfigLoader.parse(toml: ""), home: root)
        config.ai = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path), home: root)
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: herdr) })
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"),
                                     config: config, aiStore: store, recordedSamples: 16_000)
        session.setScheduleTranscriptForTesting("試行日は金曜日です")
        session.aiPaneClosePollInterval = 0.05
        return session
    }
    private func submit(_ session: MeetingSession) async {
        session.submitAI(question: "確認してください", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"))
        await session.submissionTaskForTesting?.value
    }
    private func reply(_ session: MeetingSession, root: URL, kind: AIReceiveEvent.Kind = .answered) throws {
        let controller = try #require(session.aiRecord?.controller)
        let request = try #require(controller.conversation.questions.last?.request)
        let event = try AIReceiveEvent(request: request, kind: kind, recordedAt: Date(), body: "確認しました",
                                       reason: kind == .needsInput ? "clarification" : nil)
        try AIFileStore(root: root).write(AIJSON.encode(event), to: [".kikigaki-context", session.aiMeetingID.uuidString,
            "ai", "inbox", request.id.uuidString + ".result.json"], replacing: false)
        controller.scan()
    }
    private func closed(_ fake: FakeHerdr) async -> Bool {
        await fake.commands.contains { $0.prefix(2) == ["workspace", "close"] }
    }

    @Test func 返事が届いてからペインを閉じ送信も再表示もできなくする() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let session = try session(root, herdr: { try await fake.run($0, $1) })
        await submit(session)
        #expect(session.aiRecord?.controller.conversation.questions.last?.state == .submitted)
        await session.stop()
        #expect(session.snapshot.saved)
        // 返事待ちの間は閉じない。
        try await Task.sleep(for: .milliseconds(200))
        #expect(await !closed(fake))
        #expect(session.aiRecord?.controller.hasOpenPanes == true)
        try reply(session, root: root)
        await session.paneCleanupTaskForTesting?.value
        #expect(await closed(fake))
        let controller = try #require(session.aiRecord?.controller)
        #expect(controller.isPaneClosed(slot: 1) && !controller.hasOpenPanes)
        #expect(!controller.canSend(slot: 1) && session.snapshot.ai?.canOpenPane == false)
        // 会議の記録はそのまま読める。
        #expect(controller.conversation.questions.last?.result?.body == "確認しました")
    }

    @Test func 返事待ちがなければ停止と同時に閉じる() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let session = try session(root, herdr: { try await fake.run($0, $1) })
        await submit(session)
        try reply(session, root: root)
        await session.stop()
        await session.paneCleanupTaskForTesting?.value
        #expect(await closed(fake))
        #expect(session.aiRecord?.controller.isPaneClosed(slot: 1) == true)
    }

    @Test func 最後の1回とその返事が済んでから閉じる() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let session = try session(root, herdr: { try await fake.run($0, $1) })
        defer { session.stopAISchedule() }
        let now = Date()
        try session.startAISchedule(options: .init(prompt: "議事録を更新"), helper: URL(fileURLWithPath: "/bin/echo"), now: now)
        session.evaluateAISchedule(now: now.addingTimeInterval(180))
        await session.submissionTaskForTesting?.value
        try reply(session, root: root)
        await session.stop()
        // 最後の1回の判定が残っている間は閉じない。
        try await Task.sleep(for: .milliseconds(150))
        #expect(await !closed(fake))
        session.evaluateAISchedule()
        await session.submissionTaskForTesting?.value
        #expect(session.aiRecord?.controller.conversation.questions.count == 2)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await !closed(fake))
        try reply(session, root: root)
        await session.paneCleanupTaskForTesting?.value
        #expect(await closed(fake))
        #expect(session.aiRecord?.controller.conversation.questions.allSatisfy { $0.result != nil } == true)
    }

    /// 停止と同時に始まる最後の1回は、停止の時点でまだ接続も会議の登録簿も無い。
    @Test func 停止で初めて接続する最後の1回でも返事を待ってから閉じる() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let session = try session(root, herdr: { try await fake.run($0, $1) })
        defer { session.stopAISchedule() }
        try session.startAISchedule(options: .init(prompt: "議事録を更新"), helper: URL(fileURLWithPath: "/bin/echo"))
        // 停止後の本文が空だと変更なしで送らない。最終保存に残る手入力を置く。
        #expect(session.submitTyped("停止後に送る行"))
        #expect(session.aiRecord == nil)
        await session.stop()
        await session.submissionTaskForTesting?.value
        #expect(session.aiRecord?.controller.conversation.questions.count == 1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await !closed(fake))
        try reply(session, root: root)
        await session.paneCleanupTaskForTesting?.value
        #expect(await closed(fake))
    }

    @Test func 未回答の確認質問は待たずに閉じる() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let session = try session(root, herdr: { try await fake.run($0, $1) })
        await submit(session)
        try reply(session, root: root, kind: .needsInput)
        await session.stop()
        await session.paneCleanupTaskForTesting?.value
        #expect(await closed(fake))
        // 返答の導線は出さない。記録は残る。
        #expect(session.snapshot.ai?.canAsk == false)
        #expect(session.aiRecord?.controller.conversation.questions.last?.state == .needsInput)
    }

    @Test func 上限を過ぎたら返事待ちでも閉じる() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let session = try session(root, herdr: { try await fake.run($0, $1) })
        session.aiPaneCloseTimeout = 0.2
        await submit(session)
        await session.stop()
        await session.paneCleanupTaskForTesting?.value
        #expect(await closed(fake))
        #expect(session.aiRecord?.controller.conversation.questions.last?.isAwaitingResult == true)
    }

    @Test func 閉じられなければ警告だけ残し保存は成功のままにする() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let session = try session(root, herdr: { args, timeout in
            if args.prefix(2) == ["workspace", "close"] {
                return AIProcessOutput(status: 1, stdout: Data(), stderr: Data("{\"error\":{\"code\":\"herdr_failed\"}}".utf8))
            }
            return try await fake.run(args, timeout)
        })
        await submit(session)
        try reply(session, root: root)
        await session.stop()
        await session.paneCleanupTaskForTesting?.value
        #expect(session.snapshot.saved && session.snapshot.message?.contains("保存") != false)
        #expect(session.snapshot.ai?.warning?.contains("ペインを閉じられません") == true)
        let controller = try #require(session.aiRecord?.controller)
        #expect(!controller.isPaneClosed(slot: 1) && controller.hasOpenPanes)
        #expect(session.snapshot.ai?.canOpenPane == true)
    }

    @Test func 停止後は手動の依頼を受け付けない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let session = try session(root, herdr: { try await fake.run($0, $1) })
        session.aiPaneCloseTimeout = 0.2
        await session.stop()
        #expect(session.snapshot.ai?.canSubmit == false && session.snapshot.ai?.canAsk == false)
        await submit(session)
        #expect(session.aiRecord == nil)
        #expect(await fake.commands.isEmpty)
    }
}
