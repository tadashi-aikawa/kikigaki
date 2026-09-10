import Darwin
import Foundation
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import KikigakiCLI

@Suite struct MinutesRevisionTests {
    @Test func 第二世代の通知と世代不一致を検証する() throws {
        let f = try ReturnCommandTests.Fixture(generation: 2)
        let command = try ReturnCommand(f.args("minutes", ["--path", "/tmp/議事録.md"]))
        _ = try command.execute(input: { Data() }, environment: [:])
        #expect(try AIInbox(outputDirectory: f.root).readMinutes(filename: f.request.id.uuidString + ".minutes.json", for: f.request).sessionGeneration == 2)
        try f.files.write(AIJSON.encode(AISessionRecord(meetingID: f.session.meetingID, generation: 1, provider: .codex, token: "secret")), to: f.base + ["sessions", "2.json"])
        #expect(throws: AIError.mismatch) { try command.execute(input: { Data() }, environment: [:]) }
    }

    @Test func 別requestと会議とsession階層を拒否する() throws {
        let f = try ReturnCommandTests.Fixture(), other = try ReturnCommandTests.Fixture()
        var args = f.args("minutes", ["--path", "/tmp/議事録.md"])
        args[4] = other.request.id.uuidString
        try f.files.write(AIJSON.encode(other.request), to: f.base + ["requests", other.request.id.uuidString + ".json"])
        #expect(throws: (any Error).self) { try ReturnCommand(args).execute(input: { Data() }, environment: [:]) }
        for broken in ["/ai/session/1.json", "/ai/sessions/0/1.json", "/ai/sessions/01.json"] {
            args = f.args("minutes", ["--path", "/tmp/議事録.md"])
            args[2] = f.path.replacingOccurrences(of: "/ai/sessions/1.json", with: broken)
            #expect(throws: AIError.unsafeFile) { try ReturnCommand(args).execute(input: { Data() }, environment: [:]) }
        }
        try f.files.write(AIJSON.encode(other.session), to: f.base + ["sessions", "1.json"])
        #expect(throws: AIError.mismatch) { try ReturnCommand(f.args("minutes", ["--path", "/tmp/議事録.md"])).execute(input: { Data() }, environment: [:]) }
    }

    @Test func 親fsync失敗後の同じ通知を耐久化して返す() throws {
        let f = try ReturnCommandTests.Fixture()
        let command = try ReturnCommand(f.args("minutes", ["--path", "/tmp/a.md"]))
        #expect(throws: AIError.unsafeFile) {
            try command.execute(input: { Data() }, environment: [:], makeFileStore: { root in
                AIFileStore(root: root, sync: { fd in
                    var value = stat()
                    if fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFDIR { return -1 }
                    return fsync(fd)
                })
            })
        }
        let original = try AIInbox(outputDirectory: f.root).readMinutes(filename: f.request.id.uuidString + ".minutes.json", for: f.request)
        #expect(try command.execute(input: { Data() }, environment: [:]) == original.eventID)
        #expect(try AIInbox(outputDirectory: f.root).readMinutes(filename: original.filename, for: f.request) == original)
    }

    @Test func 所有者と欠損階層の従来契約を保つ() throws {
        let f = try ReturnCommandTests.Fixture()
        let command = try ReturnCommand(f.args("minutes", ["--path", "/tmp/a.md"]))
        #expect(throws: AIError.unsafeFile) {
            try command.execute(input: { Data() }, environment: [:], makeFileStore: { AIFileStore(root: $0, owner: getuid() + 1) })
        }
        #expect(throws: AIError.unsafeFile) { try f.files.read(["missing", "state.json"]) }
        #expect(throws: AIFileError.missing) { try AIFileStore(root: f.root, allowsMissingParents: true).read(["missing", "state.json"]) }
        try FileManager.default.removeItem(at: URL(fileURLWithPath: f.path).deletingLastPathComponent())
        #expect(throws: AIError.unsafeFile) { try command.execute(input: { Data() }, environment: [:]) }
    }

    @Test func path引数の許可とinvalidPathを区別する() throws {
        let f = try ReturnCommandTests.Fixture()
        for action in ["accept", "reply"] {
            let extra = ["--path", "/tmp/a.md"] + (action == "reply" ? ["--kind", "answered"] : [])
            #expect(throws: (any Error).self) { try ReturnCommand(f.args(action, extra)) }
        }
        for path in ["relative.md", "/tmp/.KIKIGAKI-CONTEXT/a.md", "/tmp/\u{200D}.md"] {
            #expect(throws: MinutesCommandError.invalidPath) { try ReturnCommand(f.args("minutes", ["--path", path])).execute(input: { Data() }, environment: [:]) }
        }
    }
}
