import AppKit
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import Kikigaki

@Suite(.timeLimit(.minutes(1))) @MainActor struct AIScheduleAppTests {
    private final class Hook {
        var action: (() -> Void)?
        func run() { action?() }
    }
    private func session(_ root: URL, fake: FakeHerdr) throws -> MeetingSession {
        var config = ResolvedConfig(config: try ConfigLoader.parse(toml: ""), home: root)
        config.ai = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path), home: root)
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config, aiStore: store, recordedSamples: 16_000)
        session.setScheduleTranscriptForTesting("試行日は金曜日です")
        return session
    }
    private func reply(_ session: MeetingSession, root: URL, kind: AIReceiveEvent.Kind = .answered) throws {
        let controller = try #require(session.aiRecord?.controller)
        let request = try #require(controller.conversation.questions.last?.request)
        let event = try AIReceiveEvent(request: request, kind: kind, recordedAt: Date(), body: "議事録を更新しました",
                                       reason: kind == .needsInput ? "clarification" : kind == .failed ? "work_failed" : nil)
        try AIFileStore(root: root).write(AIJSON.encode(event), to: [".kikigaki-context", session.aiMeetingID.uuidString,
            "ai", "inbox", request.id.uuidString + ".result.json"], replacing: false)
        controller.scan()
    }
    private func settle(_ session: MeetingSession) async { await session.submissionTaskForTesting?.value }

    @Test func 非稼働時の表示更新は自動送信用の全行を組まない() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try session(root, fake: FakeHerdr())
        #expect(session.scheduleLinesBuildCount == 0)
        session.setScheduleTranscriptForTesting("追加の発話")
        #expect(session.scheduleLinesBuildCount == 0)
        try session.startAISchedule(options: .init(prompt: "更新"), helper: URL(fileURLWithPath: "/bin/echo"))
        #expect(session.scheduleLinesBuildCount > 0)
        let runningCount = session.scheduleLinesBuildCount
        session.stopAISchedule()
        session.setScheduleTranscriptForTesting("停止後の発話")
        #expect(session.scheduleLinesBuildCount == runningCount)
        let noAI = MeetingSession(testingRecordingAt: root.appendingPathComponent("without-ai.md"),
            config: ResolvedConfig(config: try ConfigLoader.parse(toml: ""), home: root),
            aiStore: AIRecordStore(directory: root), recordedSamples: 16_000)
        noAI.setScheduleTranscriptForTesting("AI未設定の発話")
        #expect(noAI.scheduleLinesBuildCount == 0)
    }

    @Test func ゲージの即時実行が本番の送信経路へ入り期限を更新する() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try session(root, fake: FakeHerdr()), now = Date()
        defer { session.stopAISchedule() }
        try session.startAISchedule(options: .init(prompt: "今すぐ更新", sendFinal: false),
                                    helper: URL(fileURLWithPath: "/bin/echo"), now: now)
        let window = TranscriptWindowController()
        window.onFireScheduleAI = { session.fireAIScheduleNow(now: now.addingTimeInterval(42)) }
        window.apply(session.snapshot)
        window.compactFooter.gauge.activate(clickCount: 2)
        await settle(session)
        #expect(session.snapshot.aiSchedule.nextFire == now.addingTimeInterval(222))
        let request = try #require(session.aiRecord?.controller.conversation.questions.first)
        #expect(request.state == .submitted && request.request.trigger == .scheduled)
        session.fireAIScheduleNow(now: now.addingTimeInterval(43)); await settle(session)
        #expect(session.aiRecord?.controller.conversation.questions.count == 1)
        #expect(session.snapshot.aiSchedule.nextFire == now.addingTimeInterval(222))
        await session.stop()
    }

    @Test func 接続中に手動を開いたら接続を保って未送信の自動だけ譲る() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), hook = Hook()
        var config = ResolvedConfig(config: try ConfigLoader.parse(toml: ""), home: root)
        config.ai = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path), home: root)
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { args, timeout in
            if args.prefix(2) == ["workspace", "create"] { await hook.run() }
            return try await fake.run(args, timeout)
        }) })
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config, aiStore: store, recordedSamples: 16_000)
        defer { session.stopAISchedule() }
        session.setScheduleTranscriptForTesting("議題です")
        hook.action = { session.beginAIDraft() }
        let now = Date()
        try session.startAISchedule(options: .init(prompt: "更新"), helper: URL(fileURLWithPath: "/bin/echo"), now: now)
        session.evaluateAISchedule(now: now.addingTimeInterval(180)); await settle(session)
        #expect(session.aiRecord?.controller.conversation.questions.first?.state == .cancelled)
        #expect(session.aiRecord?.controller.canSend == true)
        #expect(await fake.commands.filter { $0.prefix(2) == ["agent", "prompt"] }.isEmpty)
        session.submitAI(question: "手動を先に", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"))
        await settle(session)
        #expect(session.aiRecord?.controller.conversation.questions.last?.state == .submitted)
        #expect(await fake.commands.filter { $0.prefix(2) == ["workspace", "create"] }.count == 1)
        session.endAIDraft(); await session.stop()
    }

    @Test func 自動と手動は同じ接続を使い変更なしとシート中は送らない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), session = try session(root, fake: fake), now = Date()
        defer { session.stopAISchedule() }
        session.updateAIDraft("手動の下書き")
        try session.startAISchedule(options: .init(prompt: "議事録を更新", workAllowed: false), helper: URL(fileURLWithPath: "/bin/echo"), now: now)
        session.beginAIDraft()
        session.evaluateAISchedule(now: now.addingTimeInterval(180))
        #expect(session.aiRecord == nil)
        session.endAIDraft()
        session.evaluateAISchedule(now: now.addingTimeInterval(360)); await settle(session)
        let first = try #require(session.aiRecord?.controller.conversation.questions.first)
        #expect(first.state == .submitted && first.request.trigger == .scheduled)
        #expect(!first.request.envelope.participant.workAllowed)
        #expect(session.aiDraft == "手動の下書き" && session.snapshot.ai?.submissionID == nil)
        session.evaluateAISchedule(now: now.addingTimeInterval(540))
        #expect(session.aiRecord?.controller.conversation.questions.count == 1)
        try reply(session, root: root)
        session.evaluateAISchedule(now: now.addingTimeInterval(720)); await settle(session)
        #expect(session.aiRecord?.controller.conversation.questions.count == 1)
        #expect(session.aiRecord?.controller.conversation.questions.first?.isUnread == false)
        let conversation = try #require(session.aiRecord?.controller.conversation)
        let items = AITimeline.items(conversation: conversation, utterances: [], timeline: MeetingTimeline(startedAt: now))
        // 自動の往復も人の発話と同格の行で、送信だけ細い1行にする。
        #expect(items.map(\.kind) == [.sendLine(automatic: true), .reply(.answered)])
        #expect(items.allSatisfy { $0.automatic })
        let sendItem = try #require(items.first), replyItem = try #require(items.last)
        #expect(sendItem.notes.first?.hasSuffix("発言") == true)
        #expect(replyItem.body.hasPrefix("議事録を更新しました"))
        session.submitAI(question: "手動の質問", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"))
        await settle(session)
        let questions = try #require(session.aiRecord?.controller.conversation.questions)
        #expect(questions.count == 2 && questions[1].request.trigger == nil)
        #expect(questions[0].request.envelope.participant.streamID == questions[1].request.envelope.participant.streamID)
        #expect(await fake.commands.filter { $0.prefix(2) == ["workspace", "create"] }.count == 1)
        await session.stop()
    }

    @Test(arguments: [AIReceiveEvent.Kind.answered, .needsInput, .failed])
    func 停止時の訂正は返事を待って最後に一度だけ送る(kind: AIReceiveEvent.Kind) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), session = try session(root, fake: fake), now = Date()
        defer { session.stopAISchedule() }
        try session.startAISchedule(options: .init(prompt: "議事録を更新"), helper: URL(fileURLWithPath: "/bin/echo"), now: now)
        session.evaluateAISchedule(now: now.addingTimeInterval(180)); await settle(session)
        await session.stop() // 音源なしfixtureの最終本文は空。受領後に削除訂正として送る。
        #expect(session.snapshot.saved && session.snapshot.aiSchedule.active)
        #expect(session.aiRecord?.controller.conversation.questions.count == 1)
        try reply(session, root: root, kind: kind)
        session.evaluateAISchedule(); await settle(session)
        #expect(session.aiRecord?.controller.conversation.questions.count == 2)
        let last = try #require(session.aiRecord?.controller.conversation.questions.last)
        #expect(last.state == .submitted && last.request.trigger == .scheduled)
        #expect(last.request.envelope.readLineCount == 0)
        session.evaluateAISchedule(); await settle(session)
        #expect(session.aiRecord?.controller.conversation.questions.count == 2)
        #expect(!session.snapshot.aiSchedule.active)
    }

    @Test func 自動送信シートの必須入力と既定と実画面() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let sheet = AIScheduleSheet(prompt: "", minutes: 7, workAllowed: false)
        let content = try #require(sheet.window.contentView)
        let button = try #require(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "開始" })
        #expect(!button.isEnabled)
        let editor = try #require(descendants(content).compactMap { $0 as? NSTextView }.first)
        editor.string = "会議の決定事項と担当・期限をMarkdown議事録へ更新してください。変更点を短く返してください。"
        sheet.textDidChange(Notification(name: NSText.didChangeNotification))
        var options: AIScheduleOptions?
        sheet.onStart = { options = $0 }
        button.performClick(nil); button.performClick(nil)
        #expect(options?.interval == 420 && options?.sendFinal == true && options?.workAllowed == false)
    }
}
