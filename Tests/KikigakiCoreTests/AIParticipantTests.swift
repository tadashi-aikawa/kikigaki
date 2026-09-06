import Darwin
import Foundation
import Testing
@testable import KikigakiCore

private let epoch = Date(timeIntervalSince1970: 0)

private func request(meeting: UUID = UUID(), stream: UUID = UUID(), generation: Int = 1,
                     id: UUID = UUID(), number: Int = 1, question: String = "質問", root: URL = URL(fileURLWithPath: "/tmp/ai-test"),
                     parent: UUID? = nil, tail: AITentativeTail? = nil) throws -> AIRequest {
    var history = try AIStreamHistory(meetingID: meeting, streamID: stream, sessionGeneration: generation)
    let snapshot = try history.prepare(lines: ["[00:00:00] 話者A: 元の会話"], outputDirectory: root)
    let participant = AIParticipantContext(streamID: stream, requestID: id, sessionGeneration: generation,
        participantName: "迅雷", cliPath: "/Applications/KIKIGAKI.app/Contents/Helpers/kikigaki-cli",
        sessionPath: root.appendingPathComponent(".kikigaki-context/\(meeting.uuidString)/ai/sessions/\(generation).json").path,
        requestToken: "test-only-token", question: question, capturedAt: epoch, audioCutoffSeconds: 10,
        tentativeTail: tail, inReplyToRequestID: parent, inReplyToEventID: parent.map { "\($0.uuidString)/result" })
    return try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant), number: number, voiceQuestion: "声の問い", snapshot: snapshot)
}

@Suite struct AIConfigTests {
    @Test func 対象時刻は範囲両端から固定しUUIDを表示しない() throws {
        var history = try AIStreamHistory(meetingID: UUID())
        let first = try history.prepare(lines: ["[14:00:00] A: 前回"], outputDirectory: URL(fileURLWithPath: "/tmp/ai-test"))
        try history.acknowledge(snapshotID: first.id, streamID: first.streamID, sessionGeneration: 1)
        let next = try history.prepare(lines: first.lines + ["[23:59:59] A: 前", "[00:00:01] B: 後"], outputDirectory: URL(fileURLWithPath: "/tmp/ai-test"))
        #expect(next.timeRange?.start == "23:59:59")
        #expect(next.timeRange?.end == "00:00:01")
        let r = try request()
        var conversation = AIConversation(meetingID: r.envelope.meetingID)
        try conversation.append(r)
        let markdown = AIMarkdown.section(conversation)
        #expect(markdown.contains("対象: 1〜1行(00:00:00〜00:00:00)"))
        #expect(!markdown.contains(r.envelope.snapshotID.uuidString))
        #expect(try AIJSON.decode(AIRequest.self, from: AIJSON.encode(r)) == r)
    }

    @Test(arguments: ["", "[24:00:00] A", "[00:60:00] A", "[00:00:60] A", "[0:00:00] A", "本文 [12:00:00]"])
    func 不正時刻は範囲へ補完しない(_ line: String) throws {
        var history = try AIStreamHistory(meetingID: UUID())
        let snapshot = try history.prepare(lines: [line, "[12:01:00] A: 有効"], outputDirectory: URL(fileURLWithPath: "/tmp/ai-test"))
        #expect(snapshot.timeRange == nil)
    }

    @Test func 未設定は無効で空テーブルは既定値で有効() throws {
        #expect(try ConfigLoader.parse(toml: "").ai == nil)
        let config = try ConfigLoader.parse(toml: "[ai]")
        let resolved = ResolvedConfig(config: config, home: URL(fileURLWithPath: "/home/test"))
        #expect(resolved.ai?.cli == .codex)
        #expect(resolved.ai?.participantName == "迅雷")
        #expect(resolved.ai?.cwd.path == "/home/test/Library/Application Support/KIKIGAKI/ai-work")
        #expect(resolved.ai?.notifySound == false)
        #expect(resolved.ai?.hotkey == ResolvedAIConfig.defaultHotkey)
    }

