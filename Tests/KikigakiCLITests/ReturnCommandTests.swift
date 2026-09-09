import Darwin
import Foundation
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import KikigakiCLI

@Suite struct ReturnCommandTests {
    final class Fixture {
        let root: URL, request: AIRequest, session: AISessionRecord, path: String
        var base: [String] { [".kikigaki-context", session.meetingID.uuidString, "ai"] }
        var files: AIFileStore { .init(root: root) }
        init(provider: AIProvider = .codex, slot: Int? = nil) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("kikigaki cli ' $ " + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let meeting = UUID()
            var history = try AIStreamHistory(meetingID: meeting)
            let snapshot = try history.prepare(lines: ["[12:00:00] A: 質問です"], outputDirectory: root)
            let branch = AIEnvelope.sessionPath(slot: slot, generation: 1)
            path = root.appendingPathComponent(".kikigaki-context/\(meeting.uuidString)/" + branch).path
            let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
                participantName: "迅雷", cliPath: "/tmp/helper", sessionPath: path, requestToken: "request-secret",
                question: "質問", capturedAt: Date(), audioCutoffSeconds: 1,
                profile: slot == nil ? nil : "議事録", profileSlot: slot)
            request = try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant), number: 1, snapshot: snapshot)
            session = AISessionRecord(meetingID: meeting, generation: 1, provider: provider, token: "hook-secret",
                connection: .init(workspaceID: "w", paneID: "p", provider: provider, sessionID: "main-thread"))
            try files.write(AIJSON.encode(session), to: base + ["sessions"] + (slot.map { ["\($0)"] } ?? []) + ["1.json"])
            try files.write(AIJSON.encode(request), to: base + ["requests", request.id.uuidString + ".json"])
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func args(_ action: String, _ extra: [String] = []) -> [String] {
            [action, "--session", path, "--request", request.id.uuidString, "--token", "request-secret"] + extra
        }
        func hookArgs(_ payload: String? = nil) -> [String] {
            ["notify", "--session", path, "--provider", session.provider.rawValue, "--token", "hook-secret"] + (payload.map { [$0] } ?? [])
        }
    }
    @Test func acceptと全result種別はCoreで読める() throws {
        for (kind, reason) in [("answered", nil), ("needs_input", "clarification"), ("needs_input", "context_missing"), ("failed", "read_failed")] as [(String, String?)] {
            let f = try Fixture()
            let args = f.args("reply", ["--kind", kind] + (reason.map { ["--reason", $0] } ?? []))
            _ = try ReturnCommand(args).execute(input: { Data("結論\n\n本文です。".utf8) }, environment: [:])
            let event = try AIInbox(outputDirectory: f.root).read(filename: f.request.id.uuidString + ".result.json", for: f.request)
            #expect(event.kind.rawValue == kind && event.body == "結論\n\n本文です。")
            #expect(event.contextReceived == (reason != "read_failed" && reason != "context_missing"))
            _ = try ReturnCommand(f.args("accept")).execute(input: { Issue.record("acceptはstdinを読まない"); return Data() }, environment: [:])
            #expect(try AIInbox(outputDirectory: f.root).read(filename: f.request.id.uuidString + ".accept.json", for: f.request).kind == .accept)
        }
    }
    /// プロファイルごとの枝を切った会議でも返送できること。
    /// 平置きだけを想定していた頃はここで unsafe_file になり、実herdrの返送が全滅した。
    @Test func プロファイルの枝を切った保存パスでも返送できる() throws {
        let f = try Fixture(slot: 2)
        #expect(f.path.hasSuffix("/ai/sessions/2/1.json"))
        _ = try ReturnCommand(f.args("accept")).execute(input: { Data() }, environment: [:])
        _ = try ReturnCommand(f.args("reply", ["--kind", "answered"])).execute(input: { Data("回答".utf8) }, environment: [:])
        let inbox = AIInbox(outputDirectory: f.root)
        #expect(try inbox.read(filename: f.request.id.uuidString + ".accept.json", for: f.request).kind == .accept)
        #expect(try inbox.read(filename: f.request.id.uuidString + ".result.json", for: f.request).body == "回答")
    }

    @Test func 枝の番号が不正な保存パスを拒否する() throws {
        let f = try Fixture(slot: 2)
        for broken in ["/ai/sessions/0/1.json", "/ai/sessions/02/1.json", "/ai/sessions/x/1.json", "/ai/sessions/2/3/1.json"] {
            var args = f.args("accept")
            args[2] = f.path.replacingOccurrences(of: "/ai/sessions/2/1.json", with: broken)
            #expect(throws: (any Error).self) { try ReturnCommand(args).execute(input: { Data() }, environment: [:]) }
        }
    }

    @Test func 再実行は時刻を変えず異なる本文は拒否する() throws {
        let f = try Fixture(), command = try ReturnCommand(f.args("reply", ["--kind", "answered"]))
        let first = try command.execute(input: { Data("回答".utf8) }, environment: [:], now: Date(timeIntervalSince1970: 100))
        #expect(try command.execute(input: { Data("回答".utf8) }, environment: [:]) == first)
        #expect(throws: AIError.conflict) { try command.execute(input: { Data("別回答".utf8) }, environment: [:]) }
        let event = try AIInbox(outputDirectory: f.root).read(filename: f.request.id.uuidString + ".result.json", for: f.request)
        #expect(event.recordedAt == Date(timeIntervalSince1970: 100))
    }
    @Test func トークンとパスとUTF8と上限を検証する() throws {
        let f = try Fixture()
        var args = f.args("accept"); args[6] = "hook-secret"
        #expect(throws: AIError.mismatch) { try ReturnCommand(args).execute(input: { Data() }, environment: [:]) }
        #expect(throws: (any Error).self) { try ReturnCommand(["accept", "--session", "/tmp/../bad", "--request", f.request.id.uuidString, "--token", "x"]).execute(input: { Data() }) }
        let command = try ReturnCommand(f.args("reply", ["--kind", "answered"]))
        #expect(throws: (any Error).self) { try command.execute(input: { Data([0xff]) }, environment: [:]) }
        #expect(throws: AIError.tooLarge) { try command.execute(input: { Data(repeating: 65, count: AILimits.bodyBytes + 1) }, environment: [:]) }
        let inbox = try f.files.directory(f.base + ["inbox"])
        let target = inbox.appendingPathComponent(f.request.id.uuidString + ".result.json")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: f.root.appendingPathComponent("absent"))
        #expect(throws: (any Error).self) { try command.execute(input: { Data("回答".utf8) }, environment: [:]) }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("absent").path))
    }
    @Test func 同時に違う回答を公開しても一つだけを保存する() async throws {
        let f = try Fixture(), command = try ReturnCommand(f.args("reply", ["--kind", "answered"]))
        let first = Task.detached { try? command.execute(input: { Data("回答A".utf8) }, environment: [:]) }
        let second = Task.detached { try? command.execute(input: { Data("回答B".utf8) }, environment: [:]) }
        let results = await [first.value, second.value]
        #expect(results.compactMap { $0 }.count == 1)
        let event = try AIInbox(outputDirectory: f.root).read(filename: f.request.id.uuidString + ".result.json", for: f.request)
        #expect(["回答A", "回答B"].contains(event.body))
    }
    @Test func フックはタイトルと本threadを分離し本文を保持しない() throws {
        let f = try Fixture()
        for thread in ["title-thread", "main-thread"] {
            let payload = "{\"type\":\"agent-turn-complete\",\"thread-id\":\"\(thread)\",\"turn-id\":\"turn\",\"last-assistant-message\":\"秘密本文\",\"input-messages\":[\"request-secret\"]}"
            let command = try ReturnCommand(f.hookArgs(payload))
            let id = try command.execute(input: { Issue.record("Codex notifyはstdinを読まない"); return Data() })
            #expect(try command.execute(input: { Data() }) == id)
            let data = try f.files.read(f.base + ["inbox", "notify-\(id).json"])
            #expect(!String(decoding: data, as: UTF8.self).contains("秘密本文"))
            #expect(!String(decoding: data, as: UTF8.self).contains("request-secret"))
            let event = try AIJSON.decode(AIHookObservation.self, from: data)
            #expect(event.sessionID == thread)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.files.directory(f.base + ["inbox"]).path).count == 2)
        let claude = try Fixture(provider: .claude)
        let id = try ReturnCommand(claude.hookArgs()).execute(input: { Data("{\"hook_event_name\":\"Stop\",\"session_id\":\"main-thread\",\"prompt_id\":\"p\",\"background_tasks\":[{\"status\":\"running\"}]}".utf8) })
        let event = try AIJSON.decode(AIHookObservation.self, from: claude.files.read(claude.base + ["inbox", "notify-\(id).json"]))
        #expect(event.runningBackgroundTasks)
    }
    @Test func 別プロセスのCLIへstdinを渡して返送できる() throws {
        let f = try Fixture()
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = ProcessInfo.processInfo.environment["KIKIGAKI_CLI_TEST_BINARY"].map { URL(fileURLWithPath: $0) } ?? source.appendingPathComponent(".build/debug/kikigaki-cli")
        let input = f.root.appendingPathComponent("input")
        try Data("結論です。\n`code` と $(実行しない)".utf8).write(to: input)
        let handle = try FileHandle(forReadingFrom: input); defer { try? handle.close() }
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = binary; process.arguments = f.args("reply", ["--kind", "answered"])
        var environment = ProcessInfo.processInfo.environment; environment["CODEX_THREAD_ID"] = nil
        process.environment = environment; process.standardInput = handle; process.standardOutput = output; process.standardError = error
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let result = try #require(JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: String])
        #expect(result["event_id"] == f.request.id.uuidString + "/result")
        #expect(try AIInbox(outputDirectory: f.root).read(filename: f.request.id.uuidString + ".result.json", for: f.request).body?.contains("$(実行しない)") == true)
    }
}
