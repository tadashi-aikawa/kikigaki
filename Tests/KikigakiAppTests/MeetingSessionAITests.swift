import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite(.timeLimit(.minutes(1))) @MainActor struct MeetingSessionAITests {
    private final class Gate {
        var opened = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            let pending = waiters; waiters = []
            pending.forEach { $0.resume() }
        }
    }
    private final class Hook {
        var action: (() async -> Void)?
        func run() async { await action?() }
    }
    private func config(_ root: URL) throws -> ResolvedConfig {
        var value = ResolvedConfig(config: try ConfigLoader.parse(toml: ""), home: root)
        value.ai = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path), home: root)
        return value
    }
    private func submit(_ session: MeetingSession) throws -> Task<Void, Never> {
        session.submitAI(question: "質問", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"))
        return try #require(session.submissionTaskForTesting)
    }

    private final class NoAudio: AudioSource {
        func start(onSamples: @escaping ([Float]) -> Void) throws { Issue.record("テストでは音源を起動しない") }
        func stop() {}
    }
    @Test(arguments: [false, true]) func シートの作業許可を会議内で引き継ぎ送信時に固定し新録音で設定へ戻す(defaultAllowed: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        var config = try config(root)
        config.ai = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path, allowWork: defaultAllowed), home: root)
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config, aiStore: store)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func sheet() -> AIQuestionSheet {
            let sheet = AIQuestionSheet(participant: "迅雷", parentNumber: nil, draft: "追記してください", voice: "", range: "追加の確定行なし",
                tentative: false, canSubmit: true, workAllowed: session.aiWorkAllowed)
            sheet.onWorkAllowedChange = { session.updateAIWorkAllowed($0) }
            sheet.onSubmit = { text, full in session.submitAI(question: text, full: full, parent: nil, helper: URL(fileURLWithPath: "/bin/echo")) }
            return sheet
        }
        let firstSheet = sheet()
        let checkbox = try #require(descendants(firstSheet.window.contentView!).compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("作業を許可する") })
        #expect((checkbox.state == .on) == defaultAllowed)
        checkbox.performClick(nil)
        #expect(session.aiWorkAllowed == !defaultAllowed)
        if let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] {
            let view = firstSheet.window.contentView!.superview!; view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent("work-allowed-\(!defaultAllowed).png"))
        }
        let send = try #require(descendants(firstSheet.window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "送信" })
        send.performClick(nil)
        #expect(!checkbox.isEnabled)
        let task = try #require(session.submissionTaskForTesting)
        // 起動が始まる前に次回の値を変えても、今回のrequestはEnter時点の値を使う。
        session.updateAIWorkAllowed(defaultAllowed)
        await task.value
        let first = try #require(session.aiRecord?.controller.conversation.questions.first)
        #expect(first.state == .submitted && first.request.envelope.participant.workAllowed == !defaultAllowed)
        var conversation = AIConversation(meetingID: first.request.envelope.meetingID)
        try conversation.append(first.request)
        try conversation.update(first.request.id) { try $0.beginSending(at: Date()); try $0.submitted() }
        let sendItem = try #require(AITimeline.items(conversation: conversation, utterances: [],
                                                     timeline: MeetingTimeline(startedAt: Date())).first)
        // 許可されているのが通常なので、注記は許可していないときだけ出す。
        #expect(sendItem.notes.contains("作業許可なし") == defaultAllowed)
        session.updateAIWorkAllowed(!defaultAllowed)
        session.update(config: config)
        let secondSheet = sheet()
        let nextCheckbox = try #require(descendants(secondSheet.window.contentView!).compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("作業を許可する") })
        #expect((nextCheckbox.state == .on) == !defaultAllowed)
        session.cancelAI(first.request.id); session.recreateAI()
        let second = try submit(session); await second.value
        #expect(session.aiRecord?.controller.conversation.questions.last?.request.envelope.participant.workAllowed == !defaultAllowed)
        await session.stop()
        #expect(session.aiWorkAllowed == !defaultAllowed)
        #expect(try String(contentsOf: root.appendingPathComponent("meeting.md"), encoding: .utf8).contains("- 作業許可: " + (!defaultAllowed ? "あり" : "なし")))
        // DEBUG fixtureのmodelsはthrowする。録音開始時のリセットだけを本番startで通す。
        #expect(await !session.start(source: NoAudio()))
        #expect(session.aiWorkAllowed == defaultAllowed)
    }

    @Test func 録音停止は確定待ち中の問いだけを取り消し送信しない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), waiting = Gate()
        let store = AIRecordStore(directory: root, makeHerdr: {
            AIHerdr(run: { try await fake.run($0, $1) })
        })
        // 1秒収録済み・処理は0秒なので、実際のAIConfirmationWaitへ入る。
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"),
            config: try config(root), aiStore: store, recordedSamples: 16_000)
        session.onChange = { if $0.ai?.progress?.hasPrefix("聞き取りの確定待ち") == true || $0.ai?.warning != nil { waiting.open() } }
        let task = try submit(session)
        await waiting.wait()
        #expect(session.snapshot.ai?.progress?.hasPrefix("聞き取りの確定待ち") == true)
        await session.stop()
        await task.value
        #expect(session.snapshot.state == .idle)
        #expect(session.snapshot.ai?.progress == nil)
        #expect(session.aiRecord?.controller.conversation.questions.isEmpty == true)
        #expect(await fake.commands.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func 接続や送信中の録音停止では最終保存中も停止後も一度だけ送信する(duringSend: Bool, finishBeforeSend: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), hook = Hook(), finishing = Gate(), finishAudio = Gate()
        let operation = duringSend ? ["agent", "prompt"] : ["workspace", "create"]
        let store = AIRecordStore(directory: root, makeHerdr: {
            AIHerdr(run: { args, timeout in
                if Array(args.prefix(2)) == operation { await hook.run() }
                return try await fake.run(args, timeout)
            })
        })
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"),
            config: try config(root), aiStore: store, finishAudio: { await finishAudio.wait() })
        session.onChange = { if $0.state == .finishing { finishing.open() } }
        var stopTask: Task<Void, Never>?
        hook.action = {
            stopTask = Task { await session.stop() }
            await finishing.wait()
            #expect(session.snapshot.state == .finishing)
            if finishBeforeSend {
                finishAudio.open()
                await stopTask?.value
                #expect(session.snapshot.state == .idle)
            }
        }
        let task = try submit(session)
        await task.value
        #expect(finishing.opened)
        #expect(session.snapshot.state == (finishBeforeSend ? .idle : .finishing))
        #expect(session.aiRecord?.controller.conversation.questions.map(\.state) == [.submitted])
        #expect(await fake.commands.filter { $0.prefix(2) == ["agent", "prompt"] }.count == 1)
        finishAudio.open()
        await stopTask?.value
        #expect(session.snapshot.saved)
        #expect(session.aiRecord?.archive != nil)
    }

    @Test func 明示的な取消は接続中でも送信を止める() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), hook = Hook()
        let store = AIRecordStore(directory: root, makeHerdr: {
            AIHerdr(run: { args, timeout in
                if args.prefix(2) == ["workspace", "create"] { await hook.run() }
                return try await fake.run(args, timeout)
            })
        })
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"),
            config: try config(root), aiStore: store)
        hook.action = { session.cancelAIPreparation() }
        let task = try submit(session)
        await task.value
        #expect(session.aiRecord?.controller.conversation.questions.map(\.state) == [.cancelled])
        #expect(await fake.commands.filter { $0.prefix(2) == ["agent", "prompt"] }.isEmpty)
        await session.stop()
    }
}