    @Test func 設定を全項目解釈しホームを引数から解決する() throws {
        let parsed = try ConfigLoader.parse(toml: """
        [ai]
        cli = "claude"
        command = "/test/Claude Code"
        model = "test-model"
        address = "参加者へ"
        cwd = "~/project"
        extraArgs = ["--effort", "high"]
        prompt = "短く答える"
        notifySound = true
        [ai.hotkey]
        modifiers = ["command", "shift"]
        key = "j"
        """)
        let ai = try #require(ResolvedConfig(config: parsed, home: URL(fileURLWithPath: "/home/person")).ai)
        #expect(ai.cli == .claude && ai.command == "/test/Claude Code" && ai.model == "test-model")
        #expect(ai.cwd.path == "/home/person/project" && ai.participantName == "参加者")
        #expect(ai.notifySound && ai.extraArgs == ["--effort", "high"])
    }

    @Test(arguments: ["cli = 'unknown'", "command = 'codex'", "cwd = './work'", "model = ''", "address = 'へ'",
                      "notifySound = 'yes'", "extraArgs = ['--model=x']"])
    func 不正設定を拒否する(_ field: String) throws {
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: "[ai]\n" + field) }
    }

    @Test func 改行とサイズ超過と既存キーとの衝突を拒否する() throws {
        #expect(throws: ConfigError.self) { try AIConfig(address: "人\n名").validate() }
        #expect(throws: ConfigError.self) { try AIConfig(address: " へ ").validate() }
        #expect(throws: ConfigError.self) { try AIConfig(prompt: String(repeating: "あ", count: 10923)).validate() }
        #expect(throws: ConfigError.self) {
            try ConfigLoader.parse(toml: "[ai.hotkey]\nmodifiers=['control','option','command']\nkey='K'")
        }
        #expect(throws: ConfigError.self) {
            try ConfigLoader.parse(toml: "[ai.hotkey]\nmodifiers=['invalid']\nkey='j'")
        }
    }

    @Test(arguments: ["--settings=x", "--setting-sources=user", "--safe-mode", "--bare", "--bg", "-p", "--resume=x", "--model=x", "--", "prompt"])
    func Claudeの接続契約を壊す追加指定を拒否(_ argument: String) {
        #expect(throws: ConfigError.self) { try AIExtraArguments.validate([argument], provider: .claude) }
    }

    @Test(arguments: ["exec", "resume", "--remote=ws://test", "-cnotify=[]", "--config=notify=[]", "--cd=/tmp", "-mx", "--profile=other"])
    func Codexの衝突と結合短縮引数を拒否(_ argument: String) {
        #expect(throws: ConfigError.self) { try AIExtraArguments.validate([argument], provider: .codex) }
    }

    @Test func 対応する追加引数の値も検証する() throws {
        try AIExtraArguments.validate(["--sandbox=workspace-write", "--search", "--add-dir", "/tmp/test"], provider: .codex)
        try AIExtraArguments.validate(["--effort", "high", "--permission-mode=auto"], provider: .claude)
        #expect(throws: ConfigError.self) { try AIExtraArguments.validate(["--effort"], provider: .claude) }
        #expect(throws: ConfigError.self) { try AIExtraArguments.validate(["--effort=no"], provider: .claude) }
        #expect(throws: ConfigError.self) { try AIExtraArguments.validate(["--add-dir", "relative"], provider: .codex) }
        #expect(throws: ConfigError.self) { try AIExtraArguments.validate(["--effort", "--settings"], provider: .claude) }
    }
}

@Suite struct AIInboxTests {
    private func fixture() throws -> (URL, AIRequest, URL, AIReceiveEvent) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kikigaki-inbox-" + UUID().uuidString)
        let r = try request(root: root)
        var directory = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in [".kikigaki-context", r.envelope.meetingID.uuidString, "ai", "inbox"] {
            directory.appendPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let event = try AIReceiveEvent(request: r, kind: .answered, recordedAt: epoch, body: "返送")
        let file = directory.appendingPathComponent(event.filename)
        try AIJSON.encode(event).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return (root, r, file, event)
    }

