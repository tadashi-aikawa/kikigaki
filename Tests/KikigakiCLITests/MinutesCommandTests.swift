import Darwin
import Foundation
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import KikigakiCLI

@Suite struct MinutesCommandTests {
    @Test(arguments: [nil, 2] as [Int?])
    func 保存して同じ通知は冪等にしresultと共存する(_ slot: Int?) throws {
        let f = try ReturnCommandTests.Fixture(slot: slot)
        let path = "/tmp/議事録 ' $().md"
        let command = try ReturnCommand(f.args("minutes", ["--path", path]))
        let first = try command.execute(input: { Issue.record("minutesはstdinを読まない"); return Data() }, environment: [:], now: Date(timeIntervalSince1970: 10))
        #expect(try command.execute(input: { Data() }, environment: [:]) == first)
        let inbox = AIInbox(outputDirectory: f.root)
        let event = try inbox.readMinutes(filename: f.request.id.uuidString + ".minutes.json", for: f.request)
        #expect(event.minutesPath == path && event.recordedAt == Date(timeIntervalSince1970: 10))
        #expect(throws: AIError.conflict) {
            try ReturnCommand(f.args("minutes", ["--path", "/tmp/別.md"])).execute(input: { Data() }, environment: [:])
        }
        _ = try ReturnCommand(f.args("reply", ["--kind", "answered"])).execute(input: { Data("保存した".utf8) }, environment: [:])
        _ = try ReturnCommand(f.args("accept")).execute(input: { Data() }, environment: [:])
        #expect(try inbox.read(filename: f.request.id.uuidString + ".result.json", for: f.request).body == "保存した")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.files.directory(f.base + ["inbox"]).path).count == 3)
    }

    @Test func 引数とtokenと管理領域とthreadを検証する() throws {
        let f = try ReturnCommandTests.Fixture()
        for extra in [[], ["--path", ""], ["--path", "/tmp/a.md", "--path", "/tmp/a.md"], ["--path", "/tmp/a.md", "--kind", "answered"]] {
            #expect(throws: (any Error).self) { try ReturnCommand(f.args("minutes", extra)) }
        }
        for path in ["/tmp/.kikigaki-context/a.md", "/tmp/../a.md", "/tmp//a.md", "relative.md"] {
            #expect(throws: (any Error).self) { try ReturnCommand(f.args("minutes", ["--path", path])).execute(input: { Data() }, environment: [:]) }
        }
        var args = f.args("minutes", ["--path", "/tmp/a.md"]); args[6] = "hook-secret"
        #expect(throws: AIError.mismatch) { try ReturnCommand(args).execute(input: { Data() }, environment: [:]) }
        let command = try ReturnCommand(f.args("minutes", ["--path", "/tmp/a.md"]))
        #expect(throws: AIError.mismatch) { try command.execute(input: { Data() }, environment: ["CODEX_THREAD_ID": "other"]) }
        _ = try command.execute(input: { Data() }, environment: ["CODEX_THREAD_ID": "main-thread"])
        #expect(try AIJSON.decode(String.self, from: f.files.read(f.base + ["sessions", "1.identity.json"])) == "main-thread")
    }

    @Test(arguments: ["symlink", "hardlink", "fifo", "permissions"])
    func 不正な既存イベントを読みも置換もしない(_ kind: String) throws {
        let f = try ReturnCommandTests.Fixture(), name = f.request.id.uuidString + ".minutes.json"
        let inbox = try f.files.directory(f.base + ["inbox"]), target = inbox.appendingPathComponent(name)
        let command = try ReturnCommand(f.args("minutes", ["--path", "/tmp/a.md"]))
        let bytes = try AIJSON.encode(AIMinutesEvent(request: f.request, path: "/tmp/a.md", recordedAt: Date()))
        let other = f.root.appendingPathComponent("other")
        try f.files.write(bytes, to: ["other"])
        switch kind {
        case "symlink": try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other)
        case "hardlink": #expect(link(other.path, target.path) == 0)
        case "fifo": #expect(mkfifo(target.path, 0o600) == 0)
        default:
            try f.files.write(bytes, to: f.base + ["inbox", name]); #expect(chmod(target.path, 0o644) == 0)
        }
        #expect(throws: (any Error).self) { try command.execute(input: { Data() }, environment: [:]) }
        #expect(throws: (any Error).self) { try AIInbox(outputDirectory: f.root).readMinutes(filename: name, for: f.request) }
        #expect(try Data(contentsOf: other) == bytes)
    }

    @Test func 同時通知は排他的に公開し本文は触らない() async throws {
        let f = try ReturnCommandTests.Fixture()
        let path = f.root.appendingPathComponent("minutes.md")
        try Data("既存議事録".utf8).write(to: path)
        let a = try ReturnCommand(f.args("minutes", ["--path", path.path]))
        let b = try ReturnCommand(f.args("minutes", ["--path", "/tmp/other.md"]))
        let first = Task.detached { try? a.execute(input: { Data() }, environment: [:]) }
        let second = Task.detached { try? b.execute(input: { Data() }, environment: [:]) }
        #expect(await [first.value, second.value].compactMap { $0 }.count == 1)
        #expect(try String(contentsOf: path, encoding: .utf8) == "既存議事録")
    }

    @Test func 実バイナリがminutesを保存する() throws {
        let f = try ReturnCommandTests.Fixture(slot: 2)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = source.appendingPathComponent(".build/debug/kikigaki-cli")
        process.arguments = f.args("minutes", ["--path", "/tmp/実行結果.md"])
        var env = ProcessInfo.processInfo.environment; env["CODEX_THREAD_ID"] = nil
        process.environment = env; process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = error
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let result = try JSONDecoder().decode([String: String].self, from: output.fileHandleForReading.readDataToEndOfFile())
        #expect(result["event_id"] == f.request.id.uuidString + "/minutes")
        #expect(try AIInbox(outputDirectory: f.root).readMinutes(filename: f.request.id.uuidString + ".minutes.json", for: f.request).minutesPath == "/tmp/実行結果.md")
    }
}
