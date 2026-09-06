import Foundation
import Testing
@testable import Kikigaki
import KikigakiCore

@Suite struct AITransportTests {
    @Test func 保存は排他公開し途中パスのリンクを拒否する() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AIFileStore(root: root)
        try store.write(Data("first".utf8), to: ["private", "request.json"], replacing: false)
        #expect(try store.read(["private", "request.json"]) == Data("first".utf8))
        #expect(throws: AIError.self) { try store.write(Data(), to: ["private", "request.json"], replacing: false) }
        try store.write(Data("updated".utf8), to: ["private", "request.json"])
        #expect(try store.read(["private", "request.json"]) == Data("updated".utf8))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: root.appendingPathComponent("private").path)
        #expect(throws: AIError.self) { try store.write(Data(), to: ["link", "new.json"]) }
        #expect(throws: AIError.self) { try store.read(["private", "request.json"], limit: 2) }
    }

    @Test @MainActor func 監視中のディレクトリ置換でも再走査する() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("inbox")
        var scans = 0
        let monitor = AIInboxMonitor(directory: directory) { scans += 1 }
        defer { monitor.stop() }
        #expect(scans == 1)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        monitor.scan()
        try Data("event".utf8).write(to: directory.appendingPathComponent("result.json"))
        for _ in 0..<50 where scans < 3 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(scans >= 3)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        monitor.scan()
        let before = scans
        try Data("next".utf8).write(to: directory.appendingPathComponent("result.json"))
        for _ in 0..<50 where scans == before { try await Task.sleep(for: .milliseconds(20)) }
        #expect(scans > before)
    }

    @Test func 親環境と引用文字を起動先へ漏らさない() {
        #expect(AIProcessRunner.environment(["HERDR_ENV": "1", "HERDR_PANE_ID": "parent", "PATH": "/bin", "X": "v"]) == ["PATH": "/bin", "X": "v"])
        #expect(AIShell.command(["/空 白/helper", "a'b", "$(touch /tmp/invalid)"]) == "'/空 白/helper' 'a'\\''b' '$(touch /tmp/invalid)'")
    }

    @Test func 並行stdoutとstderrを詰まらせず読み切る() async throws {
        let output = try await AIProcessRunner().run(URL(fileURLWithPath: "/bin/sh"),
            ["-c", "i=0; while [ $i -lt 6000 ]; do echo abcdefghijklmnop; echo qrstuvwxyzabcdef >&2; i=$((i+1)); done"], timeout: 10)
        #expect(output.status == 0)
        #expect(output.stdout.count == 102000)
        #expect(output.stderr.count == 102000)
    }

    @Test func 自分の期限超過プロセスだけを終了する() async {
        await #expect(throws: AIProcessError.self) {
            _ = try await AIProcessRunner().run(URL(fileURLWithPath: "/bin/sleep"), ["5"], timeout: 0.05)
        }
    }

    @Test func 出力量上限を超えた子を止める() async {
        await #expect(throws: AIProcessError.self) {
            _ = try await AIProcessRunner().run(URL(fileURLWithPath: "/usr/bin/yes"), ["payload"], timeout: 5)
        }
    }

    @Test func 処理中へpromptせずreadyとsessionを照合する() async throws {
        let calls = Calls()
        let herdr = AIHerdr(run: { args, _ in
            await calls.append(args)
            return AIProcessOutput(status: 0, stdout: Data(#"{"result":{"agent":{"pane_id":"w1:p1","workspace_id":"w1","agent":"codex","agent_status":"working","interactive_ready":true,"agent_session":{"value":"s1"}}}}"#.utf8), stderr: Data())
        })
        let connection = AIHerdrConnection(workspaceID: "w1", paneID: "w1:p1", provider: .codex, sessionID: "s1")
        await #expect(throws: AIHerdrError.self) { try await herdr.prompt(connection, text: "送らない") }
        #expect(await calls.values == [["agent", "get", "w1:p1"]])
        let replaced = AIHerdrConnection(workspaceID: "w1", paneID: "w1:p1", provider: .codex, sessionID: "old")
        await #expect(throws: AIHerdrError.self) { _ = try await herdr.observe(replaced) }
    }

    @Test func 生成IDを使いprompt本文を一引数で送る() async throws {
        let calls = Calls()
        let herdr = AIHerdr(run: { args, _ in
            await calls.append(args)
            let response: String
            if args.prefix(2) == ["workspace", "create"] {
                response = #"{"result":{"workspace":{"workspace_id":"opaque"},"root_pane":{"pane_id":"paneX"}}}"#
            } else if args.prefix(2) == ["agent", "get"] {
                response = #"{"result":{"agent":{"pane_id":"paneX","workspace_id":"opaque","agent":"claude","agent_status":"done","interactive_ready":true,"agent_session":{"value":"s1"}}}}"#
            } else { response = #"{"result":{}}"# }
            return AIProcessOutput(status: 0, stdout: Data(response.utf8), stderr: Data())
        })
        let connection = try await herdr.create(cwd: URL(fileURLWithPath: "/tmp/work"), label: "日本語", provider: .claude)
        try await herdr.label(connection, participant: "迅雷")
        try await herdr.start(connection, executable: URL(fileURLWithPath: "/tmp/CLI 空白"), arguments: ["--settings", "/tmp/a'b"])
        try await herdr.prompt(connection, text: "$kikigaki\n迅雷へ\n本文 ` $(x)")
        let recorded = await calls.values
        #expect(recorded[0].contains("--no-focus"))
        #expect(recorded[2] == ["pane", "run", "paneX", "'/tmp/CLI 空白' '--settings' '/tmp/a'\\''b'"])
        #expect(recorded.last == ["agent", "prompt", "paneX", "$kikigaki\n迅雷へ\n本文 ` $(x)"])
    }
}

private actor Calls {
    var values: [[String]] = []
    func append(_ value: [String]) { values.append(value) }
}