    @Test func 指定した基点だけから正当なイベントを読む() throws {
        let (root, r, _, event) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try AIInbox(outputDirectory: root).read(filename: event.filename, for: r) == event)
        #expect(throws: AIError.self) { try AIInbox(outputDirectory: root).read(filename: "../" + event.filename, for: r) }
        #expect(throws: AIError.self) { try AIInbox(outputDirectory: root, ownerID: getuid() + 1).read(filename: event.filename, for: r) }
        #expect(throws: AIError.self) { try AIInbox(outputDirectory: root.appendingPathComponent("missing")).read(filename: event.filename, for: r) }
    }

    @Test(arguments: ["symlink", "hardlink", "directory", "fifo", "permission"])
    func 不正なファイルを読み込まない(_ kind: String) throws {
        let (root, r, file, event) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("other")
        switch kind {
        case "symlink":
            try FileManager.default.moveItem(at: file, to: other)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        case "hardlink": try FileManager.default.linkItem(at: file, to: other)
        case "directory":
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        case "fifo":
            try FileManager.default.removeItem(at: file)
            #expect(mkfifo(file.path, 0o600) == 0)
        default: try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        }
        #expect(throws: AIError.self) { try AIInbox(outputDirectory: root).read(filename: event.filename, for: r) }
    }

    @Test func 階層のリンク差替と公開権限を拒否し変更しない() throws {
        let (root, r, file, event) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = file.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inbox.path)
        #expect(throws: AIError.self) { try AIInbox(outputDirectory: root).read(filename: event.filename, for: r) }
        #expect(try FileManager.default.attributesOfItem(atPath: inbox.path)[.posixPermissions] as? Int == 0o755)
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: inbox, to: moved)
        try FileManager.default.createSymbolicLink(at: inbox, withDestinationURL: moved)
        #expect(throws: AIError.self) { try AIInbox(outputDirectory: root).read(filename: event.filename, for: r) }
    }

    @Test func サイズ上限とマルチバイト境界をバイト数で検証() throws {
        let r = try request()
        let exact = String(repeating: "a", count: AILimits.bodyBytes - 3) + "あ"
        let event = try AIReceiveEvent(request: r, kind: .answered, recordedAt: epoch, body: exact)
        #expect(try AIInbox.decode(AIJSON.encode(event), filename: event.filename, for: r) == event)
        #expect(throws: AIError.tooLarge) { try AIReceiveEvent(request: r, kind: .answered, recordedAt: epoch, body: exact + "a") }
        #expect(throws: AIError.tooLarge) { try AIInbox.decode(Data(repeating: 32, count: AILimits.eventBytes + 1), filename: event.filename, for: r) }
    }

    @Test(arguments: ["schema_version", "meeting_id", "request_id", "snapshot_id", "session_generation", "event_id", "kind", "context_received", "body"])
    func JSONの契約違反で状態へ入れない(_ key: String) throws {
        let r = try request()
        let event = try AIReceiveEvent(request: r, kind: .answered, recordedAt: epoch, body: "返送")
        var json = try #require(JSONSerialization.jsonObject(with: AIJSON.encode(event)) as? [String: Any])
        switch key {
        case "schema_version", "session_generation": json[key] = 99
        case "meeting_id", "request_id", "snapshot_id": json[key] = UUID().uuidString
        case "context_received": json[key] = false
        case "body": json.removeValue(forKey: key)
        default: json[key] = "unknown"
        }
        #expect(throws: (any Error).self) {
            try AIInbox.decode(JSONSerialization.data(withJSONObject: json), filename: event.filename, for: r)
        }
    }

    @Test func 壊れたJSONと誤ファイル名と実ファイルの過大サイズを拒否() throws {
        let (root, r, file, event) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) { try AIInbox.decode(Data("{".utf8), filename: event.filename, for: r) }
        #expect(throws: AIError.mismatch) { try AIInbox.decode(AIJSON.encode(event), filename: "other.result.json", for: r) }
        try Data(repeating: 32, count: AILimits.eventBytes + 1).write(to: file)
        #expect(throws: AIError.tooLarge) { try AIInbox(outputDirectory: root).read(filename: event.filename, for: r) }
    }
}

