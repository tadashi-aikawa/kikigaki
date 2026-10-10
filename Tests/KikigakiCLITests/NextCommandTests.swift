import Darwin
import Foundation
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import KikigakiCLI

struct NextCommandTests {
    struct Fixture {
        let root: URL
        let store: NextMeetingStore
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCommandTests-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = NextMeetingStore(directory: root.appendingPathComponent("next"))
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
    @Test func 登録一覧削除は設定を読まず一件ずつ保存する() throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(try NextCommand(["next", "list"]).execute(store: f.store).isEmpty)
        let now = Date(timeIntervalSince1970: 0)
        let command = try NextCommand(["next", "add", "--minutes", "/未作成/定例 '$().md", "--title", "定例",
                                       "--at", "09:05", "--ai", "設定に無い宛先"])
        let id = try #require(command.execute(store: f.store, now: now, timeZone: TimeZone(secondsFromGMT: 0)!).first)
        let second = try #require(NextCommand(["next", "add", "--minutes", "/次.md"])
            .execute(store: f.store, now: now.addingTimeInterval(1)).first)
        let lines = try NextCommand(["next", "list"]).execute(store: f.store)
        #expect(lines == ["\(id)\t1970-01-01T09:05\t定例\t設定に無い宛先\t/未作成/定例 '$().md", "\(second)\t-\t-\t-\t/次.md"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.store.directory.path).sorted() == [id + ".json", second + ".json"].sorted())
        let attributes = try FileManager.default.attributesOfItem(atPath: f.store.directory.appendingPathComponent(id + ".json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try NextCommand(["next", "remove", id]).execute(store: f.store).isEmpty)
        #expect(try f.store.load().meetings.map(\.id.uuidString) == [second])
        #expect(throws: NextCommand.Failure.missing) { try NextCommand(["next", "remove", id]).execute(store: f.store) }
    }
    @Test func チルダを展開し日付指定を保存する() throws {
        let f = try Fixture(); defer { f.cleanup() }
        _ = try NextCommand(["next", "add", "--minutes", "~/未作成.md", "--at", "2026-10-11T13:30"]).execute(store: f.store)
        let meeting = try #require(f.store.load().meetings.first)
        #expect(meeting.minutesPath == ("~/未作成.md" as NSString).expandingTildeInPath)
        #expect(meeting.at == "2026-10-11T13:30")
    }
    @Test(arguments: ["relative.md", "/tmp/a.txt", "/tmp/../a.md", "/tmp/.kikigaki-context/a.md", "~someone/a.md"])
    func 不正な議事録は保存しない(_ path: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(throws: NextCommand.Failure.invalidPath) { try NextCommand(["next", "add", "--minutes", path]).execute(store: f.store) }
        #expect(!FileManager.default.fileExists(atPath: f.store.directory.path))
    }
    @Test(arguments: ["9:30", "25:00", "2026-02-30T12:00", "2026-10-10T12:00:00"])
    func 不正な時刻は保存しない(_ at: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(throws: NextCommand.Failure.invalidAt) { try NextCommand(["next", "add", "--minutes", "/a.md", "--at", at]).execute(store: f.store) }
        #expect(try f.store.load().meetings.isEmpty)
    }
    @Test func 引数の不足重複と未知の指定を拒否する() {
        for args in [["next"], ["next", "unknown"], ["next", "add"], ["next", "add", "--minutes"],
                     ["next", "add", "--minutes", "/a.md", "--minutes", "/b.md"],
                     ["next", "add", "--minutes", "/a.md", "--bad", "x"],
                     ["next", "list", "extra"], ["next", "remove"], ["next", "remove", "not-id"]] {
            #expect(throws: NextCommand.Failure.arguments) { try NextCommand(args) }
        }
    }
    @Test func 失効と消費は残す予約を壊さず再読込できる() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let old = try NextMeeting(minutesPath: "/old.md", createdAt: Date(timeIntervalSince1970: 0))
        let recent = try NextMeeting(minutesPath: "/recent.md", createdAt: Date(timeIntervalSince1970: 1))
        try f.store.add(old); try f.store.add(recent)
        #expect(try f.store.expire(now: Date(timeIntervalSince1970: 86_400)).meetings == [recent])
        #expect(try f.store.load().meetings == [recent])
        try f.store.consume(id: UUID())
        #expect(try f.store.load().meetings == [recent])
        let duplicate = try NextMeeting(minutesPath: recent.minutesPath, createdAt: Date(timeIntervalSince1970: 2))
        try f.store.add(duplicate)
        try f.store.consume(id: recent.id)
        #expect(try f.store.load().meetings == [duplicate])
        try f.store.consume(id: recent.id)
        #expect(try f.store.load().meetings == [duplicate])
        try f.store.consume(id: duplicate.id)
        #expect(try f.store.load().meetings.isEmpty)
    }
    @Test func ミリ秒未満の登録順も保存後に保つ() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = try NextMeeting(minutesPath: "/a.md", createdAt: Date(timeIntervalSince1970: 1000.000125))
        let b = try NextMeeting(minutesPath: "/b.md", createdAt: Date(timeIntervalSince1970: 1000.000250))
        try f.store.add(b); try f.store.add(a)
        #expect(try f.store.load().meetings == [a, b])
    }
    @Test func 壊れたファイルを飛ばし原子的な保存は既存予約を置換しない() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = try NextMeeting(minutesPath: "/a.md", createdAt: Date(timeIntervalSince1970: 123))
        try f.store.add(a)
        #expect(throws: AIError.conflict) { try f.store.add(a) }
        let files = AIFileStore(root: f.root)
        try files.write(Data("壊れたJSON".utf8), to: ["next", UUID().uuidString + ".json"])
        try FileManager.default.createSymbolicLink(at: f.store.directory.appendingPathComponent(UUID().uuidString + ".json"),
                                                   withDestinationURL: f.store.directory.appendingPathComponent(a.id.uuidString + ".json"))
        #expect(try f.store.load().meetings == [a])
    }
    @Test func 試験版と本番の保存先を分ける() throws {
        let home = URL(fileURLWithPath: "/tmp/home")
        #expect(NextMeetingStore.supportDirectory(home: home, bundleIdentifier: nil).path == "/tmp/home/Library/Application Support/KIKIGAKI")
        #expect(NextMeetingStore.supportDirectory(home: home, bundleIdentifier: "com.tadashi-aikawa.kikigaki.trial").path == "/tmp/home/Library/Application Support/KIKIGAKI-Trial")
    }
    @Test func 実バイナリのhelpと引数エラーは予約へ書かない() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (arguments, status, message) in [(["--help"], Int32(0), "kikigaki-cli next add"),
                                              (["next", "remove", "bad-id"], Int32(1), "kikigaki-cli: usage:")] {
            let process = Process(), output = Pipe(), error = Pipe()
            process.executableURL = source.appendingPathComponent(".build/debug/kikigaki-cli")
            process.arguments = arguments; process.standardOutput = output; process.standardError = error
            try process.run(); process.waitUntilExit()
            #expect(process.terminationStatus == status)
            let bytes = (status == 0 ? output : error).fileHandleForReading.readDataToEndOfFile()
            #expect(String(decoding: bytes, as: UTF8.self).contains(message))
        }
    }
    @Test func 同梱helperの親アプリから試験版の識別子を読む() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let app = f.root.appendingPathComponent("KIKIGAKI-Trial.app")
        let helpers = app.appendingPathComponent("Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.tadashi-aikawa.kikigaki.trial"],
                                                      format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        #expect(NextMeetingStore.bundledIdentifier(executable: helpers.appendingPathComponent("kikigaki-cli")) == "com.tadashi-aikawa.kikigaki.trial")
    }
    @Test(arguments: ["symlink", "permissions"])
    func 不正な予約ファイルをremoveで消さない(_ kind: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = try NextMeeting(minutesPath: "/a.md")
        try f.store.add(a)
        let target = f.store.directory.appendingPathComponent(a.id.uuidString + ".json")
        if kind == "permissions" {
            #expect(chmod(target.path, 0o644) == 0)
        } else {
            let other = f.root.appendingPathComponent("other.json")
            try FileManager.default.moveItem(at: target, to: other)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other)
        }
        #expect(throws: AIError.unsafeFile) { try f.store.remove(a.id) }
        #expect(FileManager.default.fileExists(atPath: target.path))
    }
}
