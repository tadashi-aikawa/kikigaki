import Darwin
import Foundation
import Testing
@testable import Kikigaki
import KikigakiCore
import KikigakiAIIO
import TOMLKit

@Suite struct AITransportTests {
    @Test(arguments: [1, 2, 100, Int.max]) func agent名は全世代でherdrの32文字制約を満たす(generation: Int) throws {
        let name = try AIHerdr.agentName(generation: generation)
        #expect(name.utf8.count <= 32)
        #expect(name.range(of: "^[a-z][a-z0-9_-]{0,31}$", options: .regularExpression) != nil)
        #expect(name.hasSuffix("-g" + String(generation, radix: 36)))
        #expect(throws: AIProcessError.invalidInput) { try AIHerdr.agentName(generation: 0) }
    }
    private final class CapturedLog: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.lock(); defer { lock.unlock() }; lines.append(line) }
        var captured: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }
    @Test func herdr失敗はエラーコードだけをログへ残す() async throws {
        for raw in ["invalid_agent_name", "invalid_agent_name\n"] {
            let captured = CapturedLog()
            let adapter = AIHerdr(run: { _, _ in
                AIProcessOutput(status: 1, stdout: Data(), stderr: try JSONSerialization.data(withJSONObject:
                    ["error": ["code": raw, "message": "本文とtokenは表示しない"]]))
            }, log: { captured.append($0) })
            let code = raw.contains("\n") ? "herdr_failed" : raw
            await #expect(throws: AIHerdrError.server(code)) {
                try await adapter.start(.init(workspaceID: "w", paneID: "p", provider: .codex), executable: URL(fileURLWithPath: "/tmp/fake"), arguments: [], customCommand: false)
            }
            #expect(captured.captured == ["herdr agent start: " + code])
        }
    }
    @Test func 成功時に出力の無いherdrコマンドは空の標準出力を成功として扱う() async throws {
        // 実測(herdr 0.8.2): pane report-metadata は成功時に何も出力しない
        let captured = CapturedLog()
        let adapter = AIHerdr(run: { _, _ in AIProcessOutput(status: 0, stdout: Data("\n".utf8), stderr: Data()) }, log: { captured.append($0) })
        try await adapter.label(.init(workspaceID: "w", paneID: "p", provider: .codex), participant: "迅雷")
        #expect(captured.captured.isEmpty)
    }
    @Test func 同じ失敗が続く間はログを1回に留め成功後は再び記録する() async throws {
        let captured = CapturedLog()
        let failing = AIHerdr(run: { _, _ in
            AIProcessOutput(status: 1, stdout: Data(), stderr: try JSONSerialization.data(withJSONObject: ["error": ["code": "agent_not_found"]]))
        }, log: { captured.append($0) })
        let target = AIHerdrConnection(workspaceID: "w", paneID: "p", provider: .codex)
        for _ in 0..<3 { await #expect(throws: AIHerdrError.missing) { try await failing.observe(target) } }
        #expect(captured.captured == ["herdr agent get: agent_not_found"])
    }
    @Test @MainActor func Codex通知引数はTOMLの文字列配列として復元できる() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path), home: root)
        let controller = try AIConversationController(meetingID: UUID(), outputDirectory: root, herdr: AIHerdr(run: { _, _ in throw AIHerdrError.notReady }))
        _ = try controller.prepare(lines: [], question: "質問", voiceQuestion: "", capturedAt: Date(), cutoff: 0, tail: nil, config: config, helper: URL(fileURLWithPath: "/bin/echo"))
        let launch = try AILaunchConfiguration(config: config, helper: URL(fileURLWithPath: "/bin/echo"), controller: controller)
        struct Settings: Decodable { let notify: [String] }
        let settings = try TOMLDecoder().decode(Settings.self, from: launch.arguments[1])
        #expect(settings.notify == ["/bin/echo", "notify", "--provider", "codex", "--session", controller.sessionURL.path, "--token", controller.sessionToken!])
    }
    @Test @MainActor func 生成設定は指定helperだけを許可しセッションへ限定する() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = ResolvedAIConfig(config: AIConfig(cli: .claude, command: "/bin/echo", model: "test-model", cwd: root.path), home: root)
        let controller = try AIConversationController(meetingID: UUID(), outputDirectory: root, herdr: AIHerdr(run: { _, _ in throw AIHerdrError.notReady }))
        _ = try controller.prepare(lines: [], question: "質問", voiceQuestion: "", capturedAt: Date(), cutoff: 0, tail: nil,
            config: config, helper: URL(fileURLWithPath: "/bin/echo"))
        let launch = try AILaunchConfiguration(config: config, helper: URL(fileURLWithPath: "/bin/echo"), controller: controller)
        #expect(launch.arguments.prefix(2) == ["--model", "test-model"])
        #expect(launch.arguments[2] == "--settings")
        let bytes = try AIFileStore(root: root).read([".kikigaki-context", controller.meetingID.uuidString, "ai", "sessions", "1.settings.json"])
        let settings = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect((settings["permissions"] as? [String: [String]])?["allow"] == ["Bash(/bin/echo *)"])
        #expect(!launch.arguments.contains("--permission-mode"))
        #expect(String(decoding: bytes, as: UTF8.self).contains(controller.sessionToken!))
    }
    @Test @MainActor func 監視先を置換しても再走査を続ける() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        var scans = 0
        let monitor = AIInboxMonitor(directory: inbox) { scans += 1 }
        defer { monitor.stop() }
        #expect(scans == 1)
        try FileManager.default.moveItem(at: inbox, to: root.appendingPathComponent("old"))
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        monitor.scan()
        #expect(scans == 2)
        try FileManager.default.removeItem(at: inbox)
        monitor.scan()
        #expect(scans == 3)
    }
    @Test func Claudeはsessionが立つまで準備完了にしない() async throws {
        let fake = FakeHerdr(); await fake.setProvider("claude")
        let adapter = AIHerdr(run: { try await fake.run($0, $1) })
        let target = AIHerdrConnection(workspaceID: "w", paneID: "p", provider: .claude)
        #expect(try await !adapter.observe(target).ready)
        await fake.setSession("current")
        #expect(try await adapter.observe(target).ready)
    }
    @Test func 環境と引数をシェル展開せず渡す() async throws {
        let runner = AIProcessRunner()
        let result = try await runner.run(URL(fileURLWithPath: "/usr/bin/env"), [],
            environment: ["HERDR_PANE_ID": "secret", "HERDR_OTHER": "secret", "SAFE": "kept"])
        #expect(String(decoding: result.stdout, as: UTF8.self) == "SAFE=kept\n")
        let literal = "a ' $HOME `date`\n日本語"
        let printed = try await runner.run(URL(fileURLWithPath: "/usr/bin/printf"), ["%s", literal])
        #expect(printed.stdout == Data(literal.utf8))
        let quoted = try await runner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", AIShell.command(["/usr/bin/printf", "%s", literal])])
        #expect(quoted.stdout == printed.stdout)
    }
    @Test func 両方のパイプを最後まで排出する() async throws {
        let result = try await AIProcessRunner().run(URL(fileURLWithPath: "/bin/sh"),
            ["-c", "i=0; while [ $i -lt 12000 ]; do echo abcdefgh; echo ijklmnop >&2; i=$((i+1)); done; printf END; printf FIN >&2"], timeout: 10)
        #expect(result.status == 0)
        #expect(result.stdout == Data((String(repeating: "abcdefgh\n", count: 12000) + "END").utf8))
        #expect(result.stderr == Data((String(repeating: "ijklmnop\n", count: 12000) + "FIN").utf8))
    }
    @Test func 期限と出力量と不正入力を区別する() async throws {
        let runner = AIProcessRunner()
        await #expect(throws: AIProcessError.timeout) { try await runner.run(URL(fileURLWithPath: "/bin/sleep"), ["5"], timeout: 0.03) }
        await #expect(throws: AIProcessError.outputLimit) { try await runner.run(URL(fileURLWithPath: "/usr/bin/yes"), [], timeout: 5) }
        await #expect(throws: AIProcessError.invalidInput) { try await runner.run(URL(fileURLWithPath: "/bin/echo"), ["a\0b"]) }
        await #expect(throws: AIProcessError.invalidInput) { try await runner.run(URL(fileURLWithPath: "/bin/echo"), [], timeout: .nan) }
        let task = Task { try await runner.run(URL(fileURLWithPath: "/bin/sleep"), ["5"]) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test func 完成名の排他保存とリンク拒否() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AIFileStore(root: root), bytes = Data("本文".utf8)
        try store.write(bytes, to: ["inbox", "one"], replacing: false)
        #expect(try store.read(["inbox", "one"]) == bytes)
        #expect(throws: AIError.conflict) { try store.write(Data(), to: ["inbox", "one"], replacing: false) }
        #expect(throws: AIError.tooLarge) { try store.read(["inbox", "one"], limit: 1) }
        let folder = root.appendingPathComponent("inbox")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["one"])
        let linkPath = folder.appendingPathComponent("link").path
        #expect(symlink("missing", linkPath) == 0)
        #expect(throws: AIError.unsafeFile) { try store.write(bytes, to: ["inbox", "link"]) }
        #expect(link(folder.appendingPathComponent("one").path, folder.appendingPathComponent("hard").path) == 0)
        #expect(throws: AIError.unsafeFile) { try store.read(["inbox", "one"]) }
        #expect(mkfifo(folder.appendingPathComponent("fifo").path, 0o600) == 0)
        #expect(throws: AIError.unsafeFile) { try store.read(["inbox", "fifo"]) }
        #expect(throws: AIError.unsafeFile) { try store.write(bytes, to: ["..", "escape"]) }
        #expect(symlink(folder.path, root.appendingPathComponent("alias").path) == 0)
        #expect(throws: AIError.unsafeFile) { try store.read(["alias", "one"]) }
    }
    @Test func 起動経路と準備状態と接続先を照合する() async throws {
        let fake = FakeHerdr(), adapter = AIHerdr(run: { try await fake.run($0, $1) })
        let target = try await adapter.create(cwd: URL(fileURLWithPath: "/tmp"), label: "会議", provider: .codex)
        try await adapter.start(target, executable: URL(fileURLWithPath: "/tmp/custom ' cli"), arguments: ["x;y"], customCommand: true)
        var commands = await fake.commands
        #expect(commands.last == ["pane", "run", "p", AIShell.command(["/tmp/custom ' cli", "x;y"])])
        try await adapter.start(target, executable: URL(fileURLWithPath: "/tmp/codex"), arguments: ["-m", "model"], customCommand: false)
        commands = await fake.commands
        #expect(commands.last?.prefix(2) == ["agent", "start"])
        #expect(commands.last?.suffix(9) == ["--kind", "codex", "--pane", "p", "--timeout", "15000", "--", "-m", "model"])
        await fake.setStatuses(["working"])
        await #expect(throws: AIHerdrError.notReady) { try await adapter.prompt(target, text: "質問") }
        #expect(await fake.commands.filter { $0.prefix(2) == ["agent", "prompt"] }.isEmpty)
        var pinned = target; pinned.sessionID = "old"
        await fake.setStatuses(["idle"])
        #expect(try await adapter.observe(pinned).status == .unknown)
        await fake.setSession("new")
        await #expect(throws: AIHerdrError.replaced) { try await adapter.observe(pinned) }
    }
}