@Suite struct AIMarkdownTests {
    @Test func 実時刻で印を合成し同時刻は人間を先に置く() throws {
        let r = try request(question: "問い\n続き")
        var c = AIConversation(meetingID: r.envelope.meetingID)
        try c.append(r)
        try c.update(r.id) { try $0.beginSending(at: epoch); try $0.submitted() }
        try c.receive(AIReceiveEvent(request: r, kind: .answered, recordedAt: epoch.addingTimeInterval(2), body: "本文\n\n## 回答内の見出し"), at: epoch.addingTimeInterval(2))
        let m = MeetingMarkdown.Meeting(startedAt: epoch, duration: 2,
            utterances: [.init(speaker: 0, start: 0, end: 1, text: "声")], names: .init(), ai: c)
        let rendered = MeetingMarkdown.render(m, timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(rendered.contains("- [00:00:00] 話者A: 声\n- [00:00:00] AIへ質問 Q1 → AIとのやりとり"))
        #expect(rendered.contains("- [00:00:02] AI回答 Q1 → AIとのやりとり"))
        #expect(rendered.components(separatedBy: "- 問い:").count == 2)
        #expect(rendered.contains("- 問い: 「問い 続き」"))
        #expect(rendered.hasSuffix("本文\n\n## 回答内の見出し\n"))
        #expect(!rendered.contains("test-only-token") && !rendered.contains("Helpers"))
    }

    @Test func 日付跨ぎと一時停止を反映し改名でもAI本文を変えない() throws {
        let r = try request()
        var c = AIConversation(meetingID: r.envelope.meetingID)
        try c.append(r)
        try c.update(r.id) { try $0.beginSending(at: epoch.addingTimeInterval(86401)) }
        try c.receive(AIReceiveEvent(request: r, kind: .answered, recordedAt: epoch.addingTimeInterval(86402), body: "話者Aの案"), at: epoch.addingTimeInterval(86402))
        var m = MeetingMarkdown.Meeting(startedAt: epoch, duration: 2,
            utterances: [.init(speaker: 0, start: 1, end: 2, text: "発話")], names: .init(),
            pauses: [.init(audioTime: 1, duration: 86400)], ai: c)
        m.names = SpeakerNames([0: "新しい名前"])
        let rendered = MeetingMarkdown.render(m, timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(rendered.contains("- [1970-01-02 00:00:01] AIへ質問"))
        #expect(rendered.contains("新しい名前: 発話"))
        #expect(rendered.contains("話者Aの案"))
    }

    @Test func 通常とrawに同じAI節を出して改名後も維持() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kikigaki-ai-markdown-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try request()
        var c = AIConversation(meetingID: r.envelope.meetingID)
        try c.append(r)
        try c.update(r.id) { try $0.beginSending(at: epoch) }
        try c.receive(AIReceiveEvent(request: r, kind: .answered, recordedAt: epoch, body: "話者Aへの回答"), at: epoch)
        let original = MeetingMarkdown.Meeting(startedAt: epoch, duration: 2,
            utterances: [.init(speaker: 0, start: 0, end: 2, text: "うんうん")], names: .init(), ai: c)
        let file = root.appendingPathComponent("meeting.md")
        var archive = MeetingArchive(original: original, processed: [.init(speaker: 0, start: 0, end: 2, text: "うん")], candidateCount: 1, markdownURL: file)
        #expect(archive.save().succeeded)
        archive.original.names = SpeakerNames([0: "改名"])
        #expect(archive.save().succeeded)
        let normal = try String(contentsOf: file, encoding: .utf8)
        let raw = try String(contentsOf: MeetingFiles.rawURL(for: file), encoding: .utf8)
        #expect(normal.components(separatedBy: "## AIとのやりとり").last == raw.components(separatedBy: "## AIとのやりとり").last)
        #expect(normal.contains("話者Aへの回答") && raw.contains("話者Aへの回答"))
        #expect(normal.contains("改名: うん") && raw.contains("改名: うんうん"))
    }
}

@Suite struct AIStreamTests {
    @Test func 不正なsnapshotの行番号を計算前に拒否する() throws {
        let r = try request()
        let snapshot = AIContextSnapshot(id: r.envelope.snapshotID, meetingID: r.envelope.meetingID,
            streamID: r.envelope.participant.streamID, sessionGeneration: 1, sequence: 1, previousSnapshotID: nil,
            kind: .full, fileURL: URL(fileURLWithPath: r.envelope.transcriptPath), readStartLine: Int.min, lines: ["本文"])
        #expect(throws: AIError.self) { try AIEnvelope(snapshot: snapshot, participant: r.envelope.participant) }
    }
    @Test func 空会話は明示入力だけ送れ同じsnapshotの別質問を許す() throws {
        var history = try AIStreamHistory(meetingID: UUID())
        let root = URL(fileURLWithPath: "/tmp/empty")
        let snapshot = try history.prepare(lines: [], outputDirectory: root)
        func context(_ question: String) -> AIParticipantContext {
            AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1, participantName: "迅雷",
                cliPath: "/Applications/Test.app/Contents/Helpers/kikigaki-cli",
                sessionPath: root.appendingPathComponent(".kikigaki-context/\(history.meetingID.uuidString)/ai/sessions/1.json").path,
                requestToken: "token", question: question, capturedAt: epoch, audioCutoffSeconds: 0)
        }
        let first = try AIEnvelope(snapshot: snapshot, participant: context("問い1"))
        let second = try AIEnvelope(snapshot: snapshot, participant: context("問い2"))
        #expect(first.snapshotID == second.snapshotID && first.participant.requestID != second.participant.requestID)
        #expect(first.readStartLine == 1 && first.readLineCount == 0)
        #expect(throws: AIError.self) { try AIEnvelope(snapshot: snapshot, participant: context("")) }
    }

