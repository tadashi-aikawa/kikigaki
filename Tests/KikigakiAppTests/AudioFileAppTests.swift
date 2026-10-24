import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

/// 音声ファイルの書き起こし。仕様は docs/audio-file.md
extension AppKitTests {
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct AudioFileAppTests {
    // 2026-10-20 10:00 JST
    private let recordedAt = Date(timeIntervalSince1970: 1_792_458_000)
    private var file: AudioFile { AudioFile(url: URL(fileURLWithPath: "/tmp/定例.m4a"), duration: 1935, recordedAt: recordedAt) }

    private func profiles(_ root: URL) throws -> [ResolvedAIConfig] {
        ResolvedConfig(config: try ConfigLoader.parse(toml: """
        [[ai]]
        name = "相談"
        cli = "claude"
        initialPrompt = "気になった点を挙げてください"

        [[ai]]
        name = "議事録"
        cli = "codex"
        model = "gpt-6.1-sol"
        effort = "high"
        autoStart = true
        initialPrompt = "会議の決定事項と担当・期限をMarkdown議事録へ更新してください"
        allowWork = false
        """), home: root).aiProfiles
    }

    @Test func 開始シートは使わない行とAIの行を出さず手動宛先は前回の宛先から始める() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        defaults.set("議事録", forKey: StartSheet.manualDefaultsKey)
        let next = try NextMeeting(minutesPath: "/work/minutes/定例.md", ai: "議事録")
        let sheet = StartSheet(profiles: try profiles(root), audioFile: file, diarizationEnabled: true,
                               exclusion: AudioExclusion(enabled: true, thresholdDBFS: -45),
                               minutesPath: "/work/minutes/2026-10-20 定例.md", nextMeetings: [next], defaults: defaults)
        #expect(sheet.audioFileName.stringValue == "定例.m4a")
        #expect(sheet.audioFileSummary.stringValue == file.summary())
        // システム音声・マイク・自動送信・手動送信・次の会議は出さない。AIへは仕上げで頼む。
        for view in [sheet.systemAudioAutomatic, sheet.microphoneLabel, sheet.destination, sheet.manualDestination] {
            #expect(view.superview == nil)
        }
        #expect(sheet.nextMeetings.isEmpty)
        let options = try #require(sheet.options)
        #expect(options.audioFile == file)
        #expect(options.scheduleSlot == nil && options.schedule == nil && options.nextMeetingID == nil)
        #expect(options.manualSlot == 2)
        try capture("file-sheet", sheet)
        // 録音のシートは今までどおり。
        let recording = StartSheet(profiles: try profiles(root), diarizationEnabled: true, exclusion: AudioExclusion())
        #expect(recording.audioFileName.superview == nil && recording.systemAudioAutomatic.superview != nil)
        #expect(recording.options?.audioFile == nil)
    }

