import AppKit
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import Kikigaki

@Suite(.serialized) @MainActor struct MinutesSubmissionRevisionTests {
    @Test(arguments: ["自動", "確認", "再送"])
    func 全送信入口で人の指定だけを採取する(_ route: String) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        var config = ResolvedConfig(config: try ConfigLoader.parse(toml: ""), home: root)
        config.ai = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path), home: root)
        let records = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config, aiStore: records, recordedSamples: 16_000)
        session.setScheduleTranscriptForTesting("架空会議")
        session.submitAI(question: "先行依頼", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"))
        await session.submissionTaskForTesting?.value
        let controller = try #require(session.aiRecord?.controller), first = try #require(controller.conversation.questions.first?.request)
        let kind: AIReceiveEvent.Kind = route == "確認" ? .needsInput : route == "再送" ? .failed : .answered
        let reason: String? = route == "確認" ? "clarification" : route == "再送" ? "work_failed" : nil
        let reply = try AIReceiveEvent(request: first, kind: kind, recordedAt: Date(), body: "検証", reason: reason)
        let files = AIFileStore(root: root), inbox = [".kikigaki-context", session.aiMeetingID.uuidString, "ai", "inbox"]
        try files.write(AIJSON.encode(reply), to: inbox + [reply.filename]); controller.scan()
        try session.selectMinutes("/tmp/人の指定.md")
        let event = try AIMinutesEvent(request: first, path: "/tmp/AIの対象.md", recordedAt: Date().addingTimeInterval(1))
        try files.write(AIJSON.encode(event), to: inbox + [event.filename]); controller.scan()
        #expect(controller.minutes.state.minutesPath == "/tmp/AIの対象.md")
        let window = TranscriptWindowController()
        defer { window.window?.orderOut(nil); session.stopAISchedule(); controller.stopWatching() }
        let prepared = AIPreparedStore(directory: root)
        let app = AppDelegate(testingSession: session, config: config, preparedStore: prepared, window: window)
        if route == "自動" {
            session.setScheduleTranscriptForTesting("更新された架空会議")
            try session.startAISchedule(options: .init(prompt: "更新", sendFinal: false), helper: URL(fileURLWithPath: "/bin/echo"))
            session.fireAIScheduleNow()
        } else {
            app.showAISheet(parent: route == "確認" ? first.id : nil, resend: route == "再送" ? first.id : nil)
            let sheet = try #require(app.aiSheet)
            sheet.onSubmit?("返答", false)
            sheet.close(); app.dismissAISheet()
        }
        await session.submissionTaskForTesting?.value
        let next = try #require(controller.conversation.questions.last?.request)
        #expect(next.id != first.id && next.envelope.participant.minutesPath == "/tmp/人の指定.md")
        if route == "自動" { #expect(next.trigger == .scheduled) }
        if route == "確認" { #expect(next.envelope.participant.inReplyToRequestID == first.id) }
    }
}