    @Test func 受領後でも未受領の次snapshotを発行したら再試行は全文() throws {
        var h = try AIStreamHistory(meetingID: UUID())
        let root = URL(fileURLWithPath: "/tmp/retry")
        let first = try h.prepare(lines: ["一"], outputDirectory: root)
        try h.acknowledge(snapshotID: first.id, streamID: h.streamID, sessionGeneration: 1)
        _ = try h.prepare(lines: ["一", "二"], outputDirectory: root)
        let retry = try h.prepare(lines: ["一", "二", "三"], outputDirectory: root)
        #expect(retry.kind == .full && retry.sequence == 3 && h.received == first)
    }

    @Test func 未受領は基準にならず失敗後は新しい番号の全文() throws {
        var history = try AIStreamHistory(meetingID: UUID())
        let root = URL(fileURLWithPath: "/tmp/test")
        let first = try history.prepare(lines: ["一"], outputDirectory: root)
        #expect(history.received == nil)
        let retry = try history.prepare(lines: ["一", "二"], outputDirectory: root)
        #expect(retry.sequence == 2 && retry.kind == .full && retry.previousSnapshotID == nil)
        try history.acknowledge(snapshotID: retry.id, streamID: history.streamID, sessionGeneration: 1)
        try history.acknowledge(snapshotID: first.id, streamID: history.streamID, sessionGeneration: 1)
        #expect(history.received == retry)
        #expect(try history.prepare(lines: retry.lines, outputDirectory: root) == retry)
    }

