import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

// 実シートの焦点と閉じる操作を確かめるため、同時に複数のシートを開かない。
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct StartSheetTests {
    @Test func システム音声の自動判定が追従し開始時に固定する() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var kind: AudioOutputKind = .headphones
        let sheet = StartSheet(profiles: [], diarizationEnabled: true, exclusion: AudioExclusion(), outputKind: { kind })
        #expect(sheet.systemAudioAutomatic.title == "自動(いまは取り込む)")
        #expect(sheet.options?.recordSystemAudio == true)
        try capture("system-auto-include", sheet)
        kind = .builtInSpeaker
        sheet.refreshSystemAudioOutput()
        #expect(sheet.systemAudioAutomatic.title == "自動(いまは取り込まない)")
        #expect(sheet.options?.recordSystemAudio == false)
        try capture("system-auto-exclude", sheet)
        sheet.selectSystemAudio(.include)
        #expect(sheet.options?.recordSystemAudio == true)
        kind = .unknown
        #expect(sheet.options?.recordSystemAudio == true)
        sheet.selectSystemAudio(.exclude)
        #expect(sheet.options?.recordSystemAudio == false)
        var cancelled = false
        sheet.onCancel = { cancelled = true }
        sheet.cancelPressed()
        #expect(cancelled)
    }
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
        #expect(started == StartSheet.Options(diarizationEnabled: false, exclusionEnabled: false))
        // 説明文は置かない。読めない議事録の理由だけを出す。
        #expect(sheet.minutesHintText.isEmpty)
        try capture("b-minimal", sheet)
    }

    @Test func 小音量除外はスイッチでON_OFFだけを決める() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let sheet = StartSheet(profiles: [], diarizationEnabled: true,
                               exclusion: AudioExclusion(enabled: true, thresholdDBFS: -50))
        #expect(sheet.exclusionSwitch.state == .on)
        #expect(sheet.options?.exclusionEnabled == true)
        sheet.exclusionSwitch.state = .off
        #expect(sheet.options?.exclusionEnabled == false)
    }

    @Test func 既定の宛先はautoStartのプロファイルで閉じた行に型式を出す() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true,
                               exclusion: AudioExclusion(enabled: true, thresholdDBFS: -45),
                               minutesPath: "/work/minutes/2026-09-16 定例.md")
        #expect(sheet.selectedSlot == 2)
        #expect(sheet.destinationTitle == "議事録 · Codex · gpt-5.4 (high)")
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

    @Test func プロンプトは畳まずそのまま書き換えられ宛先メニューにも先頭が並ぶ() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true, exclusion: AudioExclusion())
        #expect(sheet.editor.string == "会議の決定事項と担当・期限をMarkdown議事録へ更新してください")
        #expect(sheet.editor.enclosingScrollView?.frame.height ?? 0 >= StartSheet.promptHeight)
        sheet.editor.string = "決定事項だけ書いてください"
        sheet.textDidChange(Notification(name: NSText.didChangeNotification))
        try capture("d-ai-edited", sheet)
        #expect(sheet.options?.schedule?.prompt == "決定事項だけ書いてください")
        // メニューの各行は名前・型式・プロンプトの3行。「送らない」だけ1行。
        let items = try #require(sheet.destination.menu?.items)
        #expect(items[0].title == "送らない" && items[0].attributedTitle == nil)
        let lines = items[2].attributedTitle?.string.split(separator: "\n").map(String.init) ?? []
        #expect(lines == ["議事録", "Codex · gpt-5.4 (high)","会議の決定事項と担当・期限をMarkdown議事録へ更新してください"])
        #expect(StartSheet.promptLine("一行目\n二行目") == "一行目 二行目")
        #expect(StartSheet.promptLine("   ") == nil)
        #expect(StartSheet.promptLine(String(repeating: "あ", count: 60)) == String(repeating: "あ", count: 48) + "…")
    }

    @Test func 議事録は履歴とドロップで指定し不正なパスでは開始しない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let sheet = StartSheet(profiles: [], diarizationEnabled: true, exclusion: AudioExclusion(),
                               minutesHistory: ["/work/a.md", "/work/b.md"])
        #expect(sheet.historyPaths == ["/work/a.md", "/work/b.md"])
        // 履歴のメニューはファイル名とディレクトリの2行。長いパスでもファイル名から欠けない。
        let items = sheet.historyMenu().items
        #expect(items.map(\.toolTip) == ["/work/a.md", "/work/b.md"])
        #expect(items[0].attributedTitle?.string == "a.md\n/work")
        #expect(sheet.historyButton.isEnabled)
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

    @Test func 実ウィンドウへシートとして出し幅を固定する() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "StartSheetTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults)
        controller.window?.setFrameAutosaveName("")
        let parent = try #require(controller.window)
        let next = try NextMeeting(minutesPath: root.appendingPathComponent("定例.md").path, ai: "議事録")
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true, exclusion: AudioExclusion(),
                               nextMeetings: [next])
        sheet.present(on: parent)
        #expect(parent.attachedSheet === sheet.window)
        #expect(sheet.window.firstResponder === sheet.startButton)
        #expect(sheet.window.frame.width == StartSheet.width)
        // 「送らない」で詳細を畳むと高さだけが変わる。幅は動かさない。
        let expanded = sheet.window.frame.height
        sheet.destination.selectItem(withTag: 0)
        sheet.destinationChanged()
        #expect(sheet.window.frame.width == StartSheet.width && sheet.window.frame.height < expanded)
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

    @Test func 次の会議を先頭から選び議事録と宛先を切り替える() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let firstPath = root.appendingPathComponent("定例.md"), secondPath = root.appendingPathComponent("相談.md")
        try Data("---\nparticipants: [Tadashi]\n---\n# 定例の議事録\n\n本文".utf8).write(to: firstPath)
        try Data("# 相談の見出し\n".utf8).write(to: secondPath)
        let first = try NextMeeting(minutesPath: firstPath.path, at: "2026-10-10T13:00", ai: "議事録")
        let second = try NextMeeting(minutesPath: secondPath.path, title: "プロダクト相談", at: "2026-10-10T14:00", ai: "相談")
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true, exclusion: AudioExclusion(),
                               nextMeetings: [second, first])
        #expect(sheet.nextMeetings == [first, second])
        #expect(sheet.nextButtons.count == 3 && sheet.nextButtons[0].state == .on)
        #expect(sheet.nextButtons.last?.title == "指定しない")
        #expect(sheet.nextTitles.map(\.stringValue) == ["13:00 定例の議事録", "14:00 プロダクト相談"])
        #expect(sheet.nextDetails[0].stringValue == "議事録 · 定例.md")
        #expect(sheet.minutesBox.stringValue == firstPath.path)
        #expect(sheet.options?.minutesPath == firstPath.path && sheet.options?.scheduleSlot == 2)
        #expect(sheet.interval.selectedTag() == 5 && sheet.work.state == .off)
        #expect(sheet.diarizeOn.state == .on && sheet.systemAudioAutomatic.state == .on)
        try capture("next-two", sheet)
        #expect(sheet.window.frame.width == 640)
        sheet.nextMeetingChanged(sheet.nextButtons[1])
        #expect(sheet.minutesBox.stringValue == secondPath.path && sheet.selectedSlot == 1)
        #expect(sheet.nextButtons[0].state == .off && sheet.nextButtons[1].state == .on)
        #expect(sheet.options?.schedule?.prompt == "気になった点を3つまで挙げてください")
        // 手で直した値は予約へ書き戻さず、開始時の指定としてそのまま使う。
        sheet.minutesBox.stringValue = "/手で変えた.md"
        sheet.destination.selectItem(withTag: 0); sheet.destinationChanged()
        #expect(sheet.options?.minutesPath == "/手で変えた.md" && sheet.options?.scheduleSlot == nil)
        sheet.nextMeetingChanged(sheet.nextButtons[2])
        #expect(sheet.minutesBox.stringValue.isEmpty && sheet.selectedSlot == 2)
        #expect(sheet.options?.minutesPath == nil && sheet.options?.scheduleSlot == 2)
        sheet.close()
    }

    @Test func 設定にない宛先と未作成ファイルを金色で示して送らない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("未作成.md")
        let meeting = try NextMeeting(minutesPath: missing.path, ai: "廃止した宛先")
        let sheet = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true,
                               exclusion: AudioExclusion(), nextMeetings: [meeting])
        #expect(sheet.nextTitles[0].stringValue == "未作成.md")
        #expect(sheet.nextDetails[0].stringValue == "廃止した宛先 · 未作成.md · 設定にありません · 見つかりません")
        #expect(sheet.nextDetails[0].textColor == Washi.gold)
        #expect(sheet.selectedSlot == nil && sheet.options?.schedule == nil)
        #expect(sheet.options?.minutesPath == missing.path)
        sheet.selectNextMeeting(at: 1)
        #expect(sheet.selectedSlot == 2 && sheet.minutesBox.stringValue.isEmpty)
    }

    @Test func 宛先省略は送らず指定しないで既定へ戻る() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("見出しなし.md")
        try Data("本文だけ\n".utf8).write(to: path)
        let meeting = try NextMeeting(minutesPath: path.path)
        let sheet = StartSheet(profiles: try profiles(root, toml: "[[ai]]\nname = \"相談\""),
                               diarizationEnabled: true, exclusion: AudioExclusion(), nextMeetings: [meeting])
        #expect(sheet.nextTitles[0].stringValue == "見出しなし.md")
        #expect(sheet.nextDetails[0].stringValue == "送らない · 見出しなし.md")
        #expect(sheet.nextDetails[0].textColor == Washi.muted)
        #expect(sheet.selectedSlot == nil)
        sheet.selectNextMeeting(at: 1)
        #expect(sheet.selectedSlot == nil && sheet.minutesBox.stringValue.isEmpty)
    }

    @Test func 次の会議は三件まで表示しゼロ件なら行を置かない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meetings = try (1...4).map { try NextMeeting(minutesPath: root.appendingPathComponent("\($0).md").path,
                                                        createdAt: Date(timeIntervalSince1970: Double($0))) }
        let sheet = StartSheet(profiles: [], diarizationEnabled: true, exclusion: AudioExclusion(), nextMeetings: meetings)
        #expect(sheet.nextMeetings.count == 3 && sheet.nextButtons.count == 4)
        var cancelled = false
        sheet.onCancel = { cancelled = true }; sheet.cancelPressed()
        #expect(cancelled && sheet.nextMeetings.count == 3)
        let empty = StartSheet(profiles: try twoProfiles(root), diarizationEnabled: true, exclusion: AudioExclusion())
        #expect(empty.nextButtons.isEmpty && empty.nextTitles.isEmpty)
        func labels(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
        }
        #expect(!labels(try #require(empty.window.contentView)).contains("次の会議"))
        try capture("next-none", empty)
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
