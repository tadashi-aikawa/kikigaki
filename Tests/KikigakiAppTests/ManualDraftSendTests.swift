import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

extension AppKitTests {
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct ManualDraftSendTests {
    private func session(_ root: URL, fake: FakeHerdr) -> MeetingSession {
        var config = ResolvedConfig(config: KikigakiConfig(), home: root)
        config.aiProfiles = ["議事録", "スライド"].enumerated().map {
            ResolvedAIConfig(config: AIConfig(name: $0.element, command: "/bin/echo", cwd: root.path,
                initialPrompt: $0.element + "を更新"), home: root, slot: $0.offset + 1)
        }
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"),
            config: config, aiStore: store, recordedSamples: 16_000)
        session.automaticHelper = URL(fileURLWithPath: "/bin/echo")
        session.setMeetingManualDestination(slot: 2)
        session.setScheduleTranscriptForTesting("会議を始めます")
        session.playAutoSendSound = { _ in }
        return session
    }

    @Test func ボタンはシートを開かず会議の手動宛先と下書きを本番経路へ渡す() async throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), session = session(root, fake: fake)
        session.selectAIProfile(slot: 1)
        session.updateManualDraft("スライドの下書き", slot: 2)
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        var notifications: [VoiceCueFeedback] = []; session.notifyVoiceCue = { notifications.append($0) }
        let suite = "ManualDraftSendTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults, textDefaults: defaults)
        window.window?.setFrameAutosaveName("")
        defer { window.window?.orderOut(nil) }
        var openedSheet = false, calls = 0
        window.onAskAI = { _ in openedSheet = true }
        window.onSendManualDraft = { calls += 1; session.sendManualDraft() }
        window.apply(session.snapshot)
        let button = window.compactFooter.manualSend
        #expect(button.isEnabled && button.toolTip == "下書きで今すぐ送る")
        #expect(button.sendAction(try #require(button.action), to: button.target))
        #expect(calls == 1 && !openedSheet && sounds == [true])
        await session.submissionTaskForTesting(slot: 2)?.value
        let request = try #require(session.aiRecord?.controller.conversation.questions.first?.request)
        #expect(request.envelope.participant.profileSlot == 2)
        #expect(request.envelope.participant.question == "スライドの下書き" && request.trigger == nil)
        #expect(session.meetingManualAI?.slot == 2 && notifications.isEmpty && sounds == [true])
        #expect(await fake.commands.filter { $0.prefix(2) == ["agent", "prompt"] }.count == 1)
    }

    @Test(arguments: [false, true])
    func クリックは水位と10秒を動かさず返事待ちへ何度でも追記できる(voiceFirst: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root, fake: FakeHerdr())
        var notifications: [VoiceCueFeedback] = []; session.notifyVoiceCue = { notifications.append($0) }
        func voice(start: Double, end: Double) {
            session.publishForTesting(tokens: [.init(text: "アバンティ", phraseId: -1, start: start, end: end)],
                speakers: [0], elapsed: end, finalCount: 1, accurateFinalCount: 0)
        }
        if voiceFirst { voice(start: 0, end: 1) }
        else { #expect(session.sendManualDraft()) }
        await session.submissionTaskForTesting(slot: 2)?.value
        #expect(session.manualDraftSendState == .ready(appendix: true))
        #expect(session.snapshot.manualDraftSendState.toolTip.contains("追記"))
        #expect(session.sendManualDraft())
        await session.submissionTaskForTesting(slot: 2)?.value
        if voiceFirst {
            #expect(session.sendManualDraft())
            await session.submissionTaskForTesting(slot: 2)?.value
            // クリックで声の水位や時計を変えず、その後の合図は従来どおり無視する。
            voice(start: 0.5, end: 1)
            voice(start: 2, end: 3)
        } else {
            // クリックだけでは水位も10秒の待ちも発生しない。
            voice(start: 0, end: 1)
            await session.submissionTaskForTesting(slot: 2)?.value
        }
        let question = try #require(session.aiRecord?.controller.conversation.questions.first)
        #expect(question.appendices.count == 2)
        #expect(session.aiRecord?.controller.conversation.questions.count == 1)
        #expect(notifications.count == 1)
    }

    @Test func 指定しないと準備中と切断と停止は無効にして一時停止中は送れる() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), session = session(root, fake: fake)
        #expect(session.snapshot.manualDraftSendState.canSend)
        session.setMeetingManualDestination(slot: nil)
        #expect(session.snapshot.manualDraftSendState == .unavailable("手動宛先を指定してください"))
        #expect(!session.sendManualDraft())
        session.setMeetingManualDestination(slot: 2)
        session.automaticHelper = nil
        #expect(session.snapshot.manualDraftSendState == .unavailable("送信の設定がありません"))
        session.automaticHelper = URL(fileURLWithPath: "/bin/echo")
        session.togglePause()
        #expect(session.snapshot.state == .paused && session.snapshot.manualDraftSendState.canSend)
        #expect(session.sendManualDraft())
        #expect(session.snapshot.manualDraftSendState == .unavailable("送信の準備中です"))
        await session.submissionTaskForTesting(slot: 2)?.value
        await fake.setStatuses(["missing"])
        try? await session.aiRecord?.controller.refreshConnection(slot: 2)
        #expect(!session.manualDraftSendState.canSend)
        #expect(session.manualDraftSendState.toolTip.contains("接続先"))
        await session.stop()
        #expect(!session.snapshot.manualDraftSendState.canSend)
    }

    @Test func 別宛先の準備中でも手動宛先への送信を妨げない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root, fake: FakeHerdr())
        let other = try #require(session.meetingAIProfiles.first)
        session.submitAI(question: "別宛先", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"), profile: other)
        #expect(session.manualDraftSendState.canSend)
        #expect(session.sendManualDraft())
        await session.submissionTaskForTesting(slot: 1)?.value
        await session.submissionTaskForTesting(slot: 2)?.value
        #expect(session.aiRecord?.controller.conversation.questions.count == 2)
    }

    @Test func AI設定や会議の保存先がないフッターは送れない() throws {
        _ = NSApplication.shared
        let footer = AICompactFooter(visibility: { false })
        var snapshot = SessionSnapshot(state: .recording)
        footer.update(snapshot, reduceMotion: true)
        #expect(footer.destinations.isHidden && !footer.manualSend.isEnabled)
        snapshot.ai = AIViewState()
        snapshot.manualDestination = .init(slot: 1, name: "迅雷")
        snapshot.manualDraftSendState = .ready(appendix: false)
        footer.update(snapshot, reduceMotion: true)
        #expect(!footer.manualSend.isEnabled)
        snapshot.markdownURL = URL(fileURLWithPath: "/tmp/meeting.md")
        footer.update(snapshot, reduceMotion: true)
        #expect(footer.manualSend.isEnabled)
        snapshot.manualDraftSendState = .unavailable("送信の準備中です")
        footer.update(snapshot, reduceMotion: true)
        #expect(!footer.manualSend.isEnabled && footer.manualSend.toolTip == "送信の準備中です")
        #expect(footer.manualSend.accessibilityLabel() == "送信の準備中です")
    }

    @Test func グローバルキーは手動宛先へ下書きを送りキーの表記で通知する() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), session = session(root, fake: fake)
        session.updateManualDraft("スライドの下書き", slot: 2)
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        var cues: [VoiceCueFeedback] = []; session.notifyVoiceCue = { cues.append($0) }
        var keys: [VoiceCueFeedback] = []; session.notifyHotkey = { keys.append($0) }
        let hotkey = try #require(GlobalHotkey("cmd+shift+space"))
        #expect(session.sendManualDraft(trigger: .hotkey(hotkey)))
        await session.submissionTaskForTesting(slot: 2)?.value
        let request = try #require(session.aiRecord?.controller.conversation.questions.first?.request)
        #expect(request.envelope.participant.profileSlot == 2)
        #expect(request.envelope.participant.question == "スライドの下書き" && request.trigger == nil)
        #expect(sounds == [true] && cues.isEmpty)
        #expect(keys == [.accepted(destination: "スライド", phrase: "⇧⌘Space", appendix: false)])
    }

    @Test func グローバルキーは指定しないと停止後も低い音と理由で断る() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root, fake: FakeHerdr())
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        var keys: [VoiceCueFeedback] = []; session.notifyHotkey = { keys.append($0) }
        let hotkey = try #require(GlobalHotkey("f19"))
        session.setMeetingManualDestination(slot: nil)
        #expect(!session.sendManualDraft(trigger: .hotkey(hotkey)))
        session.setMeetingManualDestination(slot: 2)
        await session.stop()
        #expect(!session.sendManualDraft(trigger: .hotkey(hotkey)))
        #expect(sounds == [false, false])
        #expect(keys == [.failed(destination: nil, reason: "手動宛先を指定してください"),
                         .failed(destination: nil, reason: "録音中・一時停止中だけ送れます")])
        #expect(session.aiRecord?.controller.conversation.questions.isEmpty != false)
    }

    @Test func クリックの受付後に失敗しても音だけで知らせる() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var config = ResolvedConfig(config: KikigakiConfig(), home: root)
        config.ai = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path), home: root)
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { _, _ in throw CancellationError() }) })
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
            aiStore: store, recordedSamples: 16_000)
        session.automaticHelper = URL(fileURLWithPath: "/bin/echo")
        session.setScheduleTranscriptForTesting("会議を始めます")
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        var notifications: [VoiceCueFeedback] = []; session.notifyVoiceCue = { notifications.append($0) }
        #expect(session.sendManualDraft() && sounds == [true])
        await session.submissionTaskForTesting?.value
        #expect(sounds == [true, false] && notifications.isEmpty)
    }
}
}
