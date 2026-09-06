import Foundation
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