    @Test func 選び直したファイルを開始の指定に使う() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let sheet = StartSheet(profiles: [], audioFile: file, diarizationEnabled: false, exclusion: AudioExclusion())
        let other = AudioFile(url: URL(fileURLWithPath: "/tmp/別の会議.wav"), duration: 60, recordedAt: recordedAt)
        sheet.setAudioFile(other)
        #expect(sheet.audioFileName.stringValue == "別の会議.wav")
        #expect(sheet.options?.audioFile == other)
        // 録音のシートでは替えない。
        let recording = StartSheet(profiles: [], diarizationEnabled: false, exclusion: AudioExclusion())
        recording.setAudioFile(other)
        #expect(recording.options?.audioFile == nil)
    }

    @Test func 選び直したファイルを確かめる間は開始せず最後に選んだものを使う() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let sheet = StartSheet(profiles: [], audioFile: file, diarizationEnabled: false, exclusion: AudioExclusion())
        var started: StartSheet.Options?
        sheet.onStart = { started = $0 }
        let first = AudioFile(url: URL(fileURLWithPath: "/tmp/1回目.wav"), duration: 60, recordedAt: recordedAt)
        let second = AudioFile(url: URL(fileURLWithPath: "/tmp/2回目.wav"), duration: 90, recordedAt: recordedAt)
        var pending: [String: CheckedContinuation<AudioFile, Error>] = [:]
        let load: (URL) async throws -> AudioFile = { url in
            try await withCheckedThrowingContinuation { pending[url.lastPathComponent] = $0 }
        }
        sheet.probeAudioFile(first.url, load: load)
        sheet.probeAudioFile(second.url, load: load)
        while pending.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!sheet.startButton.isEnabled)
        sheet.startPressed()
        #expect(started == nil)
        pending["2回目.wav"]?.resume(returning: second)
        while sheet.audioFileProbe != nil { try await Task.sleep(for: .milliseconds(5)) }
        // 先に選んだほうが後から届いても、最後に選んだものを上書きしない。
        pending["1回目.wav"]?.resume(returning: first)
        try await Task.sleep(for: .milliseconds(20))
        #expect(sheet.startButton.isEnabled)
        sheet.startPressed()
        #expect(started?.audioFile == second)
    }

    @Test func 書き起こし中は時間に依存する操作を止める() {
        var value = SessionSnapshot()
        value.audioFile = file
        value.markdownURL = URL(fileURLWithPath: "/tmp/2026-10-20_1000.md")
        value.state = .recording
        #expect(value.transcribingFile)
        #expect(!value.canSubmitTyped && !value.canSubmitAI && !value.canPauseOrResume)
        // 保存後の仕上げでは、改名・コピーに加えてAIへ頼める。手入力はしない。
        value.state = .idle; value.reviewingFile = true
        #expect(!value.transcribingFile && value.canShare && value.canSubmitAI && !value.canSubmitTyped)
        // 完了した後は録音の停止後と同じく、AIへ新しく頼めない。
        value.reviewingFile = false
        #expect(value.canShare && !value.canSubmitAI)
        var recording = SessionSnapshot()
        recording.markdownURL = value.markdownURL; recording.state = .recording
        #expect(recording.canSubmitTyped && recording.canSubmitAI && recording.canPauseOrResume)
    }

    @Test func replayは指定したときだけ書き起こしの経路を通す() throws {
        #expect(try ReplayDebugOptions.load(arguments: ["--replay"], environment: [:]).fileTranscription == false)
        #expect(try ReplayDebugOptions.load(arguments: ["--replay"], environment: ["KIKIGAKI_DEBUG_REPLAY_FILE": "1"]).fileTranscription)
        #expect(try ReplayDebugOptions.load(arguments: [], environment: ["KIKIGAKI_DEBUG_REPLAY_FILE": "1"]).fileTranscription == false)
        #expect(throws: AIError.self) {
            try ReplayDebugOptions.load(arguments: ["--replay"], environment: ["KIKIGAKI_DEBUG_REPLAY_FILE": "yes"])
        }
    }

    @Test func 供給は消費に追いつかれるまで先へ進まない() async throws {
        let gate = FileFeedGate(limit: 100)
        var released = false
        let waiting = Task { await gate.waitUntilCaughtUp(fed: 300); released = true }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!released)
        gate.consume(150)
        try await Task.sleep(for: .milliseconds(30))
        #expect(!released)
        gate.consume(100)
        await waiting.value
        #expect(released)
    }

    @Test func 窓へのドロップは録音していないときの音声だけを受ける() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("定例.wav"), text = root.appendingPathComponent("メモ.md")
        try Data().write(to: audio); try Data().write(to: text)
        let window = TranscriptWindowController(minutesDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let drop = try #require(window.audioFileDrop)
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        pasteboard.clearContents(); pasteboard.writeObjects([audio as NSURL])
        #expect(drop.audioURL(pasteboard) == audio)
        pasteboard.clearContents(); pasteboard.writeObjects([text as NSURL])
        #expect(drop.audioURL(pasteboard) == nil)
        #expect(drop.accepts())
        var recording = SessionSnapshot(); recording.state = .recording
        window.apply(recording)
        #expect(!drop.accepts())
    }

    @Test(arguments: [420.0, 600.0])
    func 書き起こし中のヘッダーは位置と全体の長さを出し中止だけを置く(width: Double) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = TranscriptWindowController(shouldReduceMotion: { true },
                                                    minutesDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        defer { window.orderOut(nil) }
        let content = try #require(window.contentView)
        window.setContentSize(NSSize(width: width, height: 650))
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        var value = SessionSnapshot(state: .recording, elapsed: 750, markdownURL: URL(fileURLWithPath: "/tmp/2026-10-20_1000.md"))
        value.audioFile = file
        value.timeline = MeetingTimeline(startedAt: recordedAt)
        controller.apply(value)
        content.layoutSubtreeIfNeeded()
        let views = descendants(content).filter { !$0.isHiddenOrHasHiddenAncestor }
        let chip = try #require(views.compactMap { $0 as? RecordingStatusChip }.first)
        #expect(chip.accessibilityLabel() == "書き起こし中 12:30 / 32:15")
        let buttons = views.compactMap { $0 as? WashiActionButton }
        #expect(buttons.map(\.toolTip) == ["中止"])
        // 札の余白を押し縮めない。
        #expect(chip.frame.width >= chip.fittingSize.width - 0.5)
        let range = try #require(views.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasSuffix("〜") })
        #expect(!range.stringValue.hasPrefix(AudioFile.datePrefix(recordedAt)))
        try capture(content, "file-transcribing-\(Int(width))")
        // 保存後は当日とは限らない会議の日付を添える。
        // 保存後の仕上げは「仕上げ中」と「完了」。完了するまで「新しい録音」は出さない。
        value.state = .idle; value.saved = true; value.reviewingFile = true
        controller.apply(value)
        content.layoutSubtreeIfNeeded()
        #expect(range.stringValue.hasPrefix(AudioFile.datePrefix(recordedAt)))
        #expect(chip.accessibilityLabel() == "仕上げ中")
        let reviewing = descendants(content).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { $0 as? WashiActionButton }
        #expect(reviewing.map(\.toolTip) == ["完了"])
        try capture(content, "file-reviewing-\(Int(width))")
        value.reviewingFile = false
        controller.apply(value)
        content.layoutSubtreeIfNeeded()
        #expect(chip.accessibilityLabel() == "保存済み")
        let saved = descendants(content).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { $0 as? WashiActionButton }
        #expect(saved.map(\.toolTip) == ["新しい録音"])
        try capture(content, "file-saved-\(Int(width))")
    }
    private func capture(_ content: NSView, _ name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] else { return }
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    /// オンデバイスSpeechを使う結合検証。通常のテストではモデル・言語アセットを要求しない。
    @Test func 書き起こしは録音日時で保存しWAVを書かず中止では何も残さない() async throws {
        guard ProcessInfo.processInfo.environment["KIKIGAKI_TEST_SPEECH"] == "1" else { return }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var settings = try ConfigLoader.parse(toml: "outputDir = \"\(root.path)\"")
        settings.saveRecording = true
        let session = MeetingSession(config: ResolvedConfig(config: settings), models: { throw CancellationError() }, log: { _ in })
        session.setDiarizationEnabled(false)
        let source = FileSource(samples: Array(repeating: 0, count: 16000 * 2), paced: false)
        source.onEnd = { Task { @MainActor in await session.finishFileInput(from: source) } }
        let audio = AudioFile(url: root.appendingPathComponent("定例.m4a"), duration: 2, recordedAt: recordedAt)
        #expect(await session.start(source: source, audioFile: audio))
        #expect(session.snapshot.transcribingFile)
        let deadline = Date().addingTimeInterval(30)
        while session.snapshot.state != .idle, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(session.snapshot.saved)
        let name = MeetingFiles.baseName(startedAt: recordedAt, timeZone: .current) + ".md"
        #expect(session.snapshot.markdownURL?.lastPathComponent == name)
        let markdown = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        #expect(markdown.contains("- 音声: 定例.m4a"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".wav") }.isEmpty)
        // 保存してから仕上げに入る。完了したら録音の停止後と同じになる。
        #expect(session.snapshot.reviewingFile && session.snapshot.canSubmitAI)
        session.completeFileReview()
        #expect(!session.snapshot.reviewingFile && !session.snapshot.canSubmitAI)

        let long = FileSource(samples: Array(repeating: 0, count: 16000 * 600), paced: false)
        #expect(await session.start(source: long, audioFile: AudioFile(url: root.appendingPathComponent("長い.wav"), duration: 600,
                                                                      recordedAt: recordedAt.addingTimeInterval(3600))))
        let reserved = try #require(session.snapshot.markdownURL)
        #expect(FileManager.default.fileExists(atPath: reserved.path))
        await session.cancelFileTranscription()
        #expect(session.snapshot.state == .idle && !session.snapshot.saved && !session.snapshot.reviewingFile)
        #expect(session.snapshot.message == "書き起こしを中止しました")
        #expect(!FileManager.default.fileExists(atPath: reserved.path))

        // 中止した会議の音源から遅れて届いた完了通知で、次の会議を止めない。
        let next = FileSource(samples: Array(repeating: 0, count: 16000 * 600), paced: false)
        #expect(await session.start(source: next, audioFile: AudioFile(url: root.appendingPathComponent("次.wav"), duration: 600,
                                                                      recordedAt: recordedAt.addingTimeInterval(7200))))
        await session.finishFileInput(from: long)
        #expect(session.snapshot.state == .recording && session.snapshot.transcribingFile)
        await session.cancelFileTranscription()
        #expect(session.snapshot.state == .idle)
    }

    private func capture(_ name: String, _ sheet: StartSheet) throws {
        guard let directory = ProcessInfo.processInfo.environment["KIKIGAKI_START_SHEET_CAPTURE"],
              let scroll = sheet.window.contentView as? NSScrollView,
              let view = scroll.documentView else { return }
        view.layoutSubtreeIfNeeded()
        let bounds = scroll.documentVisibleRect
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }
}
}
