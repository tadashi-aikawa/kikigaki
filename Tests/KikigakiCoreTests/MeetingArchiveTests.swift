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
    private let processed = [Utterance(speaker: 0, start: 0.5, end: 3, text: "先週も言ってました。")]

    @Test func 原文を保存してから省略結果を保存し改名は両方に反映する() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try MeetingFiles.reserveMarkdownURL(in: dir, startedAt: original.startedAt)
        var archive = MeetingArchive(original: original, processed: processed, candidateCount: 1, markdownURL: url)
        let saved = archive.save()
        #expect(saved.succeeded)
        #expect(saved.utterances == processed)
        #expect(saved.message == "保存: \(url.path) / 相槌候補1件を省略(原文は .raw.md)")
        #expect(try String(contentsOf: url, encoding: .utf8) == MeetingMarkdown.render(.init(startedAt: original.startedAt, duration: original.duration, utterances: processed, names: original.names)))
        #expect(try String(contentsOf: MeetingFiles.rawURL(for: url), encoding: .utf8) == MeetingMarkdown.render(original))
        archive.original.names.set("変更した名前", for: 0)
        #expect(archive.save().succeeded)
        let raw = try String(contentsOf: MeetingFiles.rawURL(for: url), encoding: .utf8)
        let cleaned = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains("変更した名前: うんうん先週"))
        #expect(cleaned.contains("変更した名前: 先週"))
    }

    @Test func 候補ゼロなら省略通知を出さず原文保存は続ける() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try MeetingFiles.reserveMarkdownURL(in: dir, startedAt: original.startedAt)
        var archive = MeetingArchive(original: original, processed: original.utterances, candidateCount: 0, markdownURL: url)
        let saved = archive.save()
        #expect(saved.succeeded)
        #expect(saved.message == "保存: \(url.path)")
        #expect(try String(contentsOf: MeetingFiles.rawURL(for: url), encoding: .utf8) == MeetingMarkdown.render(original))
    }

    @Test func 統合訂正で省略された本文を両保存先へ復元する() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try MeetingFiles.reserveMarkdownURL(in: dir, startedAt: original.startedAt)
        var archive = MeetingArchive(original: original, processed: processed, candidateCount: 1, markdownURL: url)
        #expect(archive.save().succeeded)
        var utterances = original.utterances
        utterances[0].speaker = 1
        archive.replaceResult(.init(speakers: [1], utterances: utterances, processed: utterances, candidates: []))
        #expect(archive.save().utterances == utterances)
        let raw = try String(contentsOf: MeetingFiles.rawURL(for: url), encoding: .utf8)
        let displayed = try String(contentsOf: url, encoding: .utf8)
        #expect(raw == displayed)
        #expect(raw.contains("話者B: うんうん先週"))
    }

    @Test func 原文保存失敗は省略せず改名時に再試行しても省略しない() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try MeetingFiles.reserveMarkdownURL(in: dir, startedAt: original.startedAt)
        let rawURL = MeetingFiles.rawURL(for: url)
        // 予約後に原文のパスが使えなくなる失敗を再現する。
        try FileManager.default.createDirectory(at: rawURL, withIntermediateDirectories: false)
        var archive = MeetingArchive(original: original, processed: processed, candidateCount: 1, markdownURL: url)
        let saved = archive.save()
        #expect(saved.succeeded)
        #expect(saved.utterances == original.utterances)
        #expect(saved.message.contains("省略を中止"))
        #expect(try String(contentsOf: url, encoding: .utf8) == MeetingMarkdown.render(original))
        try FileManager.default.removeItem(at: rawURL)
        archive.original.names.set("変更した名前", for: 0)
        let renamed = archive.save()
        #expect(renamed.succeeded)
        #expect(renamed.utterances == original.utterances)
        #expect(try String(contentsOf: url, encoding: .utf8) == String(contentsOf: rawURL, encoding: .utf8))
    }

    @Test func 通常ファイルの保存に失敗しても原文は残る() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cannot-write.md")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        var archive = MeetingArchive(original: original, processed: processed, candidateCount: 1, markdownURL: url)
        let saved = archive.save()
        #expect(!saved.succeeded)
        #expect(saved.message.contains("保存に失敗"))
        #expect(try String(contentsOf: MeetingFiles.rawURL(for: url), encoding: .utf8) == MeetingMarkdown.render(original))
    }

    @Test func 両方の保存失敗でも画面用の原文を返し保存成功とは報告しない() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("missing/meeting.md")
        var archive = MeetingArchive(original: original, processed: processed, candidateCount: 1, markdownURL: url)
        let saved = archive.save()
        #expect(!saved.succeeded)
        #expect(saved.utterances == original.utterances)
        #expect(saved.message.hasPrefix("保存に失敗"))
        #expect(!saved.message.contains("省略せず保存:"))
    }

    @Test func 設定無効なら原文ファイルを増やさず従来と同じ結果() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try MeetingFiles.reserveMarkdownURL(in: dir, startedAt: original.startedAt)
        var archive = MeetingArchive(original: original, processed: nil, candidateCount: 0, markdownURL: url)
        #expect(archive.save().succeeded)
        #expect(try String(contentsOf: url, encoding: .utf8) == MeetingMarkdown.render(original))
        #expect(!FileManager.default.fileExists(atPath: MeetingFiles.rawURL(for: url).path))
    }

    @Test func 新規原文パスに既存内容があれば上書きせず通常ファイルに原文を保存() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try MeetingFiles.reserveMarkdownURL(in: dir, startedAt: original.startedAt)
        let rawURL = MeetingFiles.rawURL(for: url)
        try "別の原文".write(to: rawURL, atomically: true, encoding: .utf8)
        var archive = MeetingArchive(original: original, processed: processed, candidateCount: 1, markdownURL: url)
        #expect(archive.save().utterances == original.utterances)
        #expect(try String(contentsOf: rawURL, encoding: .utf8) == "別の原文")
        #expect(try String(contentsOf: url, encoding: .utf8) == MeetingMarkdown.render(original))
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

    @Test(arguments: ["md", "raw.md", "wav"])
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
        #expect(MeetingFiles.rawURL(for: first).lastPathComponent.hasSuffix("_2.raw.md"))
        #expect(try String(contentsOf: existing, encoding: .utf8) == "既存の録音")
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
