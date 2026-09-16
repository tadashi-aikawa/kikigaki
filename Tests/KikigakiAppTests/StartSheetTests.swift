import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite(.timeLimit(.minutes(1))) @MainActor struct StartSheetTests {
    private func profiles(_ root: URL, toml: String) throws -> [ResolvedAIConfig] {
        ResolvedConfig(config: try ConfigLoader.parse(toml: toml), home: root).aiProfiles
    }
    private func twoProfiles(_ root: URL) throws -> [ResolvedAIConfig] {
        try profiles(root, toml: """
        [[ai]]
        name = "相談"
        cli = "claude"
        model = "claude-opus-5"
        effort = "max"
        cwd = "~/work/kikigaki"
        autoPrompt = "気になった点を3つまで挙げてください"

        [[ai]]
        name = "議事録"
        cli = "codex"
        model = "gpt-5.4"
        effort = "high"
        cwd = "~/work/minutes"
        autoStart = true
        autoPrompt = "会議の決定事項と担当・期限をMarkdown議事録へ更新してください"
        autoIntervalMinutes = 5
        allowWork = false
        """)
    }

    @Test func AI未設定なら自動送信の区画ごと出さず開始できる() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let sheet = StartSheet(profiles: [], diarizationEnabled: false, exclusion: AudioExclusion())
        var started: StartSheet.Options?
        sheet.onStart = { started = $0 }
        #expect(sheet.destination.superview == nil)
        sheet.startPressed()
        #expect(started == StartSheet.Options(diarizationEnabled: false))
        try capture("b-minimal", sheet)
    }

    @Test func 既定の宛先はautoStartのプロファイルで閉じた行に型式を出す() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true,
                               exclusion: AudioExclusion(enabled: true, thresholdDBFS: -45),
                               minutesPath: "/work/minutes/2026-09-16 定例.md")
        #expect(sheet.selectedSlot == 2)
        #expect(sheet.destinationTitle == "議事録 · Codex · gpt-5.4 · high")
        #expect(!sheet.aiDetails.isHidden)
        #expect(sheet.interval.selectedTag() == 5)
        // 作業許可の初期値は宛先の設定から採る。
        #expect(sheet.work.state == .off && sheet.final.state == .on)
        let options = try #require(sheet.options)
        #expect(options.scheduleSlot == 2)
        #expect(options.schedule?.prompt == "会議の決定事項と担当・期限をMarkdown議事録へ更新してください")
        #expect(options.schedule?.interval == 300 && options.schedule?.workAllowed == false)
        #expect(options.minutesPath == "/work/minutes/2026-09-16 定例.md")
        try capture("a-full", sheet)
    }

    @Test func autoStartが無ければ送らないが既定で詳細を畳む() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sheet = StartSheet(profiles: try profiles(root, toml: "[[ai]]\nname = \"相談\""),
                               diarizationEnabled: true, exclusion: AudioExclusion())
        #expect(sheet.selectedSlot == nil)
        #expect(sheet.aiDetails.isHidden)
        #expect(sheet.destinationTitle == "送らない")
        #expect(sheet.options?.scheduleSlot == nil && sheet.options?.schedule == nil)
    }

    @Test func 宛先を選び直すと下書きを覚え送らないで畳む() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true, exclusion: AudioExclusion())
        sheet.editor.string = "議事録の下書き"
        sheet.destination.selectItem(withTag: 1)
        sheet.destinationChanged()
        #expect(sheet.selectedSlot == 1)
        #expect(sheet.editor.string == "気になった点を3つまで挙げてください")
        #expect(sheet.interval.selectedTag() == 3 && sheet.work.state == .on)
        sheet.destination.selectItem(withTag: 2)
        sheet.destinationChanged()
        #expect(sheet.editor.string == "議事録の下書き")
        sheet.destination.selectItem(withTag: 0)
        sheet.destinationChanged()
        #expect(sheet.selectedSlot == nil && sheet.aiDetails.isHidden)
        #expect(sheet.options?.schedule == nil)
    }

    @Test func プロンプトの編集はその場で開いて閉じる() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true, exclusion: AudioExclusion())
        #expect(sheet.editorBox.isHidden)
        #expect(sheet.promptLine.stringValue == "会議の決定事項と担当・期限をMarkdown議事録へ更新してください")
        sheet.toggleEditor()
        #expect(!sheet.editorBox.isHidden)
        sheet.editor.string = "決定事項だけ書いてください"
        sheet.textDidChange(Notification(name: NSText.didChangeNotification))
        try capture("d-ai-expanded", sheet)
        sheet.toggleEditor()
        #expect(sheet.editorBox.isHidden)
        #expect(sheet.promptLine.stringValue == "決定事項だけ書いてください")
        #expect(sheet.options?.schedule?.prompt == "決定事項だけ書いてください")
    }

    @Test func 議事録は履歴とドロップで指定し不正なパスでは開始しない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let sheet = StartSheet(profiles: [], diarizationEnabled: true, exclusion: AudioExclusion(),
                               minutesHistory: ["/work/a.md", "/work/b.md"])
        #expect(sheet.minutesBox.objectValues as? [String] == ["/work/a.md", "/work/b.md"])
        var started: StartSheet.Options?
        sheet.onStart = { started = $0 }
        sheet.minutesBox.stringValue = "relative.txt"
        sheet.startPressed()
        #expect(started == nil)
        // ドロップは .md のファイルだけ受ける。
        let pasteboard = NSPasteboard(name: .init("StartSheetTests.\(UUID())"))
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/work/dropped.md") as NSURL])
        #expect(sheet.minutesBox.droppedPath(pasteboard) == "/work/dropped.md")
        sheet.setMinutesPath("/work/dropped.md")
        sheet.startPressed()
        #expect(started?.minutesPath == "/work/dropped.md")
    }

    @Test func 実ウィンドウへシートとして出し504ptに収める() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "StartSheetTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults)
        controller.window?.setFrameAutosaveName("")
        let parent = try #require(controller.window)
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true, exclusion: AudioExclusion())
        sheet.present(on: parent)
        #expect(parent.attachedSheet === sheet.window)
        #expect(sheet.window.frame.width == 504)
        // 畳み・展開で高さだけが変わる。幅は動かさない。
        let collapsed = sheet.window.frame.height
        sheet.toggleEditor()
        #expect(sheet.window.frame.width == 504 && sheet.window.frame.height > collapsed)
        sheet.close()
        #expect(parent.attachedSheet == nil)
    }

    @Test func 取消は何も始めない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true, exclusion: AudioExclusion())
        var started = false, cancelled = false
        sheet.onStart = { _ in started = true }
        sheet.onCancel = { cancelled = true }
        sheet.cancelPressed()
        #expect(!started && cancelled)
    }

    /// 検証用の撮影。モックとの突き合わせに使い、通常のテストでは何もしない。
    private func capture(_ name: String, _ sheet: StartSheet) throws {
        guard let directory = ProcessInfo.processInfo.environment["KIKIGAKI_START_SHEET_CAPTURE"],
              let view = sheet.window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor struct StartSheetScheduleTests {
    /// 開始シートの値で自動送信を始める。設定の `autoStart` は使わない。
    @Test func シートの宛先と依頼で自動送信を始める() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        var config = ResolvedConfig(config: KikigakiConfig(), home: root)
        config.aiProfiles = ResolvedConfig(config: try ConfigLoader.parse(toml: """
        [[ai]]
        name = "相談"
        command = "/bin/echo"
        cwd = "\(root.path)"

        [[ai]]
        name = "議事録"
        command = "/bin/echo"
        cwd = "\(root.path)"
        autoStart = true
        autoPrompt = "設定の依頼"
        """), home: root).aiProfiles
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"),
                                     config: config, aiStore: store, recordedSamples: 16_000)
        session.automaticHelper = URL(fileURLWithPath: "/bin/echo")
        session.setScheduleTranscriptForTesting("開始時の発話")
        session.pendingAutomaticSchedule = .init(slot: 1, options: try AIScheduleOptions(prompt: "シートの依頼", interval: 120))
        session.startAutomaticSchedule()
        #expect(session.snapshot.aiSchedule.active)
        #expect(session.aiScheduleConfiguration?.name == "相談")
        #expect(session.lastScheduleOptions?.prompt == "シートの依頼")
        #expect(session.lastScheduleOptions?.interval == 120)
        await session.submissionTaskForTesting?.value
        session.stopAISchedule()
    }

    /// 「送らない」を選んだ会議では、設定に `autoStart` があっても始めない。
    @Test func シートで送らないを選ぶと設定のautoStartでも始めない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        var config = ResolvedConfig(config: KikigakiConfig(), home: root)
        config.aiProfiles = ResolvedConfig(config: try ConfigLoader.parse(toml: """
        [[ai]]
        name = "議事録"
        command = "/bin/echo"
        cwd = "\(root.path)"
        autoStart = true
        autoPrompt = "設定の依頼"
        """), home: root).aiProfiles
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"),
                                     config: config, aiStore: store, recordedSamples: 16_000)
        session.automaticHelper = URL(fileURLWithPath: "/bin/echo")
        session.pendingAutomaticSchedule = .init(slot: nil, options: nil)
        session.startAutomaticSchedule()
        #expect(!session.snapshot.aiSchedule.active)
        // 指定は1回だけ効き、次の会議へは持ち越さない。
        session.startAutomaticSchedule()
        #expect(session.snapshot.aiSchedule.active)
        session.stopAISchedule()
    }

    /// 開始シートの議事録は表示中の会議へ当てず、次の録音の準備で引き継ぐ。
    @Test func 開始シートの議事録は次の会議へ持ち越す() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let records = AIRecordStore(directory: root)
        let session = MeetingSession(config: ResolvedConfig(config: KikigakiConfig(), home: root),
                                     models: { throw CancellationError() }, log: { _ in }, aiStore: records)
        session.setMinutesPreparationForTesting()
        try session.completeMinutesPreparationForTesting(at: root.appendingPathComponent("first.md"))
        try session.prepareMinutes("/tmp/次の会議.md")
        // 表示中の会議には当たらない。次の準備で待機指定へ移る。
        #expect(try session.previewMinutesStore()?.state.humanMinutesPath == nil)
        #expect(session.waitingMinutesPath == nil)
        session.setMinutesPreparationForTesting()
        #expect(session.waitingMinutesPath == "/tmp/次の会議.md")
        try session.completeMinutesPreparationForTesting(at: root.appendingPathComponent("second.md"))
        #expect(try session.previewMinutesStore()?.state.humanMinutesPath == "/tmp/次の会議.md")
        #expect(throws: (any Error).self) { try session.prepareMinutes("relative.md") }
    }
}
