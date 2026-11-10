import Foundation
import Testing
@testable import KikigakiCore

/// AIへ渡す `image_dirs` と、画面の行の遅着の差分。仕様は docs/ai-handoff.md の「画像の参照」と
/// docs/ai-participant.md の「Envelopeと差分の基準」
@Suite struct AIImageDirectoriesTests {
    private let started = Date(timeIntervalSince1970: 1_788_759_600)
    private var timeline: MeetingTimeline { MeetingTimeline(startedAt: started) }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kikigaki-images-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func voice(_ text: String, at start: Double) -> Utterance {
        Utterance(speaker: 0, start: start, end: start + 2, text: text)
    }
    private func screen(_ root: URL, at time: Double) throws -> Utterance {
        try Utterance(screenLabel: "EV3895 · Keynote「提案資料」",
                      imagePath: root.appendingPathComponent("会議.captures/\(Int(time)).webp").path,
                      at: time, postedAt: started.addingTimeInterval(time))
    }
    private func lines(_ rows: [Utterance]) -> [String] {
        let merged = TranscriptEntries.merge(voice: rows.filter { $0.kind == .voice }, typed: rows.filter(\.isEntry), timeline: timeline)
        return TranscriptRenderer.lines(merged.utterances, names: SpeakerNames([0: "田中"]), timeline: timeline)
    }
    private func participant(_ snapshot: AIContextSnapshot, root: URL) -> AIParticipantContext {
        AIParticipantContext(streamID: snapshot.streamID, requestID: UUID(), sessionGeneration: snapshot.sessionGeneration,
            participantName: "迅雷", cliPath: "/Applications/KIKIGAKI.app/Contents/Helpers/kikigaki-cli",
            sessionPath: root.appendingPathComponent(".kikigaki-context/\(snapshot.meetingID.uuidString)/"
                + AIEnvelope.sessionPath(slot: nil, generation: snapshot.sessionGeneration)).path,
            requestToken: UUID().uuidString, question: "この図で合っていますか", capturedAt: started, audioCutoffSeconds: 10)
    }
    private func json(_ prompt: String) throws -> [String: Any] {
        let fenced = try #require(prompt.components(separatedBy: "```json\n").last)
        let body = try #require(fenced.components(separatedBy: "\n```").first)
        return try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    @Test func 会議Markdownから添付と画面の記録の置き場を存在を確かめずに導く() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let markdown = root.appendingPathComponent("2026-11-10_1400.md")
        let directories = MeetingFiles.imageDirectories(for: markdown)
        #expect(directories == [root.appendingPathComponent("2026-11-10_1400.attachments").path,
                                root.appendingPathComponent("2026-11-10_1400.captures").path])
        #expect(!directories.contains { FileManager.default.fileExists(atPath: $0) })
        #expect(MeetingFiles.attachmentsDirectory(for: markdown).path == directories[0])
        #expect(ScreenCaptureFiles.directory(for: markdown).path == directories[1])
        try AIImageDirectories.validate(directories, outputDirectory: root.path)
    }

    @Test func 置き場の形が外れた値は拒む() throws {
        let root = "/保存先"
        for invalid in [
            [String](),
            ["/保存先/会議.captures"],
            ["/保存先/会議.attachments", "/保存先/会議.captures", "/保存先/別.captures"],
            ["/保存先/会議.captures", "/保存先/会議.captures"],
            ["/保存先/会議.captures", "/保存先/会議.attachments"],
            // 別会議の添付と画面の記録の混在。
            ["/保存先/会議A.attachments", "/保存先/会議B.captures"],
            ["/別の場所/会議.attachments", "/別の場所/会議.captures"],
            ["/保存先/sub/会議.attachments", "/保存先/sub/会議.captures"],
            ["/保存先/../会議.attachments", "/保存先/../会議.captures"],
            ["/保存先/会議.attachments/", "/保存先/会議.captures/"],
            ["/保存先/.attachments", "/保存先/.captures"],
            ["保存先/会議.attachments", "保存先/会議.captures"],
            ["/保存先/会議\n.attachments", "/保存先/会議\n.captures"],
        ] {
            #expect(throws: AIError.invalid("image directories")) { try AIImageDirectories.validate(invalid, outputDirectory: root) }
        }
        try AIImageDirectories.validate(["/保存先/会議.attachments", "/保存先/会議.captures"], outputDirectory: root)
    }

    @Test func 会議Markdownが分かる所では別会議の組への差し替えも拒む() throws {
        let other = ["/保存先/会議B.attachments", "/保存先/会議B.captures"]
        // 形だけでは拒めない。
        try AIImageDirectories.validate(other, outputDirectory: "/保存先")
        #expect(throws: AIError.invalid("image directories")) {
            try AIImageDirectories.validate(other, markdownURL: URL(fileURLWithPath: "/保存先/会議A.md"))
        }
        try AIImageDirectories.validate(["/保存先/会議A.attachments", "/保存先/会議A.captures"],
                                        markdownURL: URL(fileURLWithPath: "/保存先/会議A.md"))
    }

    @Test func 会話をコピーのJSONのトップレベルに置き場を載せ_無ければ省く() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let markdown = root.appendingPathComponent("会議.md")
        let directories = MeetingFiles.imageDirectories(for: markdown)
        var history = HandoffHistory()
        let copy = try #require(history.copy(utterances: [voice("この図です", at: 0)], names: .init(), outputDirectory: root,
                                             meetingMarkdown: markdown) { _ in true })
        let metadata = try json(copy.prompt)
        #expect(metadata["image_dirs"] as? [String] == directories)
        #expect(metadata["schema_version"] as? Int == 1)
        let plain = try #require(history.copy(utterances: [voice("この図です", at: 0)], names: .init(), outputDirectory: root) { _ in true })
        #expect(try json(plain.prompt)["image_dirs"] == nil)
        // 会話ファイルと別の保存先の会議の置き場は渡さない。
        #expect(throws: AIError.invalid("image directories")) {
            try history.copy(utterances: [voice("この図です", at: 0)], names: .init(), outputDirectory: root,
                             meetingMarkdown: URL(fileURLWithPath: "/別の場所/会議.md")) { _ in true }
        }
    }

    @Test func 会議参加モードのenvelopeはトップレベルに置き場を載せ_旧requestは置き場なしで読める() throws {
        let root = URL(fileURLWithPath: "/保存先")
        let directories = MeetingFiles.imageDirectories(for: root.appendingPathComponent("会議.md"))
        var history = try AIStreamHistory(meetingID: UUID())
        let snapshot = try history.prepare(lines: ["[14:00:00] 田中: この図です"], outputDirectory: root)
        let envelope = try AIEnvelope(snapshot: snapshot, participant: participant(snapshot, root: root), imageDirectories: directories)
        let decoded = try #require(JSONSerialization.jsonObject(with: AIJSON.encode(envelope)) as? [String: Any])
        #expect(decoded["image_dirs"] as? [String] == directories)
        #expect((decoded["participant"] as? [String: Any])?["image_dirs"] == nil)
        #expect(try json(envelope.prompt())["image_dirs"] as? [String] == directories)
        #expect(try AIJSON.decode(AIEnvelope.self, from: AIJSON.encode(envelope)) == envelope)
        // 旧requestにはキーが無い。
        let old = try AIEnvelope(snapshot: snapshot, participant: participant(snapshot, root: root))
        let oldJSON = try #require(JSONSerialization.jsonObject(with: AIJSON.encode(old)) as? [String: Any])
        #expect(oldJSON["image_dirs"] == nil)
        #expect(try AIJSON.decode(AIEnvelope.self, from: AIJSON.encode(old)).imageDirectories == nil)
        // requestの固定はsnapshotから組み直して照合する。置き場も同じ値でなければ一致しない。
        let request = try AIRequest(envelope: envelope, number: 1, snapshot: snapshot)
        #expect(request.envelope.imageDirectories == directories)
        #expect(throws: AIError.invalid("image directories")) {
            try AIEnvelope(snapshot: snapshot, participant: participant(snapshot, root: root), imageDirectories: ["/別の場所/会議.captures"])
        }
    }

    @Test func 作業中の依頼への追記は元の依頼の置き場を引き継ぐ() throws {
        let root = URL(fileURLWithPath: "/保存先")
        let directories = MeetingFiles.imageDirectories(for: root.appendingPathComponent("会議.md"))
        var history = try AIStreamHistory(meetingID: UUID())
        let snapshot = try history.prepare(lines: ["[14:00:00] 田中: この図です"], outputDirectory: root)
        let request = try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant(snapshot, root: root),
                                                         imageDirectories: directories), number: 1, snapshot: snapshot)
        let nextID = UUID()
        let next = AIContextSnapshot(id: nextID, meetingID: snapshot.meetingID, streamID: snapshot.streamID,
            sessionGeneration: snapshot.sessionGeneration, sequence: 1, previousSnapshotID: snapshot.id, kind: .update,
            fileURL: snapshot.fileURL.deletingLastPathComponent().appendingPathComponent(nextID.uuidString + ".md"),
            readStartLine: 2, lines: snapshot.lines + ["[14:00:05] 画面: EV3895 画像1: `/保存先/会議.captures/140005.webp`"])
        let appendix = AIAppendix(number: 1, requestID: request.id, snapshot: next, question: "", capturedAt: started,
                                  audioCutoffSeconds: 6, tentativeTail: nil, sentAt: started)
        let context = try #require(json(appendix.prompt(for: request))["context"] as? [String: Any])
        #expect(context["image_dirs"] as? [String] == directories)
    }

    @Test func 送信済みの範囲より前に遅れて届いた画面の行は_次の差分で読み直す範囲に入り落ちも二重もしない() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var history = try AIStreamHistory(meetingID: UUID())
        // 1回目の送信: 0秒と10秒の発言。5秒に撮った画面はまだ保存中で公開されていない。
        let first = try history.prepare(lines: lines([voice("では資料を", at: 0), voice("この図を見て", at: 10)]), outputDirectory: root)
        try history.acknowledge(snapshotID: first.id, streamID: first.streamID, sessionGeneration: first.sessionGeneration)
        // 2回目の送信: 5秒の画面の行が公開され、20秒の発言も増えた。
        let late = try screen(root, at: 5)
        let secondLines = lines([voice("では資料を", at: 0), late, voice("この図を見て", at: 10), voice("次へ", at: 20)])
        let second = try history.prepare(lines: secondLines, outputDirectory: root)
        #expect(second.kind == .update)
        #expect(second.readStartLine == 2)
        #expect(second.readLineCount == 3)
        // Skillは read_start_line 以降を置き換える。受け取り側の会話を再現して、落ちも二重も無いことを確かめる。
        var received = first.lines
        received = Array(received.prefix(second.readStartLine - 1)) + Array(second.lines.dropFirst(second.readStartLine - 1))
        #expect(received == secondLines)
        #expect(received.filter { $0.contains("この図を見て") }.count == 1)
        #expect(received.contains { $0.contains("画面:") && $0.contains("会議.captures/5.webp") })
    }

    @Test func 送信の時点で公開されていない画面の行は今回に入れず_次の送信で入る() throws {
        let tokens = [TimedToken(text: "この図を見て", phraseId: 0, start: 1, end: 3)]
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let late = try screen(root, at: 2)
        let before = try AICapture(tokens: tokens, speakers: [0], finalCount: 1, processedUntil: 5, cutoff: 5,
                                   names: SpeakerNames([0: "田中"]), timeline: timeline, typed: [])
        #expect(!before.lines.contains { $0.contains("画面:") })
        let after = try AICapture(tokens: tokens, speakers: [0], finalCount: 1, processedUntil: 6, cutoff: 6,
                                  names: SpeakerNames([0: "田中"]), timeline: timeline, typed: [late])
        #expect(after.lines.contains { $0.contains("画面:") })
        // 送信の時点の音声位置ちょうどの画面は今回に入る。後ろの画面は次の送信へ回す。
        let boundary = try AICapture(tokens: tokens, speakers: [0], finalCount: 1, processedUntil: 2, cutoff: 2,
                                     names: SpeakerNames([0: "田中"]), timeline: timeline, typed: [late, try screen(root, at: 2.5)])
        #expect(boundary.lines.filter { $0.contains("画面:") }.count == 1)
    }
}
