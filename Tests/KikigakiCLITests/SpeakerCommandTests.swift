import Darwin
import Foundation
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import KikigakiCLI

@Suite struct SpeakerCommandTests {
    private let fixed = SpeakerIdentification(unresolved: ["A", "C"], candidates: ["タダシ", "田中"])
    private let evidence = "[12:00:00] 話者A: タダシです"

    @Test(arguments: [nil, 2] as [Int?]) func 作業許可なしでも返せて同内容の再実行は成功する(_ slot: Int?) throws {
        let f = try ReturnCommandTests.Fixture(slot: slot, identification: fixed, workAllowed: false)
        let command = try ReturnCommand(f.args("speaker", ["--slot", "A", "--name", " タダシ\n"]))
        let id = try command.execute(input: { Data(evidence.utf8) }, environment: [:], now: Date(timeIntervalSince1970: 10))
        #expect(id == "\(f.request.id)/speaker/A")
        #expect(try command.execute(input: { Data(evidence.utf8) }, environment: [:]) == id)
        let filename = "\(f.request.id).speaker.A.json"
        let event = try AIInbox(outputDirectory: f.root).readSpeaker(filename: filename, for: f.request)
        #expect(event.name == "タダシ" && event.evidence == evidence && event.recordedAt == Date(timeIntervalSince1970: 10))
        #expect(throws: AIError.conflict) { try command.execute(input: { Data("別の根拠".utf8) }, environment: [:]) }
        #expect(throws: AIError.conflict) {
            try ReturnCommand(f.args("speaker", ["--slot", "A", "--name", "田中"]))
                .execute(input: { Data(evidence.utf8) }, environment: [:])
        }
        // CLIは固定requestだけを見る。同名を別枠へ返すこと自体は許し、アプリが先勝ちで裁く。
        _ = try ReturnCommand(f.args("speaker", ["--slot", "C", "--name", "タダシ"]))
            .execute(input: { Data(evidence.utf8) }, environment: [:])
        _ = try ReturnCommand(f.args("accept")).execute(input: { Data() }, environment: [:])
        _ = try ReturnCommand(f.args("reply", ["--kind", "answered"]))
            .execute(input: { Data("返事".utf8) }, environment: [:])
        #expect(try AIInbox(outputDirectory: f.root).readSpeaker(filename: filename, for: f.request) == event)
    }
    @Test(arguments: ["B", "I", "a", "0", "A/../C"])
    func 固定した集合にない枠は拒否する(_ letter: String) throws {
        let f = try ReturnCommandTests.Fixture(identification: fixed)
        #expect(throws: (any Error).self) {
            try ReturnCommand(f.args("speaker", ["--slot", letter, "--name", "タダシ"]))
                .execute(input: { Data(evidence.utf8) }, environment: [:])
        }
    }
    /// 会話に出てきた人名も付けてよいので、候補外でもCLIは受ける。本文に出てきたかはアプリが取り込みで確かめる。
    @Test func 候補外の名前も名前の形なら受ける() throws {
        let f = try ReturnCommandTests.Fixture(identification: fixed)
        _ = try ReturnCommand(f.args("speaker", ["--slot", "A", "--name", "山田"]))
            .execute(input: { Data(evidence.utf8) }, environment: [:])
    }
    @Test(arguments: ["", "  ", "タダシ\0", "改\t行", String(repeating: "長", count: 65)])
    func 名前の形と引数を検証する(_ name: String) throws {
        let f = try ReturnCommandTests.Fixture(identification: fixed)
        #expect(throws: (any Error).self) {
            try ReturnCommand(f.args("speaker", ["--slot", "A", "--name", name]))
                .execute(input: { Data(evidence.utf8) }, environment: [:])
        }
    }
    @Test func 根拠はバイト上限とNULとUTF8を検証する() throws {
        let f = try ReturnCommandTests.Fixture(identification: fixed)
        let command = try ReturnCommand(f.args("speaker", ["--slot", "A", "--name", "タダシ"]))
        for data in [Data(repeating: 65, count: 2049), Data("根拠\0".utf8), Data([0xff]), Data()] {
            #expect(throws: (any Error).self) { try command.execute(input: { data }, environment: [:]) }
        }
        _ = try command.execute(input: { Data(repeating: 65, count: 2048) }, environment: [:])
    }
    @Test func 未指定のrequestと不正tokenを拒否する() throws {
        let f = try ReturnCommandTests.Fixture()
        #expect(throws: AIError.mismatch) {
            try ReturnCommand(f.args("speaker", ["--slot", "A", "--name", "タダシ"]))
                .execute(input: { Data(evidence.utf8) }, environment: [:])
        }
        let enabled = try ReturnCommandTests.Fixture(identification: fixed)
        var args = enabled.args("speaker", ["--slot", "A", "--name", "タダシ"]); args[6] = "hook-secret"
        #expect(throws: AIError.mismatch) { try ReturnCommand(args).execute(input: { Data(evidence.utf8) }, environment: [:]) }
    }
    @Test(arguments: ["symlink", "hardlink", "fifo", "permissions"])
    func 不正ファイルを読みも置換もしない(_ kind: String) throws {
        let f = try ReturnCommandTests.Fixture(identification: fixed)
        let event = try AISpeakerEvent(request: f.request, slot: "A", name: "タダシ", evidence: evidence, recordedAt: Date())
        let bytes = try AIJSON.encode(event)
        let target = try f.files.directory(f.base + ["inbox"]).appendingPathComponent(event.filename)
        let other = f.root.appendingPathComponent("other")
        try f.files.write(bytes, to: ["other"])
        switch kind {
        case "symlink": try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other)
        case "hardlink": #expect(link(other.path, target.path) == 0)
        case "fifo": #expect(mkfifo(target.path, 0o600) == 0)
        default: try f.files.write(bytes, to: f.base + ["inbox", event.filename]); #expect(chmod(target.path, 0o644) == 0)
        }
        #expect(throws: (any Error).self) {
            try ReturnCommand(f.args("speaker", ["--slot", "A", "--name", "タダシ"]))
                .execute(input: { Data(evidence.utf8) }, environment: [:])
        }
        #expect(throws: (any Error).self) { try AIInbox(outputDirectory: f.root).readSpeaker(filename: event.filename, for: f.request) }
        #expect(try Data(contentsOf: other) == bytes)
    }
    @Test func 実バイナリがstdinの根拠を保存する() throws {
        let f = try ReturnCommandTests.Fixture(slot: 2, identification: fixed)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = repo.appendingPathComponent(".build/debug/kikigaki-cli")
        process.arguments = f.args("speaker", ["--slot", "A", "--name", "タダシ"])
        var env = ProcessInfo.processInfo.environment; env["CODEX_THREAD_ID"] = nil
        process.environment = env; process.standardInput = input; process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(evidence.utf8)); try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try AIInbox(outputDirectory: f.root).readSpeaker(filename: "\(f.request.id).speaker.A.json", for: f.request).evidence == evidence)
    }
}