    @Test func 追記訂正末尾削除と全削除を別streamの受領基準で計算する() throws {
        var h = try AIStreamHistory(meetingID: UUID())
        let root = URL(fileURLWithPath: "/tmp/test")
        let first = try h.prepare(lines: ["一", "旧"], outputDirectory: root)
        try h.acknowledge(snapshotID: first.id, streamID: h.streamID, sessionGeneration: 1)
        let changed = try h.prepare(lines: ["一", "訂正", "三"], outputDirectory: root)
        #expect(changed.kind == .update && changed.readStartLine == 2 && changed.readLineCount == 2)
        #expect(changed.previousSnapshotID == first.id)
        try h.acknowledge(snapshotID: changed.id, streamID: h.streamID, sessionGeneration: 1)
        let removed = try h.prepare(lines: ["一"], outputDirectory: root)
        #expect(removed.readStartLine == 2 && removed.readLineCount == 0)
        try h.acknowledge(snapshotID: removed.id, streamID: h.streamID, sessionGeneration: 1)
        let empty = try h.prepare(lines: [], outputDirectory: root)
        #expect(empty.readStartLine == 1 && empty.readLineCount == 0 && empty.contents.isEmpty)
        #expect(first.lines == ["一", "旧"])
    }

    @Test func 別世代と別streamの受領を拒否し新世代は全文() throws {
        let meeting = UUID()
        var h = try AIStreamHistory(meetingID: meeting)
        let snapshot = try h.prepare(lines: ["本文"], outputDirectory: URL(fileURLWithPath: "/tmp/test"))
        #expect(throws: AIError.mismatch) { try h.acknowledge(snapshotID: snapshot.id, streamID: UUID(), sessionGeneration: 1) }
        #expect(throws: AIError.mismatch) { try h.acknowledge(snapshotID: snapshot.id, streamID: h.streamID, sessionGeneration: 2) }
        var next = try AIStreamHistory(meetingID: meeting, sessionGeneration: 2)
        #expect(try next.prepare(lines: snapshot.lines, outputDirectory: URL(fileURLWithPath: "/tmp/test")).kind == .full)
        #expect(next.streamID != h.streamID)
    }

    @Test func 手動履歴と会議IDだけ共有し基準を混ぜない() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID()
        var manual = HandoffHistory(startedAt: epoch, meetingID: meeting)
        var ai = try AIStreamHistory(meetingID: meeting)
        let first = try ai.prepare(lines: ["AIへ"], outputDirectory: root)
        let copy = try #require(manual.copy(utterances: [.init(speaker: 0, start: 0, end: 1, text: "手動")], names: .init(), outputDirectory: root) { _ in true })
        #expect(copy.meetingID == first.meetingID && ai.received == nil)
        try ai.acknowledge(snapshotID: first.id, streamID: ai.streamID, sessionGeneration: 1)
        #expect(manual.lastCopy == copy)
        #expect(!copy.prompt.contains("participant"))
    }

    @Test func 暫定末尾は付帯JSONだけに入りsnapshotへ混ざらない() throws {
        let tail = AITentativeTail(text: "仮の依頼", startSeconds: 8, endSeconds: 10)
        let r = try request(question: "", tail: tail)
        #expect(r.envelope.participant.questionSource == .voice)
        #expect(r.envelope.totalLineCount == 1)
        #expect(try r.envelope.prompt().contains("仮の依頼"))
        #expect(r.displayQuestion == "声の問い")
        #expect(throws: AIError.self) { try request(tail: .init(text: "仮", startSeconds: 8, endSeconds: 11)) }
    }

    @Test func 特殊文字をJSON内へ閉じ込めIDとパスを復元できる() throws {
        let root = URL(fileURLWithPath: "/tmp/日本語 空白 \" ```\n")
        let r = try request(question: "```\n$() `command`", root: root)
        let prompt = try r.envelope.prompt(extraPrompt: "追加の指示")
        #expect(prompt.hasPrefix("$kikigaki\n迅雷へ\n\nKIKIGAKI_CONTEXT"))
        #expect(prompt.components(separatedBy: "```").count == 3)
        #expect(prompt.hasSuffix("追加プロンプト:\n追加の指示"))
        let json = prompt.components(separatedBy: "```json\n")[1].components(separatedBy: "\n```")[0]
        let decoded = try AIJSON.decode(AIEnvelope.self, from: Data(json.utf8))
        #expect(decoded == r.envelope)
        #expect(!prompt.contains("元の会話"))
    }
}