func testDirectory() throws -> URL {
    let url = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("kikigaki-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

actor FakeHerdr {
    var commands: [[String]] = []
    var statuses = ["idle"]
    var session: String?
    var provider = "codex"
    var promptFailure = false
    var startFailure = false
    var beforePrompt: (@Sendable () throws -> Void)?
    func setStatuses(_ value: [String]) { statuses = value }
    func setSession(_ value: String?) { session = value }
    func setProvider(_ value: String) { provider = value }
    func rejectNextStart() { startFailure = true }
    func failPrompt(_ check: @escaping @Sendable () throws -> Void) { promptFailure = true; beforePrompt = check }
    func run(_ args: [String], _ timeout: TimeInterval) throws -> AIProcessOutput {
        commands.append(args)
        let response: [String: Any]
        switch Array(args.prefix(2)) {
        case ["agent", "start"] where startFailure:
            startFailure = false
            return AIProcessOutput(status: 1, stdout: Data(), stderr: Data("{\"error\":{\"code\":\"invalid_agent_name\"}}".utf8))
        case ["workspace", "create"]: response = ["workspace": ["workspace_id": "w"], "root_pane": ["pane_id": "p"]]
        case ["agent", "get"]:
            let status = statuses.count > 1 ? statuses.removeFirst() : statuses[0]
            var agent: [String: Any] = ["workspace_id": "w", "pane_id": "p", "agent": provider, "agent_status": status, "interactive_ready": true]
            if let session { agent["agent_session"] = ["value": session] }
            response = ["agent": agent]
        case ["agent", "prompt"]:
            try beforePrompt?()
            if promptFailure { throw AIProcessError.timeout }
            response = [:]
        default: response = [:]
        }
        return AIProcessOutput(status: 0, stdout: try JSONSerialization.data(withJSONObject: ["result": response]), stderr: Data())
    }
}
