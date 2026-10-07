import Darwin
import Foundation
import Testing
@testable import KikigakiCore

@Suite struct PrivateFileIOTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func mode(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    @Test func 新しい階層だけ0700にし既存の親とファイルを変更しない() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        let existing = root.appendingPathComponent("existing")
        try Data("keep".utf8).write(to: existing)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: existing.path)
        let directory = root.appendingPathComponent("new/output")
        try PrivateFileIO.createDirectory(at: directory)
        try PrivateFileIO.createDirectory(at: root)
        #expect(try mode(root) == 0o755)
        #expect(try mode(existing) == 0o644)
        #expect(try Data(contentsOf: existing) == Data("keep".utf8))
        #expect(try mode(directory) == 0o700)
        #expect(try mode(directory.deletingLastPathComponent()) == 0o700)
    }

    @Test func 原子的な保存と排他公開は0600を保ち失敗時に一時物を残さない() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("meeting.md")
        try PrivateFileIO.write(Data("first".utf8), to: url, replacing: false)
        #expect(try mode(url) == 0o600)
        #expect(throws: CocoaError(.fileWriteFileExists)) {
            try PrivateFileIO.write(Data("collision".utf8), to: url, replacing: false)
        }
        #expect(try Data(contentsOf: url) == Data("first".utf8))
        // 旧inodeの別名を保持し、原子的な更新で既存inodeをchmodしないことを確かめる。
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let old = root.appendingPathComponent("old")
        try FileManager.default.linkItem(at: url, to: old)
        try PrivateFileIO.write(Data("updated".utf8), to: url)
        #expect(try mode(url) == 0o600)
        #expect(try mode(old) == 0o644)
        #expect(try Data(contentsOf: old) == Data("first".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["meeting.md", "old"])
    }

    @Test func Markdown予約と本文と音量記録の再保存は0600() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var meter = AudioLevelMeter()
        meter.append([Float](repeating: 0.1, count: 1600))
        let meeting = MeetingMarkdown.Meeting(startedAt: Date(), duration: 1,
            utterances: [Utterance(speaker: 0, start: 0, end: 1, text: "test")], names: SpeakerNames(),
            audioLevels: meter.track())
        let markdown = try MeetingFiles.reserveMarkdownURL(in: root, startedAt: meeting.startedAt)
        #expect(try mode(markdown) == 0o600)
        var archive = MeetingArchive(original: meeting, markdownURL: markdown)
        for _ in 0..<2 {
            let result = archive.save()
            #expect(result.succeeded && result.levelsSucceeded)
            #expect(try mode(markdown) == 0o600)
            #expect(try mode(MeetingFiles.levelsURL(for: markdown)) == 0o600)
        }
    }
}
