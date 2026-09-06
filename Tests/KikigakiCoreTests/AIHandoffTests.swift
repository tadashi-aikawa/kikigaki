import Foundation
import Testing
@testable import KikigakiCore

@Suite struct AIHandoffTests {
    private func utterances(_ texts: [String]) -> [Utterance] {
        texts.enumerated().map { Utterance(speaker: 0, start: Double($0 * 10), end: Double($0 * 10 + 5), text: $1) }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kikigaki-handoff-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func json(_ copy: HandoffCopy) throws -> [String: Any] {
        let fenced = try #require(copy.prompt.components(separatedBy: "```json\n").last)
        let body = try #require(fenced.components(separatedBy: "\n```").first)
        return try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    @Test func 初回追記訂正改名は変更行以降を渡し固定ファイルを維持する() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var history = HandoffHistory()
        let names = SpeakerNames()
        let initial = utterances(["最初", "暫定"])
        let first = try #require(history.copy(utterances: initial, names: names, outputDirectory: dir) { _ in true })
        let originalFile = try String(contentsOf: first.fileURL, encoding: .utf8)
        #expect(first.preview.isFull)
        #expect(first.preview.startLine == 1)
        #expect(first.preview.lineCount == 2)
        #expect(!first.preview.includesCorrections)
        #expect(try json(first)["kind"] as? String == "full")
        #expect(try json(first)["previous_snapshot_id"] == nil)
        let appended = utterances(["最初", "暫定", "追加"])
        let second = try #require(history.copy(utterances: appended, names: names, outputDirectory: dir) { _ in true })
        #expect(second.preview.startLine == 3)
        #expect(second.preview.lineCount == 1)
        #expect(second.preview.startTime == 20)
        #expect(!second.preview.includesCorrections)
        #expect(try json(second)["previous_snapshot_id"] as? String == first.snapshotID.uuidString)
        let corrected = utterances(["最初", "訂正", "追加"])
        let third = try #require(history.copy(utterances: corrected, names: names, outputDirectory: dir) { _ in true })
        #expect(third.preview.startLine == 2)
        #expect(third.preview.lineCount == 2)
        #expect(third.preview.includesCorrections)
        let renamed = try #require(history.preview(utterances: corrected, names: SpeakerNames([0: "タダシ"])))
        #expect(renamed.startLine == 1)
        #expect(renamed.includesCorrections)
        #expect(try String(contentsOf: first.fileURL, encoding: .utf8) == originalFile)
        #expect(first.fileURL != second.fileURL)
        #expect(first.meetingID == second.meetingID)
    }

    @Test func 同一内容は更新せず全文コピーと再コピーは可能で再コピーは基準を進めない() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var history = HandoffHistory()
        let initial = utterances(["本文"])
        let first = try #require(history.copy(utterances: initial, names: .init(), outputDirectory: dir) { _ in true })
        #expect(history.preview(utterances: initial, names: .init()) == nil)
        #expect(try history.copy(utterances: initial, names: .init(), outputDirectory: dir) { _ in
            Issue.record("変更なしでクリップボードを変更した")
            return true
        } == nil)
        var copiedPrompt = ""
        #expect(try history.recopy { copiedPrompt = $0; return true } == first)
        #expect(copiedPrompt == first.prompt)
        #expect(history.lastCopy == first)
        let full = try #require(history.copy(utterances: initial, names: .init(), outputDirectory: dir, full: true) { _ in true })
        #expect(full.preview.isFull)
        #expect(full.snapshotID != first.snapshotID)
        #expect(try json(full)["previous_snapshot_id"] == nil)
        let next = try #require(history.copy(utterances: utterances(["本文", "続き"]), names: .init(), outputDirectory: dir) { _ in true })
        #expect(try json(next)["previous_snapshot_id"] as? String == full.snapshotID.uuidString)
    }

    @Test func 統合と解除で結合行が変わってもAIへ訂正として渡す() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var history = HandoffHistory()
        let tokens = [TimedToken(text: "前半", phraseId: 1, start: 1, end: 2),
                      TimedToken(text: "後半", phraseId: 1, start: 2, end: 3)]
        let raw: [Int?] = [0, 2]
        let firstLines = Aligner.utterances(tokens: tokens, speakers: raw)
        let first = try #require(history.copy(utterances: firstLines, names: .init(), outputDirectory: dir) { _ in true })
        let merged = Aligner.utterances(tokens: tokens, speakers: SpeakerMapping(overrides: [2: 0]).apply(raw))
        let correction = try #require(history.copy(utterances: merged, names: .init(), outputDirectory: dir) { _ in true })
        #expect(correction.preview.includesCorrections)
        #expect(correction.preview.startLine == 1)
        #expect(correction.preview.totalLineCount == 1)
        #expect(try String(contentsOf: correction.fileURL, encoding: .utf8).contains("話者A: 前半後半"))
        let restored = try #require(history.copy(utterances: firstLines, names: .init(), outputDirectory: dir) { _ in true })
        #expect(restored.preview.includesCorrections)
        #expect(restored.preview.totalLineCount == 2)
        #expect(try String(contentsOf: first.fileURL, encoding: .utf8).contains("話者C: 後半"))
    }

    @Test func 空の初回は無効で末尾削除と全削除はゼロ行更新になる() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var history = HandoffHistory()
        #expect(history.preview(utterances: [], names: .init(), full: true) == nil)
        #expect(try history.recopy { _ in true } == nil)
        _ = try history.copy(utterances: utterances(["一", "二"]), names: .init(), outputDirectory: dir) { _ in true }
        let truncated = try #require(history.copy(utterances: utterances(["一"]), names: .init(), outputDirectory: dir) { _ in true })
        #expect(truncated.preview.startLine == 2)
        #expect(truncated.preview.startTime == 10)
        #expect(truncated.preview.lineCount == 0)
        #expect(truncated.preview.totalLineCount == 1)
        #expect(truncated.preview.includesCorrections)
        let empty = try #require(history.copy(utterances: [], names: .init(), outputDirectory: dir) { _ in true })
        #expect(empty.preview.startLine == 1)
        #expect(empty.preview.lineCount == 0)
        #expect(empty.preview.totalLineCount == 0)
        #expect(try Data(contentsOf: empty.fileURL).isEmpty)
        #expect(history.preview(utterances: [], names: .init()) == nil)
        #expect(history.preview(utterances: [], names: .init(), full: true)?.isFull == true)
    }

    @Test func 保存失敗とクリップボード失敗は成功履歴を保持する() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var history = HandoffHistory()
        let initial = utterances(["前回"])
        let changed = utterances(["前回", "追加"])
        let first = try #require(history.copy(utterances: initial, names: .init(), outputDirectory: dir) { _ in true })
        let blocked = dir.appendingPathComponent("file")
        try Data().write(to: blocked)
        #expect(throws: HandoffError.self) {
            try history.copy(utterances: changed, names: .init(), outputDirectory: blocked) { _ in
                Issue.record("保存失敗後にクリップボードを変更した")
                return true
            }
        }
        #expect(history.lastCopy == first)
        #expect(throws: HandoffError.self) {
            try history.copy(utterances: changed, names: .init(), outputDirectory: dir) { prompt in
                let metadata = try? JSONSerialization.jsonObject(with: Data(prompt.components(separatedBy: "```json\n")[1].components(separatedBy: "\n```")[0].utf8)) as? [String: Any]
                #expect(FileManager.default.fileExists(atPath: metadata?["transcript_path"] as? String ?? ""))
                return false
            }
        }
        #expect(history.lastCopy == first)
        #expect(history.preview(utterances: changed, names: .init())?.startLine == 2)
        #expect(throws: HandoffError.self) { try history.recopy { _ in false } }
        #expect(history.lastCopy == first)
        try FileManager.default.removeItem(at: first.fileURL)
        #expect(throws: HandoffError.self) { try history.recopy { _ in
            Issue.record("ファイル消失後に再コピーした")
            return true
        } }
        #expect(history.lastCopy == first)
    }

    @Test func 特殊な保存先はJSONから復元でき発話本文はプロンプトへ混入しない() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let special = dir.appendingPathComponent("日本語 空白 \"引用\" ```\n改行")
        let start = Date(timeIntervalSince1970: 0)
        var history = HandoffHistory(startedAt: start)
        let copy = try #require(history.copy(utterances: utterances(["秘密の会話\n二行目"]), names: SpeakerNames([0: "人\n名"]), outputDirectory: special) { _ in true })
        let metadata = try json(copy)
        #expect(Set(metadata.keys) == Set(["schema_version", "meeting_id", "snapshot_id", "sequence", "kind", "transcript_path", "read_start_line", "read_line_count", "total_line_count"]))
        #expect(metadata["transcript_path"] as? String == copy.fileURL.path)
        #expect(metadata["schema_version"] as? Int == 1)
        #expect(copy.prompt.components(separatedBy: "```").count == 3)
        #expect(copy.prompt.contains("\\u0060"))
        #expect(!copy.prompt.contains("秘密の会話"))
        let stamp = MeetingTimeline(startedAt: start).clock(at: 0, seconds: true)
        #expect(try String(contentsOf: copy.fileURL, encoding: .utf8) == "[\(stamp)] 人 名: 秘密の会話 二行目\n")
        var newMeeting = HandoffHistory()
        let fresh = try #require(newMeeting.copy(utterances: utterances(["次の会議"]), names: .init(), outputDirectory: special) { _ in true })
        #expect(fresh.meetingID != copy.meetingID)
        #expect(fresh.preview.isFull)
    }

    @Test func 専用ディレクトリは既存も非公開にし通常Markdownを維持する() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = dir.appendingPathComponent(".kikigaki-context")
        try FileManager.default.createDirectory(at: context, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let regular = dir.appendingPathComponent("meeting.md")
        try "通常の会議".write(to: regular, atomically: true, encoding: .utf8)
        let parentPermissions = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        var history = HandoffHistory()
        let first = try #require(history.copy(utterances: utterances(["一"]), names: .init(), outputDirectory: dir) { _ in true })
        let meeting = first.fileURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: meeting.path)
        _ = try history.copy(utterances: utterances(["一", "二"]), names: .init(), outputDirectory: dir) { _ in true }
        for url in [context, meeting] {
            #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o700)
        }
        #expect(try FileManager.default.attributesOfItem(atPath: first.fileURL.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int == parentPermissions)
        #expect(try String(contentsOf: regular, encoding: .utf8) == "通常の会議")
    }

    @Test func 専用ディレクトリのシンボリックリンクを拒否する() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let permissions = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(".kikigaki-context"), withDestinationURL: target)
        var history = HandoffHistory()
        #expect(throws: HandoffError.self) {
            try history.copy(utterances: utterances(["一"]), names: .init(), outputDirectory: dir) { _ in
                Issue.record("リンク経由でコピーした")
                return true
            }
        }
        #expect(history.lastCopy == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        #expect(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int == permissions)
    }

    @Test func 初回クリップボード失敗後の再試行も全文になる() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var history = HandoffHistory()
        #expect(throws: HandoffError.self) {
            try history.copy(utterances: utterances(["本文"]), names: .init(), outputDirectory: dir) { _ in false }
        }
        #expect(history.lastCopy == nil)
        #expect(history.preview(utterances: utterances(["本文"]), names: .init())?.isFull == true)
        let retry = try #require(history.copy(utterances: utterances(["本文"]), names: .init(), outputDirectory: dir) { _ in true })
        #expect(try json(retry)["previous_snapshot_id"] == nil)
        #expect(retry.sequence == 1)
    }

    @Test func 連番は成功コピーだけ進み全文も通算し再コピーと新会議を区別する() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var history = HandoffHistory()
        let initial = utterances(["本文"])
        let changed = utterances(["本文", "追加"])
        let first = try #require(history.copy(utterances: initial, names: .init(), outputDirectory: dir) { _ in true })
        #expect(first.sequence == 1)
        #expect(try json(first)["sequence"] as? Int == 1)
        #expect(try history.copy(utterances: initial, names: .init(), outputDirectory: dir) { _ in true } == nil)
        #expect(throws: HandoffError.self) {
            try history.copy(utterances: changed, names: .init(), outputDirectory: dir) { _ in false }
        }
        let blocked = dir.appendingPathComponent("file")
        try Data().write(to: blocked)
        #expect(throws: HandoffError.self) {
            try history.copy(utterances: changed, names: .init(), outputDirectory: blocked) { _ in true }
        }
        #expect(history.lastCopy?.sequence == 1)
        let second = try #require(history.copy(utterances: changed, names: .init(), outputDirectory: dir) { _ in true })
        #expect(second.sequence == 2)
        #expect(try json(second)["sequence"] as? Int == 2)
        let full = try #require(history.copy(utterances: changed, names: .init(), outputDirectory: dir, full: true) { _ in true })
        #expect(full.sequence == 3)
        #expect(try json(full)["sequence"] as? Int == 3)
        let repeated = try #require(history.recopy { _ in true })
        #expect(repeated == full)
        #expect(try json(repeated)["sequence"] as? Int == 3)
        let afterRecopy = try #require(history.copy(utterances: initial, names: .init(), outputDirectory: dir) { _ in true })
        #expect(afterRecopy.sequence == 4)
        var nextMeeting = HandoffHistory()
        let fresh = try #require(nextMeeting.copy(utterances: initial, names: .init(), outputDirectory: dir) { _ in true })
        #expect(fresh.sequence == 1)
        #expect(fresh.meetingID != first.meetingID)
    }

    @Test func 保存後に会議ディレクトリをリンクへ差し替えたらコピーも再コピーも拒否する() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var history = HandoffHistory()
        let first = try #require(history.copy(utterances: utterances(["本文"]), names: .init(), outputDirectory: dir) { _ in true })
        let meeting = first.fileURL.deletingLastPathComponent()
        let moved = dir.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: meeting, to: moved)
        try FileManager.default.createSymbolicLink(at: meeting, withDestinationURL: moved)
        #expect(throws: HandoffError.self) { try history.recopy { _ in
            Issue.record("リンク経由で再コピーした")
            return true
        } }
        #expect(throws: HandoffError.self) {
            try history.copy(utterances: utterances(["本文", "追加"]), names: .init(), outputDirectory: dir) { _ in true }
        }
        #expect(history.lastCopy == first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).count == 1)
    }
}
