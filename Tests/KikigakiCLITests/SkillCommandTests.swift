import Foundation
import Testing
@testable import KikigakiCLI

@Suite struct SkillCommandTests {
    struct Fixture {
        let root: URL, home: URL, app: URL, source: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "skill-command-\(UUID().uuidString)").resolvingSymlinksInPath()
            home = root.appending(path: "home")
            app = root.appending(path: "Applications/KIKIGAKI.app")
            source = app.appending(path: "Contents/Resources/skills/kikigaki")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("skill".utf8).write(to: source.appending(path: "SKILL.md"))
            try FileManager.default.createDirectory(at: app.appending(path: "Contents/Helpers"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        func link(_ relative: String) -> String? { try? FileManager.default.destinationOfSymbolicLink(atPath: home.appending(path: relative).path) }
        func run(_ action: String) throws -> [SkillCommand.Outcome] {
            try SkillCommand(["skill", action]).execute(home: home, source: source).map(\.outcome)
        }
    }

    @Test func 無ければ親ごと張り再実行は変えず外すのは自分のリンクだけ() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(try f.run("install") == [.linked, .linked])
        #expect(f.link(".claude/skills/kikigaki") == f.source.path && f.link(".codex/skills/kikigaki") == f.source.path)
        #expect(try f.run("install") == [.unchanged, .unchanged])
        #expect(try f.run("uninstall") == [.removed, .removed])
        #expect(try f.run("uninstall") == [.absent, .absent])
        #expect(FileManager.default.fileExists(atPath: f.home.appending(path: ".claude/skills").path))
    }

    @Test func 別の場所のKIKIGAKIを指すリンクは張り直し利用者のものは触らない() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let files = FileManager.default
        try files.createDirectory(at: f.home.appending(path: ".claude/skills"), withIntermediateDirectories: true)
        try files.createDirectory(at: f.home.appending(path: ".codex/skills"), withIntermediateDirectories: true)
        // 旧版の.appが消えて切れたリンクも同梱先なら自分のもの。cloneへのリンクは切れていても利用者のもの。
        try files.createSymbolicLink(atPath: f.home.appending(path: ".claude/skills/kikigaki").path,
                                     withDestinationPath: "/Old/KIKIGAKI.app/Contents/Resources/skills/kikigaki")
        try files.createSymbolicLink(atPath: f.home.appending(path: ".codex/skills/kikigaki").path,
                                     withDestinationPath: "/missing/clone/skills/kikigaki")
        #expect(try f.run("install") == [.relinked, .skipped])
        #expect(f.link(".claude/skills/kikigaki") == f.source.path)
        #expect(f.link(".codex/skills/kikigaki") == "/missing/clone/skills/kikigaki")
        #expect(try f.run("uninstall") == [.removed, .skipped])
        #expect(f.link(".codex/skills/kikigaki") == "/missing/clone/skills/kikigaki")

        try files.removeItem(at: f.home.appending(path: ".codex/skills/kikigaki"))
        try files.createDirectory(at: f.home.appending(path: ".codex/skills/kikigaki"), withIntermediateDirectories: true)
        #expect(try f.run("install") == [.linked, .skipped])
        #expect(try f.run("uninstall") == [.removed, .skipped])
        #expect(files.fileExists(atPath: f.home.appending(path: ".codex/skills/kikigaki").path))
    }

    @Test func 同梱先はHelpersのCLIから導き引数を検証する() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(try SkillCommand.bundledSkill(executable: f.app.appending(path: "Contents/Helpers/kikigaki-cli")).path == f.source.path)
        #expect(throws: SkillCommand.Failure.bundledSkillNotFound) {
            try SkillCommand.bundledSkill(executable: f.root.appending(path: ".build/debug/kikigaki-cli"))
        }
        for arguments in [["skill"], ["skill", "remove"], ["skill", "install", "extra"], ["install"]] {
            #expect(throws: SkillCommand.Failure.arguments) { try SkillCommand(arguments) }
        }
    }
}
