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
    private let feedback = ProcessInfo.processInfo.environment["KIKIGAKI_DEBUG_AI_FEEDBACK"]
    init(output: String) { self.output = URL(fileURLWithPath: output) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: UserDefaults(suiteName: suite)!)
            controller.window?.setFrameAutosaveName("")
            controller.window?.setContentSize(NSSize(width: 600, height: 740))
            controller.show()
            if feedback == "model" { try renderModel() }
            else if feedback != nil { try await renderFeedback() }
            else { try render() }
            controller.window?.orderOut(nil)
            UserDefaults.standard.removePersistentDomain(forName: suite)
            NSApp.terminate(nil)
        } catch {
            FileHandle.standardError.write(Data("AI progress capture failed: \(error)\n".utf8))
            exit(1)
        }
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
                participantName: [feedback == nil ? "迅雷" : "オブシディア", "ミネルヴァ", "クロディーヌ"][(slot - 1) % 3], cliPath: "/tmp/capture-helper",
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
        var ai = AIViewState(conversation: conversation, connection: .idle,
            connections: Dictionary(uniqueKeysWithValues: (1...count).map { ($0, AIConnectionStatus.idle) }),
            generations: Dictionary(uniqueKeysWithValues: (1...count).map { ($0, 1) }))
        if let source = ProcessInfo.processInfo.environment["KIKIGAKI_DEBUG_AI_AVATAR"] { ai.avatarSources[1] = source }
        // 3つの枠で、項目の欠け方を変えて出す。2はmodel未設定でCLI名、3はeffort未設定。
        ai.modelLabels = [1: AIModelLabel(model: "gpt-6-astra", effort: "high", directory: "minutes"),
                          2: AIModelLabel(model: "claude", effort: "max", directory: "owlery"),
                          3: AIModelLabel(model: "gpt-6-astra", directory: "kikigaki")]
        return SessionSnapshot(ai: ai, state: .recording,
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
        if feedback == "labels" {
            guard let small = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: small) else { throw AIError.invalid("capture 1x") }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            bitmap.draw(in: NSRect(origin: .zero, size: view.bounds.size))
            NSGraphicsContext.restoreGraphicsState()
            guard let data = small.representation(using: .png, properties: [:]) else { throw AIError.invalid("capture 1x bitmap") }
            try data.write(to: output.appendingPathComponent(name + "-1x.png"))
        }
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
    /// 名前行のモデル表記。返事待ち・回答・3宛先同時・420ptの4枚を撮る。
    private func renderModel() throws {
        apply(try fixture(count: 1, accepted: true)); try capture("model-waiting")
        apply(try answering(count: 1)); try capture("model-answered")
        // 混雑した会議。#1は返事待ちのまま、#2と#3は回答済みで所要時間まで並ぶ。
        var busy = try answering(count: 3, waitingSlots: [1], crowded: true)
        busy.ai?.connections = [1: .working, 2: .idle, 3: .idle]
        apply(busy); try capture("model-three-destinations")
        controller.window?.setContentSize(NSSize(width: 420, height: 740))
        apply(busy); try capture("model-three-destinations-narrow")
        controller.window?.setContentSize(NSSize(width: 600, height: 740))
    }
    private func answering(count: Int, waitingSlots: Set<Int> = [], crowded: Bool = false) throws -> SessionSnapshot {
        var state = try fixture(count: count, accepted: true, crowded: crowded)
        guard var conversation = state.ai?.conversation else { throw AIError.invalid("answer fixture") }
        for question in conversation.questions where !waitingSlots.contains(question.request.number) {
            try conversation.receive(AIReceiveEvent(request: question.request, kind: .answered,
                recordedAt: now.addingTimeInterval(-3),
                body: "公開日までに録音と議事録の動作を確認し、残った確認事項は担当者へ伝えます。"),
                at: now.addingTimeInterval(-3))
        }
        state.ai?.conversation = conversation
        return state
    }
    private func renderFeedback() async throws {
        var state = try fixture(count: 1, accepted: true)
        state.ai?.connections[1] = .working
        apply(state)
        guard let row = controller.transcriptDocument.rows.compactMap({ $0 as? AIReplyRow }).first,
              let avatar = row.subviews.compactMap({ $0 as? AvatarView }).first else { throw AIError.invalid("avatar row") }
        for _ in 0..<100 where avatar.image == nil { try await Task.sleep(for: .milliseconds(20)) }
        guard avatar.image != nil else { throw AIError.invalid("avatar load") }
        if feedback == "labels" {
            apply(state); try capture("labels-working")
            state.ai?.connections[1] = .blocked
            apply(state); try capture("labels-blocked")
            state.ai?.connections[1] = .disconnected
            apply(state); try capture("labels-disconnected")
            state.ai?.readOnly = true; state.state = .idle; state.saved = true
            apply(state); try capture("labels-historical")
            var busy = try fixture(count: 3, accepted: true, crowded: true)
            busy.ai?.connections = [1: .working, 2: .blocked, 3: .idle]
            apply(busy); try capture("labels-three-destinations")
            return
        }
        apply(state); try capture(feedback == "before" ? "before-working" : "working")
        if feedback == "before" { return }
        state.ai?.connections[1] = .disconnected
        apply(state); try capture("disconnected")
        state.ai?.readOnly = true; state.state = .idle; state.saved = true
        apply(state); try capture("historical-waiting")
        var busy = try fixture(count: 3, accepted: true, crowded: true)
        busy.ai?.connections = [1: .working, 2: .blocked, 3: .idle]
        apply(busy); try capture("three-destinations-crowded")
        try renderFeedbackReplies()
    }
    private func renderFeedbackReplies() throws {
        for kind in [AIReceiveEvent.Kind.answered, .needsInput] {
            var answered = try fixture(count: 1, accepted: true)
            guard var conversation = answered.ai?.conversation, let request = conversation.questions.first?.request else { throw AIError.invalid("reply fixture") }
            try conversation.receive(AIReceiveEvent(request: request, kind: kind, recordedAt: now.addingTimeInterval(-1),
                body: kind == .answered ? "公開日までに録音と議事録の動作を確認し、残った確認事項は担当者へ伝えます。" : "動作確認の担当者は田中さんでよいですか？",
                reason: kind == .needsInput ? "clarification" : nil), at: now)
            answered.ai?.conversation = conversation
            apply(answered); try capture(kind == .answered ? "answered" : "needs-input")
            if kind == .answered {
                answered.ai?.readOnly = true; answered.state = .idle; answered.saved = true
                apply(answered); try capture("historical")
            }
        }
    }
}
#endif
