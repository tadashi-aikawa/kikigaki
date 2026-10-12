import AppKit
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import Kikigaki

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct ManualDestinationSwitchTests {
    @MainActor private struct Fixture {
        let session: MeetingSession
        let app: AppDelegate
        let window: TranscriptWindowController
        let defaults: MinutesTestDefaults

        func closeSheet() {
            app.aiSheet?.close()
            app.dismissAISheet()
        }
        func close() { closeSheet(); window.window?.orderOut(nil) }
    }

    private func fixture(_ root: URL, fake: FakeHerdr, initialSlot: Int? = 1, failConnection: Bool = false) -> Fixture {
        _ = NSApplication.shared
        var config = ResolvedConfig(config: KikigakiConfig(), home: root)
        config.aiProfiles = ["議事録", "スライド"].enumerated().map {
            ResolvedAIConfig(config: AIConfig(name: $0.element, command: "/bin/echo", cwd: root.path,
                                              initialPrompt: $0.element + "を更新"), home: root, slot: $0.offset + 1)
        }
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { args, timeout in
            if failConnection && args.prefix(2) == ["workspace", "create"] { throw AIHerdrError.notReady }
            return try await fake.run(args, timeout)
        }) })
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
                                     aiStore: store, recordedSamples: 16_000)
        session.automaticHelper = URL(fileURLWithPath: "/bin/echo")
        session.playAutoSendSound = { _ in }
        session.setMeetingManualDestination(slot: initialSlot)
        session.setScheduleTranscriptForTesting("会議を始めます")
        let defaults = MinutesTestDefaults()
        defaults.value.set(initialSlot == nil ? "" : "議事録", forKey: StartSheet.manualDefaultsKey)
        let window = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults.value,
                                               textDefaults: defaults.value)
        window.window?.setFrameAutosaveName("")
        window.window?.setFrameOrigin(NSPoint(x: 20000, y: 20000))
        let app = AppDelegate(testingSession: session, config: config, window: window,
                              aiHelper: URL(fileURLWithPath: "/bin/echo"))
        return Fixture(session: session, app: app, window: window, defaults: defaults)
    }

    private func selectAndSend(_ fixture: Fixture, slot: Int, text: String) throws -> Task<Void, Never> {
        fixture.app.showAISheet(parent: nil)
        let sheet = try #require(fixture.app.aiSheet)
        sheet.onDestination?(slot)
        #expect(sheet.owningSlot == slot)
        #expect(fixture.session.meetingManualAI?.slot != slot)
        sheet.onSubmit?(text, false)
        return try #require(fixture.session.submissionTaskForTesting(slot: slot))
    }

    private func receive(_ session: MeetingSession, root: URL, request: AIRequest,
                         kind: AIReceiveEvent.Kind = .answered) throws {
        let event = try AIReceiveEvent(request: request, kind: kind, recordedAt: Date(), body: "確認しました",
                                       reason: kind == .needsInput ? "clarification" : kind == .failed ? "work_failed" : nil)
        try AIFileStore(root: root).write(AIJSON.encode(event), to: [".kikigaki-context", session.aiMeetingID.uuidString,
            "ai", "inbox", event.filename], replacing: false)
        session.aiRecord?.controller.scan()
    }

    @Test func 返事待ちの別宛先へシートで追記しても合図の宛先は切り替わらない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let f = fixture(root, fake: FakeHerdr()); defer { f.close() }
        let config = f.session.meetingAIProfiles[1]
        f.session.submitAI(question: "スライドを更新", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"), profile: config)
        await f.session.submissionTaskForTesting(slot: 2)?.value
        f.app.showAISheet(parent: nil)
        let sheet = try #require(f.app.aiSheet)
        sheet.onDestination?(2)
        #expect(sheet.sendButton.title == "追記して送る")
        sheet.onSubmit?("見出しも追加", false)
        await f.session.submissionTaskForTesting(slot: 2)?.value
        #expect(f.session.meetingManualAI?.slot == 1)
        #expect(f.session.aiRecord?.controller.conversation.questions.count == 1)
        #expect(f.session.aiRecord?.controller.conversation.questions[0].appendices.first?.question == "見出しも追加")
    }

    @Test(arguments: [Int?.none, Int?(1)])
    func 手動送信後に宛先とフッターと初期選択が切り替わり合言葉で同じ文面を送る(initialSlot: Int?) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), fixture = fixture(root, fake: fake, initialSlot: initialSlot)
        defer { fixture.close() }
        let session = fixture.session
        let remembered = fixture.defaults.value.string(forKey: StartSheet.manualDefaultsKey)
        let task = try selectAndSend(fixture, slot: 2, text: "スライドの図を更新")
        // 接続・送信の完了前は、前の宛先を維持する。
        #expect(session.meetingManualAI?.slot == initialSlot)
        await task.value
        #expect(session.meetingManualAI?.slot == 2 && session.snapshot.manualDestination?.slot == 2)
        fixture.window.apply(session.snapshot)
        #expect(fixture.window.compactFooter.manualDestination.destinationName == "スライド")
        let controller = try #require(session.aiRecord?.controller)
        let first = try #require(controller.conversation.questions.last?.request)
        #expect(first.envelope.participant.profileSlot == 2 && controller.conversation.questions.last?.state == .submitted)
        try receive(session, root: root, request: first)
        fixture.closeSheet()
        fixture.app.showAISheet(parent: nil)
        #expect(fixture.app.aiSheet?.owningSlot == 2 && fixture.app.aiSheet?.draft == "スライドの図を更新")
        fixture.closeSheet()
        // シートの選択が動いても、声の合図は最後に手動送信した宛先へ送る。
        session.selectAIProfile(slot: 1)
        session.publishForTesting(tokens: [.init(text: "アバンティ", phraseId: -1, start: 0, end: 1)],
                                  speakers: [0], elapsed: 1, finalCount: 1, accurateFinalCount: 0)
        await (try #require(session.submissionTaskForTesting(slot: 2))).value
        #expect(controller.conversation.questions.count == 2)
        let repeated = try #require(controller.conversation.questions.last?.request)
        #expect(repeated.trigger == nil && repeated.envelope.participant.profileSlot == 2)
        #expect(repeated.envelope.participant.question == "スライドの図を更新")
        #expect(await fake.commands.filter { $0.prefix(2) == ["agent", "prompt"] }.count == 2)
        #expect(fixture.defaults.value.string(forKey: StartSheet.manualDefaultsKey) == remembered)
        let nextStart = StartSheet(profiles: session.meetingAIProfiles, diarizationEnabled: true,
                                   exclusion: AudioExclusion(), defaults: fixture.defaults.value)
        defer { nextStart.close() }
        #expect(nextStart.selectedManualSlot == initialSlot)
    }

    @Test(arguments: [Int?.none, Int?(1)])
    func 手動シートで宛先を選び直して取り消しても会議の宛先を変えない(initialSlot: Int?) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = fixture(root, fake: FakeHerdr(), initialSlot: initialSlot)
        defer { fixture.close() }
        fixture.app.showAISheet(parent: nil)
        let sheet = try #require(fixture.app.aiSheet)
        sheet.onDestination?(2)
        sheet.onCancel?()
        sheet.close()
        #expect(fixture.session.meetingManualAI?.slot == initialSlot)
        #expect(fixture.session.snapshot.manualDestination?.slot == initialSlot)
        #expect(fixture.session.aiRecord == nil)
    }

    @Test(arguments: [Int?.none, Int?(1)])
    func 手動送信の準備を取り消しても会議の宛先を変えない(initialSlot: Int?) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), fixture = fixture(root, fake: fake, initialSlot: initialSlot)
        defer { fixture.close() }
        let task = try selectAndSend(fixture, slot: 2, text: "更新")
        fixture.session.cancelAIPreparation(slot: 2)
        await task.value
        #expect(fixture.session.meetingManualAI?.slot == initialSlot)
        #expect(!(await fake.commands).contains { $0.prefix(2) == ["agent", "prompt"] })
    }

    @Test(arguments: [Int?.none, Int?(1)], [false, true])
    func 接続失敗と送達不明では会議の手動宛先を変えない(initialSlot: Int?, promptFailure: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), fixture = fixture(root, fake: fake, initialSlot: initialSlot, failConnection: !promptFailure)
        defer { fixture.close() }
        if promptFailure { await fake.failPrompt({}) }
        await (try selectAndSend(fixture, slot: 2, text: "更新")).value
        #expect(fixture.session.meetingManualAI?.slot == initialSlot)
        #expect(fixture.session.snapshot.manualDestination?.slot == initialSlot)
        let question = try #require(fixture.session.aiRecord?.controller.conversation.questions.last)
        #expect(question.state == (promptFailure ? .deliveryUnknown : .failed))
        #expect(fixture.session.snapshot.ai?.warning != nil)
    }

    @Test(arguments: [false, true])
    func 確認への返答と失敗した依頼の再送は会議の手動宛先を変えない(resend: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = fixture(root, fake: FakeHerdr())
        defer { fixture.close() }
        let session = fixture.session
        session.submitAI(question: "確認", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"),
                         profile: session.meetingAIProfiles[1])
        await (try #require(session.submissionTaskForTesting(slot: 2))).value
        let controller = try #require(session.aiRecord?.controller)
        let source = try #require(controller.conversation.questions.last?.request)
        try receive(session, root: root, request: source, kind: resend ? .failed : .needsInput)
        fixture.app.showAISheet(parent: resend ? nil : source.id, resend: resend ? source.id : nil)
        let sheet = try #require(fixture.app.aiSheet)
        #expect(sheet.owningSlot == 2 && sheet.onDestination == nil)
        sheet.onSubmit?(resend ? "再送" : "その案でお願いします", false)
        await (try #require(session.submissionTaskForTesting(slot: 2))).value
        #expect(controller.conversation.questions.count == 2)
        #expect(controller.conversation.questions.last?.state == .submitted)
        #expect(controller.conversation.questions.last?.request.envelope.participant.profileSlot == 2)
        #expect(session.meetingManualAI?.slot == 1 && session.snapshot.manualDestination?.slot == 1)
    }
}
