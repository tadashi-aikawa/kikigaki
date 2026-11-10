import AppKit
import Testing
@testable import Kikigaki
import KikigakiCore
import KikigakiAIIO

extension AppKitTests {
/// 「会話をコピー」・手動送信・自動送信で同じ `image_dirs` が乗ること、遅れて届いた画面の行が自動送信で落ちも二重もしないこと。
/// 仕様は docs/ai-handoff.md の「画像の参照」と docs/ai-participant.md の「Envelopeと差分の基準」
@Suite(.timeLimit(.minutes(1))) @MainActor struct AIImageDirectoriesAppTests {
    private let display = ScreenDisplay(id: 1, name: "EV3895", points: CGSize(width: 64, height: 36), menuBarFraction: 0)

    private func json(_ prompt: String) throws -> [String: Any] {
        let fenced = try #require(prompt.components(separatedBy: "```json\n").last)
        let body = try #require(fenced.components(separatedBy: "\n```").first)
        return try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }
    private func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        return try #require(context.makeImage())
    }
    private func wait(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }
    /// 10秒分の音声を受け付けた録音中の会議。5秒の位置に発言が1つある。
    /// - outputDir: 設定の `outputDir` に書く文字列。会議Markdownは、設定が解決した保存先から導く。省略時は `root`
    private func session(_ root: URL, fake: FakeHerdr, outputDir: String? = nil) throws -> MeetingSession {
        var config = ResolvedConfig(config: KikigakiConfig(outputDir: outputDir ?? root.path), home: root)
        config.ai = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path), home: root)
        try FileManager.default.createDirectory(at: config.outputDir, withIntermediateDirectories: true)
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { args, timeout in try await fake.run(args, timeout) }) })
        let session = MeetingSession(testingRecordingAt: config.outputDir.appendingPathComponent("meeting.md"), config: config,
                                     aiStore: store, recordedSamples: 160_000)
        session.setScheduleTranscriptForTesting("この図の数字を確認します", start: 5, elapsed: 10)
        return session
    }
    private func reply(_ session: MeetingSession, root: URL) throws {
        let controller = try #require(session.aiRecord?.controller)
        let request = try #require(controller.conversation.questions.last?.request)
        let event = try AIReceiveEvent(request: request, kind: .answered, recordedAt: Date(), body: "確認しました")
        try AIFileStore(root: controller.outputDirectory).write(AIJSON.encode(event), to: [".kikigaki-context", session.aiMeetingID.uuidString,
            "ai", "inbox", request.id.uuidString + ".result.json"], replacing: false)
        controller.scan()
    }
    private func sentLines(_ request: AIRequest) throws -> [String] {
        try String(contentsOfFile: request.envelope.transcriptPath, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    @Test func 会議参加モードの手動と自動で会議Markdownから導いた同じ置き場を載せ_requestの保存にも残す() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let expected = MeetingFiles.imageDirectories(for: root.appendingPathComponent("meeting.md"))
        let config = ResolvedAIConfig(config: AIConfig(cli: .codex, command: "/bin/echo", cwd: root.path), home: root)
        let controller = try testAIController(meetingID: UUID(), outputDirectory: root,
                                              herdr: AIHerdr(run: { _, _ in throw AIHerdrError.notReady }))
        // 送らずに取り消し、次の経路の準備へ進める。値は送信の前に固定済み。
        // 確認への返答と再送も同じ `prepare` を通る。返答は元の確認の受信が要るので、ここでは手動と自動で確かめる。
        func prepare(_ trigger: AIParticipantContext.Trigger?) throws -> AIRequest {
            let request = try controller.prepare(lines: ["[12:00:00] A: この図を見て"], question: "確認", voiceQuestion: "",
                capturedAt: Date(), cutoff: 1, tail: nil, config: config, helper: URL(fileURLWithPath: "/bin/echo"), trigger: trigger)
            try controller.cancel(request.id)
            return request
        }
        for request in [try prepare(nil), try prepare(.scheduled)] {
            #expect(request.envelope.imageDirectories == expected)
            #expect(try json(request.envelope.prompt())["image_dirs"] as? [String] == expected)
            let stored = try AIFileStore(root: root).read([".kikigaki-context", controller.meetingID.uuidString, "ai", "requests",
                                                           request.id.uuidString + ".json"])
            #expect(try AIJSON.decode(AIRequest.self, from: stored).envelope.imageDirectories == expected)
        }
    }

    @Test func 回収したrequestの置き場が同じ保存先の別会議を指していれば拒む() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meetingID = UUID()
        var history = try AIStreamHistory(meetingID: meetingID)
        let snapshot = try history.prepare(lines: ["[12:00:00] A: この図を見て"], outputDirectory: root)
        let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: "迅雷", cliPath: "/Applications/KIKIGAKI.app/Contents/Helpers/kikigaki-cli",
            sessionPath: root.appendingPathComponent(".kikigaki-context/\(meetingID.uuidString)/ai/sessions/1.json").path,
            requestToken: UUID().uuidString, question: "確認", capturedAt: Date(), audioCutoffSeconds: 1)
        func conversation(_ markdown: String?) throws -> AIConversation {
            let envelope = try AIEnvelope(snapshot: snapshot, participant: participant,
                                          imageDirectories: markdown.map { MeetingFiles.imageDirectories(for: root.appendingPathComponent($0)) })
            var value = AIConversation(meetingID: meetingID)
            try value.append(AIRequest(envelope: envelope, number: 1, snapshot: snapshot))
            return value
        }
        // 形は正しいので、会議Markdownを知らない検証は通る。
        let swapped = try conversation("別の会議.md")
        _ = try AIJSON.decode(AIConversation.self, from: AIJSON.encode(swapped))
        let adapter = AIHerdr(run: { _, _ in throw AIHerdrError.notReady })
        #expect(throws: AIError.invalid("image directories")) {
            try testAIController(meetingID: meetingID, outputDirectory: root, herdr: adapter, recovered: swapped)
        }
        _ = try testAIController(meetingID: meetingID, outputDirectory: root, herdr: adapter, recovered: try conversation("meeting.md"))
        // `image_dirs` の無い旧requestは照合せずに回収する。
        _ = try testAIController(meetingID: meetingID, outputDirectory: root, herdr: adapter, recovered: try conversation(nil))
    }

    /// 会話ファイルの行の画像参照の親が `image_dirs` のどれかと文字列で一致し、`image_dirs` の親が会話ファイルの保存先と一致すること。
    /// Skillはこの2つを文字列で照合する。
    private func expectSameNotation(transcriptPath: String, imageDirectories: [String]?, expected: [String]) throws {
        let directories = try #require(imageDirectories)
        #expect(directories == expected)
        let saved = URL(fileURLWithPath: transcriptPath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        #expect(directories.allSatisfy { URL(fileURLWithPath: $0).deletingLastPathComponent().path == saved })
        let text = try String(contentsOfFile: transcriptPath, encoding: .utf8)
        let regex = try Regex("画像[0-9]+: `([^`]+)`")
        let references = text.matches(of: regex).compactMap { $0.output[1].substring.map(String.init) }
        // 画面の記録と手入力の添付の両方の置き場を指す参照があること。
        #expect(Set(references.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }) == Set(directories))
        for reference in references {
            #expect(FileManager.default.fileExists(atPath: reference))
            #expect(directories.contains(URL(fileURLWithPath: reference).deletingLastPathComponent().path))
        }
    }

    /// 設定の `outputDir` の書き方を変えても、3経路で行の画像参照の親と `image_dirs` と会話ファイルの保存先が文字列で一致する。
    /// - 空: `/private/tmp/…` そのまま。`standardizedFileURL` はファイルが在るとき `/tmp` に変える
    /// - `.`、末尾のスラッシュ、重なったスラッシュ: 設定の解決で1回だけ字句上で畳む。`..` は設定エラーなのでここへ来ない
    /// - 結合文字で始まる名前: 区切りと1文字にまとめず、そのまま保つ
    @Test(arguments: ["", "/./meeting", "/meeting/", "//meeting", "/\u{0301}会議/./meeting"])
    func 保存先の書き方によらず_3経路で会話ファイルと置き場と画像参照の表記がそろう(suffix: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(root.path.hasPrefix("/private/tmp/"))
        let fake = FakeHerdr(), session = try session(root, fake: fake, outputDir: root.path + suffix)
        defer { session.stopAISchedule() }
        let markdown = try #require(session.snapshot.markdownURL)
        #expect(markdown.path == LexicalPath.normalized(markdown.path) && markdown.path.hasPrefix("/private/tmp/"))
        let expected = MeetingFiles.imageDirectories(for: markdown)
        #expect(expected.allSatisfy { !$0.contains("/./") && !$0.contains("/../") && !$0.contains("//") })
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: markdown)
        recorder.observeForTesting(try image(), observedAt: Date().addingTimeInterval(-2), label: "EV3895 · Keynote「提案資料」")
        await wait { !session.screenEntriesForTesting.isEmpty }
        let shot = try #require(session.screenEntriesForTesting.first?.imagePaths.first)
        #expect(FileManager.default.fileExists(atPath: shot) && shot.hasPrefix("/private/tmp/"))
        // 手入力の添付も同じ置き場の決まりに乗る。
        let png = try #require(NSBitmapImageRep(cgImage: try image()).representation(using: .png, properties: [:]))
        #expect(session.submitTyped("この画像も見て", images: [try TypedImageDraft(data: png)]))

        var copied: [String] = []
        session.copyContext(writeClipboard: { copied.append($0); return true })
        let metadata = try json(try #require(copied.first))
        let copyPath = try #require(metadata["transcript_path"] as? String)
        #expect(copyPath.hasPrefix("/private/tmp/"))
        try expectSameNotation(transcriptPath: copyPath, imageDirectories: metadata["image_dirs"] as? [String], expected: expected)

        try session.startAISchedule(options: .init(prompt: "議事録を更新", sendFinal: false), helper: URL(fileURLWithPath: "/bin/echo"))
        await session.submissionTaskForTesting?.value
        let scheduled = try #require(session.aiRecord?.controller.conversation.questions.last?.request)
        #expect(scheduled.trigger == .scheduled)
        try expectSameNotation(transcriptPath: scheduled.envelope.transcriptPath, imageDirectories: scheduled.envelope.imageDirectories,
                               expected: expected)
        try reply(session, root: root)
        session.stopAISchedule()

        session.submitAI(question: "この図で合っていますか", full: true, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"))
        await session.submissionTaskForTesting?.value
        let manual = try #require(session.aiRecord?.controller.conversation.questions.last?.request)
        #expect(manual.trigger == nil && manual.id != scheduled.id)
        try expectSameNotation(transcriptPath: manual.envelope.transcriptPath, imageDirectories: manual.envelope.imageDirectories,
                               expected: expected)
        await wait { recorder.pendingForTesting == 0 }
    }

    @Test func 送信済みの発言より前に遅れて届いた画面は_次の自動送信で1回だけ送り受領後は送り直さない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), session = try session(root, fake: fake), now = Date()
        defer { session.stopAISchedule() }
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: root.appendingPathComponent("meeting.md"))
        try session.startAISchedule(options: .init(prompt: "議事録を更新", sendFinal: false), helper: URL(fileURLWithPath: "/bin/echo"), now: now)
        await session.submissionTaskForTesting?.value
        let first = try #require(session.aiRecord?.controller.conversation.questions.first?.request)
        #expect(try sentLines(first).count == 1)
        try reply(session, root: root)
        // 9秒前に観測した画面。音声位置は1秒で、送信済みの5秒の発言より前に公開される。
        recorder.observeForTesting(try image(), observedAt: Date().addingTimeInterval(-9), label: "EV3895 · Keynote「提案資料」")
        await wait { !session.screenEntriesForTesting.isEmpty }
        let late = try #require(session.screenEntriesForTesting.first)
        #expect(late.start < 5)
        // 期限は最初の送信の実時刻から一間隔後。開始の時刻ちょうどの一間隔後では数ミリ秒足りない。
        session.evaluateAISchedule(now: now.addingTimeInterval(200)); await session.submissionTaskForTesting?.value
        let questions = try #require(session.aiRecord?.controller.conversation.questions)
        #expect(questions.count == 2)
        let second = try #require(questions.last?.request)
        #expect(second.trigger == .scheduled && second.envelope.kind == .update)
        // 遅れた行の位置から読み直し、その後ろの送信済みの発言も置き換えの範囲に入れる。
        #expect(second.envelope.readStartLine == 1 && second.envelope.readLineCount == 2)
        let lines = try sentLines(second)
        #expect(lines.count == 2 && lines[0].contains("画面:") && lines[1].contains("この図の数字を確認します"))
        #expect(second.envelope.imageDirectories == MeetingFiles.imageDirectories(for: root.appendingPathComponent("meeting.md")))
        try reply(session, root: root)
        session.evaluateAISchedule(now: now.addingTimeInterval(600)); await session.submissionTaskForTesting?.value
        #expect(session.aiRecord?.controller.conversation.questions.count == 2)
        await wait { recorder.pendingForTesting == 0 }
    }

    @Test func 停止の待ちの間に公開された画面を最後の1回に含める() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), session = try session(root, fake: fake), now = Date()
        defer { session.stopAISchedule() }
        let recorder = session.installScreenRecorderForTesting(display: display, markdownURL: root.appendingPathComponent("meeting.md"))
        try session.startAISchedule(options: .init(prompt: "議事録を更新"), helper: URL(fileURLWithPath: "/bin/echo"), now: now)
        await session.submissionTaskForTesting?.value
        try reply(session, root: root)
        #expect(session.screenEntriesForTesting.isEmpty)
        // 受け付けた直後に停止する。MainActorを明け渡すまで公開は走らないので、公開は停止の待ちの間になる。
        recorder.observeForTesting(try image(), label: "EV3895 · Keynote「提案資料」")
        await session.stop()
        #expect(session.screenEntriesForTesting.count == 1)
        session.evaluateAISchedule(); await session.submissionTaskForTesting?.value
        let questions = try #require(session.aiRecord?.controller.conversation.questions)
        #expect(questions.count == 2)
        let last = try #require(questions.last?.request)
        #expect(last.trigger == .scheduled)
        #expect(try sentLines(last).contains { $0.contains("画面:") && $0.contains(".captures/") })
    }
}
}
