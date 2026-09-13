#if DEBUG
import AppKit
import KikigakiCore

/// --show-windowと明示的な撮影先を指定した開発時だけ起動する。
/// 保存・herdr通信は行わず、実際のrequest操作から本番のウィンドウへ状態を流す。
@MainActor final class AIProgressCaptureHarness: NSObject, NSApplicationDelegate {
    private let output: URL
    private var controller: TranscriptWindowController!
    private let now = Date()
    private var start: Date { now.addingTimeInterval(-600) }
    private let suite = "kikigaki-ai-progress-capture-" + UUID().uuidString
    init(output: String) { self.output = URL(fileURLWithPath: output) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: UserDefaults(suiteName: suite)!)
            controller.window?.setFrameAutosaveName("")
            controller.window?.setContentSize(NSSize(width: 600, height: 740))
            controller.show()
            try render()
            controller.window?.orderOut(nil)
            UserDefaults.standard.removePersistentDomain(forName: suite)
            NSApp.terminate(nil)
        } catch {
            FileHandle.standardError.write(Data("AI progress capture failed: \(error)\n".utf8))
            exit(1)
        }
    }
    private func fixture(count: Int, accepted: Bool, deliveryUnknown: Bool = false, crowded: Bool = false) throws -> SessionSnapshot {
        let meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        let lines = ["公開日までに、録音と議事録の動作を確認します。", "受領と作業中を区別できると、待つ理由が分かります。",
                     "確認事項が残っていたら、担当者へ伝えましょう。"]
        let utterances = (0..<(crowded ? 45 : 3)).map { index in
            Utterance(speaker: index % 2, start: Double(index * 10), end: Double(index * 10 + 8), text: lines[index % lines.count])
        }
        for slot in 1...count {
            var history = try AIStreamHistory(meetingID: meeting)
            let snapshot = try history.prepare(lines: ["[00:00:01] 田中: " + lines[0]], outputDirectory: output)
            let participant = AIParticipantContext(streamID: snapshot.streamID, requestID: UUID(), sessionGeneration: 1,
                participantName: ["迅雷", "ミネルヴァ", "クロディーヌ"][(slot - 1) % 3], cliPath: "/tmp/capture-helper",
                sessionPath: output.appendingPathComponent(".kikigaki-context/\(meeting)/"
                    + AIEnvelope.sessionPath(slot: slot, generation: 1)).path,
                requestToken: "capture", question: "", capturedAt: now.addingTimeInterval(-85),
                audioCutoffSeconds: 440, profile: "宛先\(slot)", profileSlot: slot)
            let request = try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant), number: slot,
                voiceQuestion: lines[0], snapshot: snapshot, voiceUtteranceStart: crowded ? 420 : 0)
            try conversation.append(request)
            try conversation.update(request.id) {
                try $0.beginSending(at: now.addingTimeInterval(accepted ? -80 : -2))
                if !deliveryUnknown { try $0.submitted() }
            }
            if accepted {
                try conversation.receive(AIReceiveEvent(request: request, kind: .accept, recordedAt: now.addingTimeInterval(-78)),
                                         at: now.addingTimeInterval(-78))
            }
        }
        return SessionSnapshot(ai: AIViewState(conversation: conversation, connection: .idle,
            connections: Dictionary(uniqueKeysWithValues: (1...count).map { ($0, AIConnectionStatus.idle) }),
            generations: Dictionary(uniqueKeysWithValues: (1...count).map { ($0, 1) })), state: .recording,
            utterances: utterances, timeline: MeetingTimeline(startedAt: start), names: SpeakerNames([0: "田中", 1: "佐藤"]),
            elapsed: 600, markdownURL: output.appendingPathComponent("fixture.md"), detectedSpeakerSlots: [0, 1])
    }
    private func apply(_ snapshot: SessionSnapshot) {
        var snapshot = snapshot
        if let ai = snapshot.ai {
            snapshot.ai?.unconfirmed = Set((ai.conversation?.questions ?? []).filter {
                AIReturnStatus.isUnconfirmed(question: $0, connection: ai.connection(for: $0.request),
                    idleSince: now.addingTimeInterval(-6), now: now, hasRunningBackgroundTasks: false)
            }.map { $0.request.id })
        }
        controller.apply(snapshot)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        for row in controller.transcriptDocument.rows.compactMap({ $0 as? AIReplyRow }) {
            row.progressView.refresh(now: now)
        }
    }
    private func capture(_ name: String) throws {
        guard let view = controller.window?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AIError.invalid("capture view") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AIError.invalid("capture bitmap") }
        try data.write(to: output.appendingPathComponent(name + ".png"))
        let rows = controller.transcriptDocument.rows.compactMap { $0 as? AIReplyRow }
        print("\(name): \(Int(view.bounds.width))×\(Int(view.bounds.height))pt; " + rows.map {
            "\($0.item.participantName) \($0.progressView.displayText), height=\($0.frame.height)"
        }.joined(separator: "; "))
    }
    private func render() throws {
        apply(try fixture(count: 1, accepted: false)); try capture("submitted")
        var state = try fixture(count: 1, accepted: true)
        state.ai?.connections[1] = .working
        apply(state); try capture("working")
        state.ai?.connections[1] = .blocked
        apply(state); try capture("blocked")
        state.ai?.connections[1] = .idle
        apply(state); try capture("return-unconfirmed")
        state.ai?.connections[1] = .disconnected
        apply(state); try capture("disconnected")
        state.ai?.readOnly = true; state.state = .idle; state.saved = true
        apply(state); try capture("historical")
        var busy = try fixture(count: 3, accepted: true, crowded: true)
        busy.ai?.connections = [1: .working, 2: .blocked, 3: .idle]
        apply(busy); try capture("three-destinations-crowded")
        controller.window?.setContentSize(NSSize(width: 420, height: 740))
        apply(busy); try capture("three-destinations-narrow")
        controller.window?.setContentSize(NSSize(width: 600, height: 740))
        apply(try fixture(count: 1, accepted: false, deliveryUnknown: true)); try capture("delivery-unknown")
        var unaccepted = try fixture(count: 1, accepted: false)
        unaccepted.ai?.connections[1] = .blocked
        apply(unaccepted); try capture("blocked-before-accept")
    }
}
#endif
