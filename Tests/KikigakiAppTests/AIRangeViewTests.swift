import AppKit
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import Kikigaki

@Suite @MainActor struct AIRangeViewTests {
    private func capture(_ name: String, _ view: NSView) throws {
        guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] else { return }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @Test func 範囲の境界は行高と読んでいる位置を変えず600と900で描く() throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let started = Date(timeIntervalSince1970: 1788952320)
        let timeline = MeetingTimeline(startedAt: started)
        let texts = ["体験会は9月20日で進めましょう。", "説明を十分、体験を二十分に分けますか。",
                     "最後に質問の時間も五分あると安心ですね。", "参加者への案内は、今週の金曜までに送ります。",
                     "では、案内の文面は明日の昼までに共有します。", "当日の受付担当も決めておきたいです。"]
        var utterances = texts.enumerated().map { Utterance(speaker: $0.offset % 3, start: Double($0.offset * 10), end: Double($0.offset * 10 + 4), text: $0.element) }
        utterances[3] = try .init(typedText: texts[3], at: 30, postedAt: started.addingTimeInterval(30))
        var history = try AIStreamHistory(meetingID: UUID())
        var conversation = AIConversation(meetingID: history.meetingID)
        func request(_ count: Int, number: Int, kind: AIReceiveEvent.Kind) throws {
            let context = try history.prepare(lines: TranscriptRenderer.lines(Array(utterances.prefix(count)), names: SpeakerNames(), timeline: timeline), outputDirectory: root)
            let p = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
                participantName: "議事録", cliPath: "/tmp/helper",
                sessionPath: root.appendingPathComponent(".kikigaki-context/\(history.meetingID)/ai/sessions/1.json").path,
                requestToken: "test", question: "議事録を更新", capturedAt: started.addingTimeInterval(Double(count * 10 - 5)),
                audioCutoffSeconds: Double(count * 10 - 5), trigger: .scheduled)
            let request = try AIRequest(envelope: AIEnvelope(snapshot: context, participant: p), number: number, voiceQuestion: "", snapshot: context)
            try conversation.append(request)
            try conversation.update(request.id) { try $0.beginSending(at: p.capturedAt); try $0.submitted() }
            try conversation.receive(AIReceiveEvent(request: request, kind: kind, recordedAt: p.capturedAt,
                body: kind == .accept ? nil : "議事録を更新しました。"), at: p.capturedAt)
            try history.acknowledge(snapshotID: context.id, streamID: history.streamID, sessionGeneration: 1)
        }
        try request(2, number: 1, kind: .answered)
        try request(4, number: 2, kind: .accept)
        var state = SessionSnapshot(ai: AIViewState(conversation: conversation), state: .recording,
            utterances: utterances, timeline: timeline, names: SpeakerNames([0: "佐藤", 1: "鈴木", 2: "田中"]),
            elapsed: 60, markdownURL: root.appendingPathComponent("meeting.md"))
        let boundaries = AIRangeBoundaries.resolve(history: history, questions: conversation.questions, utterances: utterances)
        var overlap = conversation
        let pending = conversation.questions[1].request
        try overlap.receive(AIReceiveEvent(request: pending, kind: .answered, recordedAt: started.addingTimeInterval(39),
            body: "案内の担当と期限を追記しました。"), at: started.addingTimeInterval(39))
        var schedule = AIScheduleState(meetingID: history.meetingID)
        try schedule.start(options: .init(prompt: "議事録を更新"), now: Date(), runID: UUID())
        let window = TranscriptWindowController(shouldReduceMotion: { true })
        window.window!.setFrameAutosaveName("")
        for width in [600, 900] {
            state.ai?.conversation = conversation
            state.aiSchedule = AIScheduleViewState(schedule: schedule, availability: .awaitingResult)
            window.window!.setContentSize(NSSize(width: width, height: 800))
            state.ai?.rangeBoundaries = .init()
            window.apply(state)
            let content = window.window!.contentView!; content.layoutSubtreeIfNeeded()
            window.apply(state); content.layoutSubtreeIfNeeded()
            let frames = window.transcriptDocument.rows.map(\.frame)
            let height = window.transcriptDocument.frame.height
            window.transcriptDocument.followsBottom = false
            let origin = window.scrollView.contentView.bounds.origin
            state.ai?.rangeBoundaries = boundaries; window.apply(state); content.layoutSubtreeIfNeeded()
            #expect(window.transcriptDocument.rangeMarkers.count == 2)
            #expect(window.transcriptDocument.rangeMarkers.first?.row is AIReplyRow)
            #expect(window.transcriptDocument.subviews.suffix(2).allSatisfy { $0 is AIRangeBoundaryView })
            #expect(window.transcriptDocument.rows.map(\.frame) == frames)
            #expect(window.transcriptDocument.frame.height == height)
            #expect(window.scrollView.contentView.bounds.origin == origin)
            let lastSpeech = window.transcriptDocument.rows.compactMap { $0 as? TranscriptRow }[3]
            let speechIndex = try #require(window.transcriptDocument.rows.firstIndex { $0 === lastSpeech })
            #expect(window.transcriptDocument.rangeMarkers.last?.row === window.transcriptDocument.rows[speechIndex + 1])
            try capture("range-three-\(width)", content.superview!)
            state.ai?.conversation = overlap
            state.ai?.rangeBoundaries = AIRangeBoundaries.resolve(history: history, questions: overlap.questions, utterances: utterances)
            state.aiSchedule = AIScheduleViewState(schedule: schedule)
            window.apply(state); content.layoutSubtreeIfNeeded()
            #expect(window.transcriptDocument.rangeMarkers.count == 1)
            try capture("range-overlap-\(width)", content.superview!)
            state.ai?.rangeBoundaries = .init()
            state.ai?.conversation = nil
            state.aiSchedule = AIScheduleViewState(schedule: nil)
            window.apply(state); content.layoutSubtreeIfNeeded()
            #expect(window.transcriptDocument.rangeMarkers.isEmpty)
            try capture("range-none-\(width)", content.superview!)
        }
        state.state = .idle; state.saved = true; state.ai?.rangeBoundaries = boundaries
        state.ai?.conversation = conversation
        window.apply(state); window.window!.contentView!.layoutSubtreeIfNeeded()
        #expect(window.transcriptDocument.rangeMarkers.count == 2)
        window.scrollView.contentView.scroll(to: .zero)
        try capture("range-stopped-900", window.window!.contentView!.superview!)
        window.window!.setContentSize(NSSize(width: 600, height: 460))
        window.window!.contentView!.layoutSubtreeIfNeeded()
        window.apply(state)
        window.transcriptDocument.followsBottom = false
        window.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 40))
        let scrolledHeight = window.transcriptDocument.frame.height
        state.ai?.rangeBoundaries = .init(); window.apply(state)
        #expect(window.scrollView.contentView.bounds.minY == 40)
        state.ai?.rangeBoundaries = boundaries; window.apply(state)
        #expect(window.scrollView.contentView.bounds.minY == 40)
        #expect(window.transcriptDocument.frame.height == scrolledHeight)
    }

    @Test func 自動宛先を保存復元し過去会議にも発話と境界を表示する() async throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = try testDirectory(); defer { try? FileManager.default.removeItem(at: registry) }
        let fake = FakeHerdr()
        let store = AIRecordStore(directory: registry, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        let record = try store.begin(meetingID: UUID(), markdownURL: root.appendingPathComponent("past.md"), config: .init(config: AIConfig(), home: root))
        store.setAutomaticSlot(1, for: record)
        let utterances = [Utterance(speaker: 0, start: 0, end: 2, text: "体験会は9月20日です。"),
                          try Utterance(typedText: "案内は金曜までに送ります。", at: 3, postedAt: Date())]
        let timeline = MeetingTimeline(startedAt: Date())
        let request = try record.controller.prepare(lines: TranscriptRenderer.lines(utterances, names: SpeakerNames(), timeline: timeline),
            question: "議事録を更新", voiceQuestion: "", capturedAt: Date(), cutoff: 5, tail: nil,
            config: record.manifest.config, helper: root.appendingPathComponent("helper"), trigger: .scheduled)
        try await record.controller.connect(config: record.manifest.config, label: "test", executable: root.appendingPathComponent("fake"), arguments: [])
        try await record.controller.send(request, config: record.manifest.config)
        let event = try AIReceiveEvent(request: request, kind: .accept, recordedAt: Date())
        try AIFileStore(root: root).write(AIJSON.encode(event), to: [".kikigaki-context", record.manifest.meetingID.uuidString, "ai", "inbox", request.id.uuidString + ".accept.json"])
        record.controller.scan()
        #expect(record.controller.rangeBoundaries(slot: nil, utterances: utterances) == .init())
        #expect(record.controller.rangeBoundaries(slot: 2, utterances: utterances) == .init())
        #expect(record.controller.rangeBoundaries(slot: 1, utterances: utterances) == .init(accepted: 1))
        var archive = MeetingArchive(original: .init(startedAt: timeline.startedAt, duration: 5, utterances: utterances, names: SpeakerNames()),
            processed: nil, candidateCount: 0, markdownURL: record.manifest.markdownURL)
        _ = store.save(&archive, for: record.manifest.meetingID)
        record.controller.stopWatching()
        let recovered = AIRecordStore(directory: registry); recovered.recover()
        let restored = try #require(recovered.records[record.manifest.meetingID])
        defer { restored.controller.stopWatching() }
        #expect(restored.manifest.automaticSlot == 1)
        recovered.setAutomaticSlot(2, for: restored)
        #expect(restored.manifest.automaticSlot == 1)
        #expect(restored.controller.rangeBoundaries(slot: restored.manifest.automaticSlot, utterances: utterances) == .init(accepted: 1))
        let window = AIPastMeetingsWindow(store: recovered, current: { nil })
        window.window!.setFrameAutosaveName(""); window.window!.setContentSize(NSSize(width: 600, height: 600))
        window.update(); window.window!.contentView!.layoutSubtreeIfNeeded()
        let document = try #require(descendants(window.window!.contentView!).compactMap { $0 as? TranscriptDocument }.first)
        #expect(document.rows.compactMap { $0 as? TranscriptRow }.count == 2)
        #expect(document.rangeMarkers.count == 1)
        try capture("range-past-600", window.window!.contentView!.superview!)
        try record.controller.newGeneration()
        let afterRecreation = AIRecordStore(directory: registry); afterRecreation.recover()
        let newRecord = try #require(afterRecreation.records[record.manifest.meetingID])
        defer { newRecord.controller.stopWatching() }
        #expect(newRecord.controller.rangeBoundaries(slot: 1, utterances: utterances) == .init())
    }
}