@Suite struct AIStateTests {
    @Test func 送信試行を先に記録して受領前の回答と後着通知で巻き戻さない() throws {
        let r = try request()
        var q = try AIQuestion(request: r)
        #expect(throws: AIError.invalidTransition) { try q.submitted() }
        try q.beginSending(at: epoch)
        #expect(q.state == .deliveryUnknown)
        let answer = try AIReceiveEvent(request: r, kind: .answered, recordedAt: epoch, body: "回答")
        try q.receive(answer, at: epoch, order: 1)
        #expect(q.state == .answered && q.contextReceived && q.isUnread)
        try q.submitted()
        try q.receive(AIReceiveEvent(request: r, kind: .accept, recordedAt: epoch), at: epoch, order: 2)
        #expect(q.state == .answered)
        q.markRead()
        #expect(!q.isUnread)
    }

    @Test func 同本文の再送は時刻が違っても二重追加せず異本文を拒否() throws {
        let r = try request()
        var conversation = AIConversation(meetingID: r.envelope.meetingID)
        try conversation.append(r)
        try conversation.update(r.id) { try $0.beginSending(at: epoch) }
        let first = try AIReceiveEvent(request: r, kind: .answered, recordedAt: epoch, body: "先の回答")
        #expect(try conversation.receive(first, at: epoch))
        try conversation.update(r.id) { $0.markRead() }
        let same = try AIReceiveEvent(request: r, kind: .answered, recordedAt: epoch.addingTimeInterval(5), body: "先の回答")
        #expect(try !conversation.receive(same, at: epoch))
        #expect(!conversation.questions[0].isUnread)
        let different = try AIReceiveEvent(request: r, kind: .answered, recordedAt: epoch, body: "別の回答")
        #expect(throws: AIError.conflict) { try conversation.receive(different, at: epoch) }
        #expect(conversation.questions[0].result == first)
    }

    @Test func 取消後と旧世代の回答は元質問に残る() throws {
        let r = try request()
        var c = AIConversation(meetingID: r.envelope.meetingID)
        try c.append(r)
        try c.update(r.id) { try $0.beginSending(at: epoch); try $0.cancel(at: epoch) }
        let next = try request(meeting: r.envelope.meetingID, generation: 2, number: 2)
        try c.append(next)
        try c.receive(AIReceiveEvent(request: r, kind: .answered, recordedAt: epoch, body: "旧回答"), at: epoch)
        #expect(c.questions[0].state == .cancelled && c.questions[0].result?.body == "旧回答")
        #expect(c.questions[1].state == .prepared && c.questions[1].result == nil)
        #expect(AIMarkdown.section(c).contains("取消後の回答"))
        #expect(AIMarkdown.section(c).contains("旧接続からの回答"))
    }

    @Test func 確認質問への返答を新requestで結び元の結果を上書きしない() throws {
        let r = try request()
        var c = AIConversation(meetingID: r.envelope.meetingID)
        try c.append(r)
        try c.update(r.id) { try $0.beginSending(at: epoch) }
        let clarification = try AIReceiveEvent(request: r, kind: .needsInput, recordedAt: epoch, body: "対象は？", reason: "clarification")
        try c.receive(clarification, at: epoch)
        let next = try request(meeting: r.envelope.meetingID, number: 2, parent: r.id)
        try c.append(next)
        #expect(c.questions[0].state == .needsInput && c.questions[0].result == clarification)
        #expect(c.questions[0].answeredByRequestID == nil)
        try c.update(next.id) { try $0.beginSending(at: epoch) }
        #expect(c.questions[0].answeredByRequestID == next.id)
        #expect(throws: AIError.self) { try c.append(request(meeting: r.envelope.meetingID, number: 3, parent: UUID())) }
    }

    @Test func 文脈不足と読み取り失敗を受領成功にしない() throws {
        let r = try request()
        let missing = try AIReceiveEvent(request: r, kind: .needsInput, recordedAt: epoch, body: "全文を", reason: "context_missing")
        let failed = try AIReceiveEvent(request: r, kind: .failed, recordedAt: epoch, body: "読めない", reason: "read_failed")
        #expect(!missing.contextReceived && !failed.contextReceived)
        var q = try AIQuestion(request: r)
        try q.beginSending(at: epoch)
        try q.receive(missing, at: epoch, order: 1)
        #expect(!q.contextReceived && q.state == .needsInput)
    }

