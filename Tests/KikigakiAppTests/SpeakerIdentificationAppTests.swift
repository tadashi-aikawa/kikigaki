import AppKit
import Foundation
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import Kikigaki
@testable import KikigakiCLI

extension AppKitTests {
@Suite(.serialized) @MainActor struct SpeakerIdentificationAppTests {
    private func session(_ root: URL, enabled: Bool = true, diarization: Bool = true) -> MeetingSession {
        let fake = FakeHerdr()
        let store = AIRecordStore(directory: root,
            makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        var configured = ResolvedConfig(config: KikigakiConfig(), home: root)
        configured.aiProfiles = [ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path,
            identifySpeakers: enabled), home: root)]
        configured.speakers = [.init(name: "タダシ"), .init(name: "田中")]
        return makeSession(root, config: configured, store: store, diarization: diarization)
    }
    private func makeSession(_ root: URL, config: ResolvedConfig, store: AIRecordStore, diarization: Bool) -> MeetingSession {
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"),
            config: config, aiStore: store, recordedSamples: 16000, diarizationEnabled: diarization)
        session.publishForTesting(tokens: [.init(text: "タダシです。", phraseId: 0, start: 0, end: 0.3),
                                          .init(text: "田中です。", phraseId: 1, start: 0.5, end: 0.8)],
            speakers: [0, 2], elapsed: 1)
        return session
    }
    private func submit(_ session: MeetingSession, trigger: AIParticipantContext.Trigger? = nil) async throws -> AIRequest {
        session.submitAI(question: trigger == nil ? "" : "議事録を更新", full: false, parent: nil,
            helper: URL(fileURLWithPath: "/bin/echo"), trigger: trigger)
        if let task = session.submissionTaskForTesting { await task.value }
        return try #require(session.aiRecord?.controller.conversation.questions.last?.request)
    }
    private func deliver(_ session: MeetingSession, request: AIRequest, slot: String = "A", name: String = "タダシ",
                         evidence: String? = nil, at: Date = Date()) throws -> AISpeakerEvent {
        let lines = TranscriptRenderer.lines(session.snapshot.utterances, names: session.snapshot.names,
                                              timeline: session.snapshot.timeline)
        let line = try #require(evidence ?? lines.first)
        let event = try AISpeakerEvent(request: request, slot: slot, name: name, evidence: line, recordedAt: at)
        let p = request.envelope.participant
        _ = try ReturnCommand(["speaker", "--session", p.sessionPath, "--request", request.id.uuidString,
            "--token", p.requestToken, "--slot", slot, "--name", name])
            .execute(input: { Data(line.utf8) }, environment: [:], now: at)
        return event
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func capture(_ name: String, view: NSView) throws {
        guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_SPEAKER_CAPTURE"] else { return }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }

    @Test(arguments: [nil, .scheduled] as [AIParticipantContext.Trigger?])
    func 共通の送信に固定情報と内蔵節が付き候補は参加者だけになる(_ trigger: AIParticipantContext.Trigger?) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root)
        let minutes = root.appendingPathComponent("minutes.md")
        try Data("---\nparticipants: [タダシ]\n---\n".utf8).write(to: minutes)
        try session.selectMinutes(minutes.path)
        let request = try await submit(session, trigger: trigger)
        #expect(request.envelope.participant.speakerIdentification == .init(unresolved: ["A", "C"], candidates: ["タダシ"]))
        #expect(request.envelope.participant.question.hasSuffix(SpeakerIdentificationPrompt.builtIn))
        #expect(request.displayQuestion == (trigger == nil ? "田中です。" : "議事録を更新"))
    }
    @Test(arguments: ["off", "undiarized", "confirmed", "named", "merged"])
    func 対象のない送信に内蔵節とキーを付けない(_ kind: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root, enabled: kind != "off", diarization: kind != "undiarized")
        if kind == "confirmed" { session.rename(slot: 0, to: ""); session.rename(slot: 2, to: "") }
        if kind == "named" { session.rename(slot: 0, to: "タダシ"); session.rename(slot: 2, to: "田中") }
        if kind == "merged" { session.setSpeakerMapping(source: 2, target: 0); session.rename(slot: 0, to: "タダシ") }
        let request = try await submit(session)
        #expect(request.envelope.participant.speakerIdentification == nil)
        #expect(!request.envelope.participant.question.contains(SpeakerIdentificationPrompt.builtIn))
    }
    @Test func 停止後の最後の一回にも同梱し現在の会議へ割り当てる() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root)
        defer { session.stopAISchedule() }
        try session.startAISchedule(options: .init(prompt: "議事録を更新"), helper: URL(fileURLWithPath: "/bin/echo"))
        await session.submissionTaskForTesting?.value
        let first = try #require(session.aiRecord?.controller.conversation.questions.first?.request)
        await session.stop()
        // 音声エンジンの無いfixtureなので、停止後の最終書き起こしを再現する。
        // 先の返事を待っている間の差分は、最後の送信へ回る。
        session.setScheduleTranscriptForTesting("タダシです。続けます。", speaker: 0)
        let p = first.envelope.participant
        _ = try ReturnCommand(["reply", "--session", p.sessionPath, "--request", first.id.uuidString,
                               "--token", p.requestToken, "--kind", "answered"])
            .execute(input: { Data("確認しました".utf8) }, environment: [:])
        session.aiRecord?.controller.scan()
        session.evaluateAISchedule()
        await session.submissionTaskForTesting?.value
        let questions = try #require(session.aiRecord?.controller.conversation.questions)
        #expect(questions.count == 2)
        let last = try #require(questions.last?.request)
        #expect(last.trigger == .scheduled && last.envelope.participant.speakerIdentification?.unresolved == ["A", "C"])
        _ = try deliver(session, request: last)
        session.aiRecord?.controller.scan()
        #expect(session.snapshot.state == .idle && session.snapshot.names.customName(for: 0) == "タダシ")
        #expect(session.snapshot.names.attributions[0] != nil)
    }
    @Test(arguments: ["human-default", "human-same", "named", "merged", "duplicate-name", "missing-time", "not-detected", "undiarized", "next-meeting"])
    func 取り込みの現在状態を機械判定して拒否する(_ kind: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root), request = try await submit(session)
        let controller = try #require(session.aiRecord?.controller)
        var logs: [String] = []; controller.speakerDiagnostic = { logs.append($0) }
        switch kind {
        case "human-default": session.rename(slot: 0, to: "")
        case "human-same": session.rename(slot: 0, to: "話者A")
        case "named": session.rename(slot: 0, to: "別名")
        case "merged": session.setSpeakerMapping(source: 0, target: 2)
        case "duplicate-name": session.rename(slot: 2, to: "タダシ")
        case "not-detected": controller.speakerContext = { (session.snapshot.names, [2], [:], ["[14:05:10] 行"]) }
        case "undiarized": controller.speakerContext = {
            var names = session.snapshot.names; names.diarizationEnabled = false
            return (names, [0, 2], [:], ["[14:05:10] 行"])
        }
        default: break
        }
        let event = try deliver(session, request: request, evidence: kind == "missing-time" ? "[23:59:59] ない発言" : nil)
        if kind == "next-meeting" { session.beginNextMeetingForTesting(recording: true) }
        controller.scan(); controller.scan()
        #expect(controller.conversation.speakerAssignments.isEmpty)
        #expect(controller.conversation.processedSpeakerIDs.contains(event.eventID))
        #expect(logs.count == 1)
        #expect(controller.warning == nil)
    }
    @Test func 同名の2枠は先勝ちで通常の返事と通知とタイムラインを増やさない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root), request = try await submit(session)
        let controller = try #require(session.aiRecord?.controller)
        var results = 0; controller.onResult = { _ in results += 1 }
        let now = Date()
        _ = try deliver(session, request: request, slot: "C", at: now)
        _ = try deliver(session, request: request, slot: "A", at: now.addingTimeInterval(1))
        let itemsBefore = AITimeline.items(conversation: controller.conversation, utterances: session.snapshot.utterances,
            timeline: session.snapshot.timeline, generation: { _ in 1 })
        controller.scan()
        #expect(session.snapshot.names.name(for: 2) == "タダシ" && session.snapshot.names.customName(for: 0) == nil)
        #expect(controller.conversation.speakerAssignments.map(\.slot) == ["C"])
        #expect(controller.conversation.questions[0].state == .submitted && results == 0)
        #expect(controller.progressReports.isEmpty)
        #expect(AITimeline.items(conversation: controller.conversation, utterances: session.snapshot.utterances,
            timeline: session.snapshot.timeline, generation: { _ in 1 }) == itemsBefore)
    }
    @Test(arguments: ["タダシ", "別名", ""])
    func 割当の点は全行に出て停止では消えず人の確認だけで消える(_ confirmation: String) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root), request = try await submit(session)
        let controller = try #require(session.aiRecord?.controller)
        _ = try deliver(session, request: request)
        controller.scan()
        let first = session.snapshot.utterances[0]
        let row = TranscriptRow()
        _ = row.update(first, names: session.snapshot.names, timeline: session.snapshot.timeline)
        row.frame = NSRect(x: 0, y: 0, width: 580, height: row.height(for: 580))
        row.layoutSubtreeIfNeeded()
        #expect(!row.attributionDot.isHidden && row.attributionDot.frame.size == NSSize(width: 5, height: 5))
        #expect(row.attributionDot.accessibilityLabel()?.hasPrefix("迅雷の推定 · ") == true)
        let later = TranscriptRow()
        _ = later.update(.init(speaker: 0, start: 10, end: 11, text: "続き"), names: session.snapshot.names, timeline: session.snapshot.timeline)
        #expect(!later.attributionDot.isHidden)
        await session.stop()
        #expect(session.snapshot.names.attributions[0] != nil)
        let state = try AIJSON.decode(AIConversation.self, from: AIFileStore(root: root).read(
            [".kikigaki-context", session.aiMeetingID.uuidString, "ai", "state.json"]))
        #expect(state.speakerNames?.attributions[0] != nil)
        let archive = try AIJSON.decode(MeetingArchive.self, from: AIFileStore(root: root).read(
            [".kikigaki-context", session.aiMeetingID.uuidString, "ai", "archive.json"]))
        #expect(archive.original.names.attributions[0] != nil)
        session.rename(slot: 0, to: confirmation)
        _ = row.update(first, names: session.snapshot.names, timeline: session.snapshot.timeline)
        #expect(row.attributionDot.isHidden && session.snapshot.names.humanTouched.contains(0))
        #expect(controller.conversation.speakerNames?.humanTouched.contains(0) == true)
        // 改名後の再走査でAIが元の名前へ戻してはならない。
        controller.scan()
        #expect(session.snapshot.names.attributions[0] == nil)
    }
    @Test func 二KiB近い複数行の根拠を全文表示し入力中も名前欄が動かない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root), request = try await submit(session)
        let lines = TranscriptRenderer.lines(session.snapshot.utterances, names: session.snapshot.names,
                                              timeline: session.snapshot.timeline)
        let firstLine = try #require(lines.first)
        let stamp = try #require(SpeakerEvidence.timestamps(in: firstLine).first)
        let suffix = "引用の終端です。"
        let continuation = "\n[\(stamp)] 話者A: 田中さんに呼ばれて応答し、タダシですと名乗っています。"
        var evidence = firstLine
        while (evidence + continuation + suffix).utf8.count <= AISpeakerEvent.evidenceBytes {
            evidence += continuation
        }
        evidence += suffix
        #expect(evidence.utf8.count > 1900 && evidence.utf8.count <= 2048)
        #expect(evidence.contains("\n"))
        _ = try deliver(session, request: request, evidence: evidence)
        session.aiRecord?.controller.scan()
        let attribution = try #require(session.snapshot.names.attributions[0])
        let defaults = MinutesTestDefaults()
        let controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults.value)
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        window.setContentSize(NSSize(width: 600, height: 460))
        controller.apply(session.snapshot); controller.show()
        defer { window.close() }
        let anchor = try #require(window.contentView)
        for nearTop in [false, true] {
            let popover = controller.makeSpeakerPopover(slot: 0)
            popover.present(relativeTo: NSRect(x: 200, y: nearTop ? 430 : 10, width: 22, height: 22), of: anchor)
            defer { popover.close() }
            let content = popover.contentView, label = popover.evidenceLabel
            let field = try #require(descendants(content).compactMap { $0 as? NSTextField }.first { $0.isEditable })
            let scroll = try #require(descendants(content).compactMap { $0 as? NSScrollView }.first)
            #expect(label.stringValue == attribution.detail)
            #expect(label.stringValue.hasSuffix(suffix + "」"))
            #expect(!label.stringValue.contains("\n"))
            #expect(label.toolTip == nil && label.accessibilityLabel() == attribution.tooltip)
            #expect(label.maximumNumberOfLines == 0 && label.lineBreakMode == .byWordWrapping)
            #expect(content.bounds.width == 340 && label.frame.width == 274)
            #expect(label.frame.height > 18 && content.bounds.height > 104 + scroll.frame.height + 22)
            #expect(label.frame.maxY < field.frame.minY && label.frame.minY > scroll.frame.maxY)
            let popoverWindow = try #require(field.window)
            let originalWindowFrame = popoverWindow.frame
            let originalContentSize = content.bounds.size
            let originalField = popoverWindow.convertToScreen(field.convert(field.bounds, to: nil))
            if !nearTop { try capture("speaker-ai-evidence-long", view: content) }
            for query in ["田", "候補にない名前"] {
                field.stringValue = query
                popover.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
                try await Task.sleep(for: .milliseconds(30))
                #expect(content.bounds.size == originalContentSize && popoverWindow.frame == originalWindowFrame)
                #expect(popoverWindow.convertToScreen(field.convert(field.bounds, to: nil)) == originalField)
                #expect(label.stringValue == attribution.detail)
            }
        }
    }

    @Test func 点と名前欄の下の根拠を本番ビューで撮影する() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root), request = try await submit(session)
        _ = try deliver(session, request: request)
        session.aiRecord?.controller.scan()
        let defaults = MinutesTestDefaults()
        let window = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults.value)
        window.window?.setFrameAutosaveName("")
        window.window?.setContentSize(NSSize(width: 600, height: 460))
        window.apply(session.snapshot); window.show()
        defer { window.window?.close() }
        try capture("speaker-ai-transcript", view: try #require(window.window?.contentView))
        let settings = SpeakerSettingsPopover(snapshot: session.snapshot)
        settings.contentView.layoutSubtreeIfNeeded()
        let dots = descendants(settings.contentView).compactMap { $0 as? SpeakerAttributionDot }.filter { !$0.isHidden }
        #expect(dots.count == 1 && dots[0].toolTip == session.snapshot.names.attributions[0]?.tooltip)
        try capture("speaker-ai-settings", view: settings.contentView)
        let popover = window.makeSpeakerPopover(slot: 0)
        let anchor = try #require(window.window?.contentView)
        popover.present(relativeTo: NSRect(x: 200, y: 200, width: 22, height: 22), of: anchor)
        defer { popover.close() }
        #expect(!popover.evidenceLabel.isHidden && popover.evidenceLabel.stringValue.hasPrefix("迅雷 "))
        #expect(popover.evidenceLabel.textColor == Washi.muted)
        let field = try #require(descendants(popover.contentView).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        #expect(popover.evidenceLabel.frame.maxY < field.frame.minY)
        try capture("speaker-ai-evidence", view: popover.contentView)
        session.rename(slot: 0, to: "タダシ")
        window.apply(session.snapshot)
        settings.update(snapshot: session.snapshot)
        #expect(descendants(settings.contentView).compactMap { $0 as? SpeakerAttributionDot }.allSatisfy { $0.isHidden })
        let confirmed = window.makeSpeakerPopover(slot: 0)
        #expect(confirmed.evidenceLabel.isHidden)
    }
}
}
