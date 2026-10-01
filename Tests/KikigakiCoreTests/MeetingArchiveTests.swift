import Foundation
import Testing
@testable import KikigakiCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kikigaki-archive-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct MeetingArchiveTests {
    private let original = MeetingMarkdown.Meeting(
        startedAt: Date(timeIntervalSince1970: 1_788_579_600), duration: 3,
        utterances: [Utterance(speaker: 0, start: 0, end: 3, text: "うんうん先週も言ってました。")], names: SpeakerNames())

    @Test func 保存は通常Markdownだけを作り改名を反映する() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try MeetingFiles.reserveMarkdownURL(in: dir, startedAt: original.startedAt)
        var archive = MeetingArchive(original: original, markdownURL: url)
        let saved = archive.save()
        #expect(saved.succeeded && saved.utterances == original.utterances)
        #expect(saved.message == "保存: \(url.path)")
        #expect(try String(contentsOf: url, encoding: .utf8) == MeetingMarkdown.render(original))
        archive.original.names.set("変更した名前", for: 0)
        #expect(archive.save().succeeded)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("変更した名前: うんうん先週"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [url.lastPathComponent])
    }

    // 廃止前の合成Codableと同じキーで保存したarchiveを復元する。
    private struct LegacyArchive: Encodable {
        let original: MeetingMarkdown.Meeting
        let markdownURL: URL
        let processed: [Utterance]
        let candidateCount = 1
        let ownsRawFile = true
        let omissionDisabledAfterFailure: Bool
    }

    @Test(arguments: [false, true])
    func 省略有効時の旧archiveは省略前を表示し既存rawを更新しない(_ failure: Bool) throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("meeting.md")
        let raw = dir.appendingPathComponent("meeting.raw.md")
        let existing = Data("既存の原文".utf8)
        try existing.write(to: raw)
        let legacy = LegacyArchive(original: original, markdownURL: url,
            processed: [.init(speaker: 0, start: 0.5, end: 3, text: "先週も言ってました。")],
            omissionDisabledAfterFailure: failure)
        var archive = try AIJSON.decode(MeetingArchive.self, from: AIJSON.encode(legacy))
        #expect(archive.original.utterances == original.utterances)
        let saved = archive.save()
        #expect(saved.succeeded && saved.utterances == original.utterances)
        #expect(try String(contentsOf: url, encoding: .utf8) == MeetingMarkdown.render(original))
        archive.original.names.set("互換確認", for: 0)
        #expect(archive.save().succeeded)
        #expect(try Data(contentsOf: raw) == existing)
        let restored = try AIJSON.decode(MeetingArchive.self, from: AIJSON.encode(archive))
        #expect(restored.original.utterances == original.utterances)
    }

    @Test func 原文パスが通常ファイルでなくても読み書きせず保存する() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("meeting.md")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("meeting.raw.md"), withIntermediateDirectories: false)
        var archive = MeetingArchive(original: original, markdownURL: url)
        #expect(archive.save().succeeded)
    }

    @Test func 保存失敗でも画面用の発話を返し成功とは報告しない() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("missing/meeting.md")
        var archive = MeetingArchive(original: original, markdownURL: url)
        let saved = archive.save()
        #expect(!saved.succeeded && saved.utterances == original.utterances)
        #expect(saved.message.hasPrefix("保存に失敗"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}

@Suite struct MeetingReservationTests {
    @Test func 予約名は日付と時刻の基底名で録音も同じ基底名() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        // 2026-09-05 12:40 JST
        let startedAt = Date(timeIntervalSince1970: 1_788_579_600)
        let url = try MeetingFiles.reserveMarkdownURL(in: dir, startedAt: startedAt, timeZone: tokyo)
        #expect(url.path == dir.appendingPathComponent("2026-09-05_1240.md").path)
        #expect(MeetingFiles.wavURL(for: url).path == dir.appendingPathComponent("2026-09-05_1240.wav").path)
    }

    @Test(arguments: ["md", "wav", "levels.json"])
    func どの保存物が存在していてもその基底名を再利用しない(_ ext: String) throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date()
        let existing = dir.appendingPathComponent(MeetingFiles.baseName(startedAt: date) + "." + ext)
        try "既存の録音".write(to: existing, atomically: true, encoding: .utf8)
        let first = try MeetingFiles.reserveMarkdownURL(in: dir, startedAt: date)
        let second = try MeetingFiles.reserveMarkdownURL(in: dir, startedAt: date)
        #expect(first.lastPathComponent.hasSuffix("_2.md"))
        #expect(second.lastPathComponent.hasSuffix("_3.md"))
        #expect(MeetingFiles.wavURL(for: first).lastPathComponent.hasSuffix("_2.wav"))
        #expect(try String(contentsOf: existing, encoding: .utf8) == "既存の録音")
    }

    @Test func 旧rawだけが残る基底名は再利用し原文を保持する() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date()
        let raw = dir.appendingPathComponent(MeetingFiles.baseName(startedAt: date) + ".raw.md")
        try "旧原文".write(to: raw, atomically: true, encoding: .utf8)
        let url = try MeetingFiles.reserveMarkdownURL(in: dir, startedAt: date)
        #expect(url.lastPathComponent == MeetingFiles.baseName(startedAt: date) + ".md")
        #expect(try String(contentsOf: raw, encoding: .utf8) == "旧原文")
    }

    @Test func 同時に同じ時刻で予約しても名前が重複しない() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date()
        let urls = try await withThrowingTaskGroup(of: URL.self, returning: [URL].self) { group in
            for _ in 0..<10 { group.addTask { try MeetingFiles.reserveMarkdownURL(in: dir, startedAt: date) } }
            var result: [URL] = []
            for try await url in group { result.append(url) }
            return result
        }
        #expect(Set(urls).count == 10)
    }
}
