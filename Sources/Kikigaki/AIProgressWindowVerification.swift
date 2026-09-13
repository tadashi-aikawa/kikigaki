#if DEBUG
import AppKit
import KikigakiCore

/// 実際のAppKitイベントループでウィンドウの可視性を検証する。テストホストから別プロセスで起動する。
@MainActor final class AIProgressWindowVerification: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await verify(); print("AI progress window verification passed"); exit(0) }
            catch { FileHandle.standardError.write(Data("AI progress window verification failed: \(error)\n".utf8)); exit(1) }
        }
    }
    private func verify() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var history = try AIStreamHistory(meetingID: UUID())
        let source = try history.prepare(lines: ["[00:00:01] 話者A: 表示を確認します"], outputDirectory: root)
        let sent = Date().addingTimeInterval(-80)
        let participant = AIParticipantContext(streamID: source.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: "検証用AI", cliPath: "/tmp/helper",
            sessionPath: root.appendingPathComponent(".kikigaki-context/\(source.meetingID)/ai/sessions/1.json").path,
            requestToken: "test", question: "", capturedAt: sent, audioCutoffSeconds: 1)
        let request = try AIRequest(envelope: AIEnvelope(snapshot: source, participant: participant), number: 1,
            voiceQuestion: "表示を確認します", snapshot: source, voiceUtteranceStart: 0)
        var conversation = AIConversation(meetingID: source.meetingID)
        try conversation.append(request)
        try conversation.update(request.id) { try $0.beginSending(at: sent); try $0.submitted() }
        try conversation.receive(AIReceiveEvent(request: request, kind: .accept, recordedAt: sent), at: sent)
        var state = SessionSnapshot(ai: AIViewState(conversation: conversation, connection: .working),
            utterances: (0..<30).map { .init(speaker: 0, start: Double($0), end: Double($0 + 1), text: "スクロール確認用の発言です。") })
        let suite = "ai-progress-window-" + UUID().uuidString
        let controller = TranscriptWindowController(shouldReduceMotion: { false }, minutesDefaults: UserDefaults(suiteName: suite)!)
        guard let window = controller.window else { throw AIError.invalid("window") }
        window.setFrameAutosaveName(""); window.isReleasedWhenClosed = false
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 800)
        window.setFrame(NSRect(x: screen.minX + 40, y: screen.minY + 40, width: 600, height: 600), display: false)
        window.level = .floating
        let cover = NSWindow(contentRect: window.frame.insetBy(dx: -20, dy: -20), styleMask: [.borderless], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false; cover.isOpaque = true; cover.backgroundColor = .white
        cover.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        defer { cover.orderOut(nil); window.orderOut(nil); UserDefaults.standard.removePersistentDomain(forName: suite) }
        controller.show(); controller.apply(state); window.contentView?.layoutSubtreeIfNeeded()
        guard let row = controller.transcriptDocument.rows.compactMap({ $0 as? AIReplyRow }).first else { throw AIError.invalid("row") }
        let view = row.progressView
        func reveal() {
            controller.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: row.frame.minY - 20))
            controller.scrolled()
        }
        func expect(_ phase: String, _ condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { print("verified: " + phase); return }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw AIError.invalid(phase)
        }
        reveal()
        try await expect("visible") { window.occlusionState.contains(.visible) && view.timerRunning && view.observerCount == 4 }
        controller.scrollView.contentView.setBoundsOrigin(.zero); controller.scrolled()
        try await expect("scrolled out") { !view.timerRunning }
        reveal()
        try await expect("scrolled in") { view.timerRunning }
        cover.orderFrontRegardless()
        try await expect("occluded") { !window.occlusionState.contains(.visible) && !view.timerRunning }
        view.refresh(now: sent.addingTimeInterval(42)); cover.orderOut(nil)
        try await expect("uncovered recalculated") { view.timerRunning && !view.displayText.hasSuffix("0:42経過") }
        window.miniaturize(nil)
        try await expect("miniaturized") { window.isMiniaturized && !view.timerRunning }
        window.deminiaturize(nil)
        try await expect("deminiaturized") { view.timerRunning }
        window.close()
        try await expect("closed") { !view.timerRunning }
        view.refresh(now: sent.addingTimeInterval(42)); controller.show()
        try await expect("reopened recalculated") { view.timerRunning && !view.displayText.hasSuffix("0:42経過") }
        try conversation.receive(AIReceiveEvent(request: request, kind: .answered, recordedAt: Date(), body: "確認完了"), at: Date())
        state.ai?.conversation = conversation; controller.apply(state)
        try await expect("finished detached observers") { view.observerCount == 0 && !view.timerRunning }
    }
}
#endif