    @Test func 未送信失敗と送達不明を区別し再送しない() throws {
        let r = try request()
        var q = try AIQuestion(request: r)
        try q.failBeforeSending("起動できない")
        #expect(q.state == .failed && q.sendAttemptedAt == nil)
        #expect(throws: AIError.invalidTransition) { try q.beginSending(at: epoch) }
        var sent = try AIQuestion(request: r)
        try sent.beginSending(at: epoch)
        #expect(throws: AIError.invalidTransition) { try sent.failBeforeSending("不明") }
        #expect(throws: AIError.invalidTransition) { try sent.beginSending(at: epoch) }
    }

    @Test func 休止の猶予と未返送を補助表示にして背景処理とblockedを除く() throws {
        var q = try AIQuestion(request: request())
        try q.beginSending(at: epoch)
        #expect(!AIReturnStatus.isUnconfirmed(question: q, connection: .idle, idleSince: epoch, now: epoch.addingTimeInterval(4), hasRunningBackgroundTasks: false))
        #expect(AIReturnStatus.isUnconfirmed(question: q, connection: .idle, idleSince: epoch, now: epoch.addingTimeInterval(5), hasRunningBackgroundTasks: false))
        #expect(!AIReturnStatus.isUnconfirmed(question: q, connection: .blocked, idleSince: epoch, now: epoch.addingTimeInterval(10), hasRunningBackgroundTasks: false))
        #expect(!AIReturnStatus.isUnconfirmed(question: q, connection: .idle, idleSince: epoch, now: epoch.addingTimeInterval(10), hasRunningBackgroundTasks: true))
        #expect(q.state == .deliveryUnknown)
    }

    @Test func 永続化往復後も重複排除と取消を保持する() throws {
        let r = try request()
        var c = AIConversation(meetingID: r.envelope.meetingID)
        try c.append(r)
        try c.update(r.id) { try $0.beginSending(at: epoch); try $0.cancel(at: epoch) }
        let event = try AIReceiveEvent(request: r, kind: .answered, recordedAt: epoch, body: "保存済み")
        try c.receive(event, at: epoch)
        var restored = try AIJSON.decode(AIConversation.self, from: AIJSON.encode(c))
        #expect(restored == c)
        #expect(try !restored.receive(event, at: epoch))
    }

    @Test(arguments: ["schema_version", "next_event_order", "state"])
    func 壊れた保存状態を復元しない(_ key: String) throws {
        let r = try request()
        var c = AIConversation(meetingID: r.envelope.meetingID)
        try c.append(r)
        var json = try #require(JSONSerialization.jsonObject(with: AIJSON.encode(c)) as? [String: Any])
        if key == "state" {
            var questions = try #require(json["questions"] as? [[String: Any]])
            questions[0]["state"] = "answered"
            json["questions"] = questions
        } else { json[key] = 0 }
        #expect(throws: (any Error).self) {
            try AIJSON.decode(AIConversation.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test func 別質問へのすり替えと取消済み未送信を拒否する() throws {
        let r = try request()
        var c = AIConversation(meetingID: r.envelope.meetingID)
        try c.append(r)
        let other = try AIQuestion(request: request(meeting: r.envelope.meetingID))
        #expect(throws: AIError.mismatch) { try c.update(r.id) { $0 = other } }
        #expect(c.questions[0].request == r)
        try c.update(r.id) { try $0.cancel(at: epoch) }
        #expect(throws: AIError.invalidTransition) { try c.update(r.id) { try $0.beginSending(at: epoch) } }
        #expect(throws: AIError.invalidTransition) {
            try c.receive(AIReceiveEvent(request: r, kind: .answered, recordedAt: epoch, body: "未送信"), at: epoch)
        }
    }
}
