import AppKit
import QuartzCore
import Foundation
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import Kikigaki
@testable import KikigakiCLI

private actor CoinAvatarLoadGate {
    private var opened = false
    private(set) var requestCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        requestCount += 1
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

extension AppKitTests {
@Suite(.serialized) @MainActor struct SpeakerIdentificationAppTests {
    private func session(_ root: URL, enabled: Bool = true, diarization: Bool = true, avatar: String? = nil) -> MeetingSession {
        let fake = FakeHerdr()
        let store = AIRecordStore(directory: root,
            makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        var configured = ResolvedConfig(config: KikigakiConfig(), home: root)
        configured.aiProfiles = [ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path,
            identifySpeakers: enabled), home: root)]
        configured.speakers = [.init(name: "タダシ", avatar: avatar), .init(name: "田中")]
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
    private func captureCoin(_ name: String, window: NSWindow) async throws {
        guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_SPEAKER_CAPTURE"] else { return }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        // cacheDisplayは3Dレイヤーの合成を再現しないため、描画サーバーの出力を撮る。
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(100))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), output + "/" + name + ".png"]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
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
        #expect(session.snapshot.speakerReveals.isEmpty)
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

    @Test(arguments: ["recording", "paused", "human", "stopped", "next-meeting"])
    func その場で取り込んだAI割当だけに演出イベントを付ける(_ kind: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root), request = try await submit(session)
        let controller = try #require(session.aiRecord?.controller)
        if kind == "paused" { session.togglePause() }
        if kind == "human" { session.rename(slot: 0, to: "タダシ") }
        if kind == "stopped" {
            await session.stop()
            // 音声エンジンの無いfixtureでも、停止後の最終本文は割当の根拠として残す。
            session.setScheduleTranscriptForTesting("タダシです。", speaker: 0)
        }
        _ = try deliver(session, request: request)
        if kind == "next-meeting" { session.beginNextMeetingForTesting(recording: true) }
        controller.scan()
        let reveals = session.snapshot.speakerReveals
        if kind == "recording" || kind == "paused" {
            #expect(reveals.count == 1)
            #expect(reveals.first?.message == "話者A → タダシ(迅雷の推定)")
            controller.scan()
            #expect(session.snapshot.speakerReveals == reveals)
        } else {
            #expect(reveals.isEmpty)
            if kind == "stopped" { #expect(session.snapshot.names.name(for: 0) == "タダシ") }
        }
    }

    @Test(arguments: [false, true])
    func 複数枠の帯を順番に出し見えている全行だけ回す(reduceMotion: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root)
        session.publishForTesting(tokens: [.init(text: "タダシです。今日はよろしくお願いします。", phraseId: 0, start: 0, end: 0.3),
            .init(text: "田中です。進めましょう。", phraseId: 1, start: 0.5, end: 0.8),
            .init(text: "では、会議を始めます。", phraseId: 2, start: 1.2, end: 1.5)],
            speakers: [0, 2, 0], elapsed: 2, frozenCount: 3)
        let request = try await submit(session)
        let defaults = MinutesTestDefaults()
        var reduced = reduceMotion
        let window = TranscriptWindowController(shouldReduceMotion: { reduced },
            minutesDefaults: defaults.value, textDefaults: defaults.value)
        window.window?.setFrameAutosaveName("")
        window.window?.setContentSize(NSSize(width: 600, height: 680))
        window.apply(session.snapshot); window.show()
        defer { session.onChange = nil; window.window?.close() }
        session.onChange = { window.apply($0) }
        _ = try deliver(session, request: request)
        _ = try deliver(session, request: request, slot: "C", name: "田中")
        session.aiRecord?.controller.scan()
        let banner = window.speakerRevealBanner
        #expect(window.rows.values.allSatisfy { $0.speakerRevealCoin.isHidden == reduceMotion })
        if !reduceMotion {
            #expect(banner.current == nil && banner.isHidden)
            for row in window.rows.values {
                #expect(row.activeSpeakerRevealID != nil)
            }
            // 同じsnapshotで回転や停止待ちをやり直さない。
            window.apply(session.snapshot)
            #expect(banner.isHidden)
            try await Task.sleep(for: .seconds(SpeakerRevealCoin.duration + 0.15))
            #expect(window.rows.values.allSatisfy { $0.speakerRevealCoin.isHidden })
        }
        #expect(banner.current?.message == "話者A → タダシ(迅雷の推定)")
        #expect(!banner.isHidden && banner.hitTest(NSPoint(x: 30, y: 10)) == nil)
        #expect(window.transcriptDocument.anchor().atBottom)
        #expect(window.rows.count == 3 && window.rows.values.allSatisfy { !$0.attributionDot.isHidden })
        #expect(banner.label.textColor == Washi.paper)
        #expect(banner.bubble.layer?.backgroundColor == Washi.ai.background.cgColor)
        #expect(banner.bubble.layer?.cornerRadius == 10)
        #expect(abs(banner.bubble.frame.midX - banner.bounds.midX) < 1)
        for row in window.rows.values {
            let body = try #require(row.content.subviews.compactMap { $0 as? NSTextField }.first { $0.isSelectable })
            #expect(row.speakerRevealCoin.frame.maxX <= body.frame.minX)
        }
        if reduceMotion {
            #expect(banner.bubble.layer?.animationKeys()?.isEmpty ?? true)
            try capture("speaker-reveal-reduced-motion", view: try #require(window.window?.contentView))
        }
        // 再描画は同じ帯を追加せず、1件目の寿命を延ばさない。
        window.apply(session.snapshot)
        // 描画に掛かる時間で狭いフェード期間を踏み外さないよう、状態を待つ。
        let fadeDeadline = Date().addingTimeInterval(4)
        while banner.current?.slot == 0, Date() < fadeDeadline {
            if !reduceMotion, banner.bubble.layer?.opacity == 0 { break }
            if reduceMotion { #expect(banner.bubble.layer?.opacity == 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
        if reduceMotion {
            #expect(banner.bubble.layer?.opacity == 1)
        } else {
            #expect(banner.current?.slot == 0)
            #expect(banner.bubble.layer?.opacity == 0)
            #expect(banner.bubble.layer?.animation(forKey: "speakerReveal") != nil)
            // 出る途中で視差効果を減らしたら、動きを終え、次の帯を即時に出す。
            reduced = true
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            #expect(window.rows.values.allSatisfy { $0.speakerRevealCoin.isHidden })
            #expect(banner.current?.slot == 2 && (banner.bubble.layer?.animationKeys()?.isEmpty ?? true))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(banner.current?.message == "話者C → 田中(迅雷の推定)")
        try capture(reduceMotion ? "speaker-reveal-second-reduced" : "speaker-reveal-second-banner",
            view: try #require(window.window?.contentView))
        try await Task.sleep(for: .milliseconds(3100))
        #expect(banner.current == nil && banner.isHidden)
        #expect(window.transcriptDocument.anchor().atBottom)
    }

    @Test func コインは描画とレイアウトを繰り返さず確定面で止まる() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root), request = try await submit(session)
        let defaults = MinutesTestDefaults()
        var reduced = false
        let controller = TranscriptWindowController(shouldReduceMotion: { reduced },
            minutesDefaults: defaults.value, textDefaults: defaults.value)
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        window.setContentSize(NSSize(width: 600, height: 460))
        controller.apply(session.snapshot); controller.show()
        defer { window.close() }
        _ = try deliver(session, request: request)
        session.aiRecord?.controller.scan()
        controller.apply(session.snapshot)
        let row = try #require(controller.rows.first { $0.key.start == 0 }?.value)
        #expect(!row.speakerRevealCoin.isHidden)
        let spin = try #require(row.speakerRevealCoin.rotor.animation(forKey: "speakerCoin") as? CAKeyframeAnimation)
        #expect(spin.duration == 5)
        #expect((spin.values?.last as? Double) == 13 * .pi)
        #expect(controller.speakerRevealBanner.isHidden)
        let labels = row.content.subviews.compactMap { $0 as? NSTextField }
        let oldName = try #require(labels.first { $0.stringValue == "話者A" })
        let newName = try #require(labels.first { $0.stringValue == "タダシ" })
        #expect(!oldName.isHidden && oldName.layer?.opacity == 1)
        #expect(newName.layer?.opacity == 0)
        let startedAt = CACurrentMediaTime()
        try await Task.sleep(for: .milliseconds(150))
        let before = (row.drawCount, row.layoutCount, row.avatarDrawCount)
        let firstTransform = try #require(row.speakerRevealCoin.rotor.presentation()?.transform)
        // 5秒の全区間を実時間で観測。撮影もCAのpresentation layerを合成した画面で行う。
        for (name, time) in [("0.5s", 0.5), ("2.5s", 2.5), ("4.5s", 4.5), ("4.9s", 4.9)] {
            let remaining = time - (CACurrentMediaTime() - startedAt)
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            let after = (row.drawCount, row.layoutCount, row.avatarDrawCount)
            let transform = try #require(row.speakerRevealCoin.rotor.presentation()?.transform)
            #expect(!CATransform3DEqualToTransform(firstTransform, transform))
            #expect(before.0 == after.0 && before.1 == after.1 && before.2 == after.2)
            #expect(!row.speakerRevealCoin.isHidden && controller.speakerRevealBanner.isHidden)
            #expect(!oldName.isHidden && oldName.layer?.opacity == 1 && newName.layer?.opacity == 0)
            print("speaker-coin \(name): row.draw=\(after.0 - before.0), row.layout=\(after.1 - before.1), avatar.draw=\(after.2 - before.2)")
            if time < 4.9 { try await captureCoin("speaker-coin-" + name, window: window) }
        }
        try await Task.sleep(for: .milliseconds(250))
        #expect(row.speakerRevealCoin.isHidden)
        #expect(row.speakerRevealCoin.rotor.animationKeys()?.isEmpty ?? true)
        #expect(newName.layer?.opacity == 1)
        #expect(controller.speakerRevealBanner.current?.name == "タダシ")
        try await captureCoin("speaker-coin-stopped", window: window)
        // CAが実際に合成した角度も確認する。等速区間と減速区間の代表点を読む。
        row.revealSpeaker(try #require(session.snapshot.speakerReveals.first), animated: true)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(150))
        for (time, turns) in [(0.1, 0.25), (0.2, 0.5), (1.5, 3.75), (2.5, 317.0 / 56),
                              (3.5, 179.0 / 28), (4.5, 545.0 / 84), (4.9, 6.5 - 0.01 / 21)] {
            row.freezeSpeakerRevealForCapture(at: time)
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(30))
            let transform = try #require(row.speakerRevealCoin.rotor.presentation()?.transform)
            #expect(abs(transform.m11 - cos(turns * 2 * .pi)) < 0.02, "\(time)秒のcos")
            #expect(abs(transform.m13 + sin(turns * 2 * .pi)) < 0.02, "\(time)秒のsin")
        }
        reduced = true
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(row.speakerRevealCoin.isHidden)
        #expect(row.speakerRevealCoin.rotor.animationKeys()?.isEmpty ?? true)
    }

    @Test(arguments: [false, true])
    func 台帳画像を先読みし遅着しても裏面だけを一度差し替える(late: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        // 青い顔はイニシャルの丸と画素でも撮影でも区別できる。外部の画像へは通信しない。
        let file = root.appendingPathComponent("avatar.tiff")
        let fixture = NSImage(size: NSSize(width: 64, height: 64), flipped: true) { rect in
            NSColor(deviceRed: 0.1, green: 0.25, blue: 0.9, alpha: 1).setFill()
            rect.fill()
            NSColor.white.setFill()
            for x in [18, 42] { NSBezierPath(ovalIn: NSRect(x: x, y: 18, width: 7, height: 9)).fill() }
            NSBezierPath(roundedRect: NSRect(x: 20, y: 44, width: 26, height: 6), xRadius: 3, yRadius: 3).fill()
            return true
        }
        try #require(fixture.tiffRepresentation).write(to: file)
        let source = "https://avatar.test/speaker.webp"
        let gate = CoinAvatarLoadGate()
        if !late { await gate.open() }
        let store = AvatarStore(cacheDirectory: root.appendingPathComponent("cache"), loadImageData: { _, directory in
            await gate.wait()
            return try await AvatarStore.load(file.path, cacheDirectory: directory)
        })
        let session = session(root, avatar: source), request = try await submit(session)
        let defaults = MinutesTestDefaults()
        let controller = TranscriptWindowController(shouldReduceMotion: { false },
            minutesDefaults: defaults.value, textDefaults: defaults.value, avatars: store)
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        window.setContentSize(NSSize(width: 600, height: 460))
        controller.apply(session.snapshot); controller.show()
        defer { window.close() }
        // この時点の行は仮名だけ。問い合わせで取得を始めず、台帳の先読みそのものを検証する。
        let preloadDeadline = Date().addingTimeInterval(2)
        while await gate.requestCount == 0, Date() < preloadDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.requestCount == 1)
        func waitForImage() async throws {
            let deadline = Date().addingTimeInterval(2)
            while store.image(for: source) == nil, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(store.image(for: source) != nil)
        }
        if !late { try await waitForImage() }
        _ = try deliver(session, request: request)
        session.aiRecord?.controller.scan()
        controller.apply(session.snapshot)
        let row = try #require(controller.rows.first { $0.key.start == 0 }?.value)
        let coin = row.speakerRevealCoin
        func backIsImage() throws -> Bool {
            let bitmap = NSBitmapImageRep(cgImage: try #require(coin.backContentsForTesting))
            let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            return color.blueComponent > 0.8 && color.redComponent < 0.3 && color.alphaComponent > 0.9
        }
        #expect(try backIsImage() == !late)
        let initialSnapshots = coin.backSnapshotCount
        let startedAt = CACurrentMediaTime()
        try await Task.sleep(for: .milliseconds(150))
        let before = (row.drawCount, row.layoutCount, row.avatarDrawCount)
        let originalSpin = try #require(coin.rotor.animation(forKey: "speakerCoin") as? CAKeyframeAnimation)
        for (name, time) in [("0.5s", 0.5), ("2.5s", 2.5), ("4.5s", 4.5), ("4.9s", 4.9)] {
            let remaining = time - (CACurrentMediaTime() - startedAt)
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            if late && time == 0.5 {
                let oldTransform = try #require(coin.rotor.presentation()?.transform)
                let arrivalStart = CACurrentMediaTime()
                await gate.open()
                try await waitForImage()
                #expect(try backIsImage())
                #expect(coin.backSnapshotCount == initialSnapshots + 1)
                let spin = try #require(coin.rotor.animation(forKey: "speakerCoin") as? CAKeyframeAnimation)
                #expect(spin.beginTime == originalSpin.beginTime && spin.duration == originalSpin.duration)
                #expect(spin.values as? [Double] == originalSpin.values as? [Double])
                CATransaction.flush()
                try await Task.sleep(for: .milliseconds(30))
                let newTransform = try #require(coin.rotor.presentation()?.transform)
                #expect(!CATransform3DEqualToTransform(oldTransform, newTransform))
                // beginTimeが既定値0のままでも、等速区間の角度の連続性で再始動を検出する。
                let phaseBefore = atan2(Double(-oldTransform.m13), Double(oldTransform.m11))
                let phaseAfter = atan2(Double(-newTransform.m13), Double(newTransform.m11))
                let expectedAdvance = (CACurrentMediaTime() - arrivalStart) * 2.5 * 2 * Double.pi
                let phaseError = phaseAfter - phaseBefore - expectedAdvance
                #expect(abs(atan2(sin(phaseError), cos(phaseError))) < 0.35)
                // 無関係な画像の通知で同じ画像を描き直さない。
                store.onChange?(); store.onChange?()
                #expect(coin.backSnapshotCount == initialSnapshots + 1)
            }
            let after = (row.drawCount, row.layoutCount, row.avatarDrawCount)
            #expect(after.0 == before.0 && after.1 == before.1)
            #expect(after.2 - before.2 == (late ? 1 : 0))
            #expect(!coin.isHidden && controller.speakerRevealBanner.isHidden)
            print("speaker-coin-avatar late=\(late) \(name): row.draw=\(after.0 - before.0), row.layout=\(after.1 - before.1), avatar.draw=\(after.2 - before.2)")
        }
        try await Task.sleep(for: .milliseconds(250))
        #expect(coin.isHidden && controller.speakerRevealBanner.current?.name == "タダシ")
        #expect(coin.backSnapshotCount == initialSnapshots + (late ? 1 : 0))
        #expect(row.activeSpeakerRevealID == nil)
        if !late && ProcessInfo.processInfo.environment["KIKIGAKI_SPEAKER_CAPTURE"] != nil {
            // 負荷は上で実時間計測した。撮影だけはCAの時刻を固定し、指定した秒の面を正確に写す。
            let reveal = try #require(session.snapshot.speakerReveals.first)
            controller.speakerRevealBanner.clear()
            row.revealSpeaker(reveal, animated: true)
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(150))
            for (name, time, turns) in [("0.5s", 0.5, 1.25), ("2.5s", 2.5, 317.0 / 56), ("4.5s", 4.5, 545.0 / 84)] {
                row.freezeSpeakerRevealForCapture(at: time)
                CATransaction.flush()
                try await Task.sleep(for: .milliseconds(30))
                let transform = try #require(coin.rotor.presentation()?.transform)
                #expect(abs(transform.m11 - cos(turns * 2 * .pi)) < 0.02)
                #expect(abs(transform.m13 + sin(turns * 2 * .pi)) < 0.02)
                try await captureCoin("speaker-coin-avatar-" + name, window: window)
            }
            row.finishSpeakerReveal()
            controller.speakerRevealBanner.enqueue([reveal], reduceMotion: false)
            try await Task.sleep(for: .milliseconds(600))
            try await captureCoin("speaker-coin-avatar-stopped", window: window)
        }
    }

    @Test func 画面外の話者も帯で知らせ初回の旧会議表示と回収では再演しない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root), request = try await submit(session)
        let defaults = MinutesTestDefaults()
        let window = TranscriptWindowController(shouldReduceMotion: { false },
            minutesDefaults: defaults.value, textDefaults: defaults.value)
        window.window?.setFrameAutosaveName("")
        window.window?.setContentSize(NSSize(width: 420, height: 460))
        var snapshot = session.snapshot
        let unrecovered = try #require(session.aiRecord?.controller.conversation)
        let lines = TranscriptRenderer.lines(snapshot.utterances, names: snapshot.names, timeline: snapshot.timeline)
        snapshot.utterances += (0..<30).map { .init(speaker: 2, start: Double($0 + 10), end: Double($0 + 11), text: "画面外の話者を確かめる発言です。") }
        window.apply(snapshot); window.show()
        defer { window.window?.close() }
        _ = try deliver(session, request: request)
        session.aiRecord?.controller.scan()
        snapshot.names = session.snapshot.names; snapshot.speakerReveals = session.snapshot.speakerReveals
        window.apply(snapshot)
        #expect(window.speakerRevealBanner.isHidden)
        try await Task.sleep(for: .seconds(SpeakerRevealCoin.duration + 0.15))
        #expect(window.speakerRevealBanner.current?.slot == 0)
        #expect(window.rows.values.allSatisfy { $0.speakerRevealCoin.isHidden })
        try capture("speaker-reveal-offscreen-banner", view: try #require(window.window?.contentView))
        window.transcriptDocument.scroll(NSPoint(x: 0, y: 0)); window.scrolled()
        #expect(window.rows.values.allSatisfy { $0.speakerRevealCoin.isHidden })
        try capture("speaker-reveal-scrolled-without-replay", view: try #require(window.window?.contentView))
        window.increaseTextSize(nil)
        #expect(window.speakerRevealBanner.label.font?.pointSize == 12)

        // 旧会議の表示は、たとえ受信イベントの値が残っていても再演しない。
        var historical = snapshot
        historical.timeline = MeetingTimeline(startedAt: snapshot.timeline.startedAt.addingTimeInterval(-60))
        historical.state = .idle
        window.apply(historical)
        #expect(window.speakerRevealBanner.isHidden)
        historical.state = .recording
        historical.ai?.readOnly = true
        historical.speakerReveals = []
        window.apply(historical)
        historical.speakerReveals = snapshot.speakerReveals
        window.apply(historical)
        #expect(window.speakerRevealBanner.isHidden)

        // 再起動回収用controllerには、画面が文脈を与えても演出イベントを出させない。
        let minutes = MinutesStore(meetingID: unrecovered.meetingID, outputDirectory: root)
        let fake = FakeHerdr()
        let recovered = try AIConversationController(meetingID: unrecovered.meetingID, outputDirectory: root,
            herdr: AIHerdr(run: { try await fake.run($0, $1) }), recovered: unrecovered, minutes: minutes)
        var notifications = 0
        recovered.speakerContext = { (SpeakerNames(), [0, 2], [:], lines) }
        recovered.onSpeakersIdentified = { _, _ in notifications += 1 }
        recovered.scan()
        #expect(recovered.conversation.speakerAssignments.count == 1)
        #expect(notifications == 0)
    }

    @Test(arguments: ["rename", "confirm", "stop", "reduce-motion"])
    func 回転中の変更で古い名前と帯を持ち越さない(_ change: String) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root), request = try await submit(session)
        let defaults = MinutesTestDefaults()
        var reduced = false
        let controller = TranscriptWindowController(shouldReduceMotion: { reduced },
            minutesDefaults: defaults.value, textDefaults: defaults.value)
        controller.window?.setFrameAutosaveName("")
        controller.apply(session.snapshot); controller.show()
        defer { controller.window?.close() }
        _ = try deliver(session, request: request)
        session.aiRecord?.controller.scan()
        controller.apply(session.snapshot)
        let row = try #require(controller.rows.first { $0.key.start == 0 }?.value)
        #expect(!row.speakerRevealCoin.isHidden && controller.speakerRevealBanner.isHidden)
        try await Task.sleep(for: .milliseconds(200))
        switch change {
        case "rename": session.rename(slot: 0, to: "別の名前")
        case "confirm": session.rename(slot: 0, to: "タダシ")
        case "stop": await session.stop()
        default:
            reduced = true
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }
        controller.apply(session.snapshot)
        #expect(row.speakerRevealCoin.isHidden && row.activeSpeakerRevealID == nil)
        let label = try #require(row.content.subviews.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == (change == "rename" ? "別の名前" : "タダシ") && !$0.isHidden })
        #expect(label.layer?.opacity == 1)
        #expect(controller.speakerRevealBanner.isHidden == (change != "reduce-motion"))
        try await Task.sleep(for: .seconds(SpeakerRevealCoin.duration + 0.15))
        #expect(controller.speakerRevealBanner.isHidden)
    }
}
}
