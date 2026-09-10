import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

// 実際にシートを開くケースは順番に実行し、複数のモーダル表示を競合させない。
@Suite(.serialized) @MainActor struct AIScheduleDestinationTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private actor BindingGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var entered = false
        func pauseOnce() async {
            guard !entered else { return }
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    @Test(arguments: ["自動→自動", "自動→手動", "手動→手動", "手動→自動"], [false, true])
    func 紐づけ中に閉じて開き直しても開始を待ち正しい宛先の文面を表示する(mode: String, fail: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = try ResolvedConfig(config: ConfigLoader.parse(toml: """
        [[ai]]
        name = "議事録"
        command = "/bin/echo"
        cwd = "\(root.path)"
        autoPrompt = "議事録の依頼"
        autoIntervalMinutes = 7
        [[ai]]
        name = "相談"
        command = "/bin/echo"
        cwd = "\(root.path)"
        autoPrompt = "相談の依頼"
        autoIntervalMinutes = 11
        """), home: root)
        let fake = FakeHerdr(), gate = BindingGate()
        let prepared = AIPreparedStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        prepared.load()
        await prepared.prepare(profile: config.aiProfiles[1], helper: URL(fileURLWithPath: "/bin/echo"), outputDirectory: root)
        let entry = try #require(prepared.unbound.first)
        let store = AIRecordStore(directory: root, makeHerdr: {
            AIHerdr(run: { args, timeout in
                if args.prefix(2) == ["agent", "get"] {
                    await gate.pauseOnce()
                    if fail { throw AIHerdrError.missing }
                }
                return try await fake.run(args, timeout)
            })
        })
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config, aiStore: store)
        session.preparedStore = prepared
        let window = TranscriptWindowController(shouldReduceMotion: { true })
        window.window?.setFrameAutosaveName("")
        defer { window.window?.orderOut(nil) }
        let app = AppDelegate(testingSession: session, config: config, preparedStore: prepared, window: window)
        let fromAuto = mode.hasPrefix("自動"), toAuto = mode.hasSuffix("自動")
        session.updateManualDraft("手動の依頼", slot: config.aiProfiles[0].slot)
        if fromAuto { app.showScheduleSheet() } else { app.showAISheet(parent: nil) }
        let originalWindow = try #require(app.scheduleSheet?.window ?? app.aiSheet?.window)
        let editor = try #require(descendants(originalWindow.contentView!).compactMap { $0 as? AIQuestionEditor }.first)
        editor.string = "編集中の議事録"
        if fromAuto {
            app.scheduleSheet?.textDidChange(Notification(name: NSText.didChangeNotification))
            app.scheduleSheet?.onPrepared?(config.aiProfiles[1].slot, entry.id)
        } else {
            app.aiSheet?.textDidChange(Notification(name: NSText.didChangeNotification))
            app.aiSheet?.onPrepared?(config.aiProfiles[1].slot, entry.id)
        }
        for _ in 0..<200 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.entered)
        let close = try #require(descendants(originalWindow.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "閉じる" })
        close.performClick(nil)
        #expect(app.scheduleSheet == nil && app.aiSheet == nil)
        if toAuto { app.showScheduleSheet() } else { app.showAISheet(parent: nil) }
        let reopenedWindow = try #require(app.scheduleSheet?.window ?? app.aiSheet?.window)
        defer { app.scheduleSheet?.close(); app.aiSheet?.close() }
        let views = descendants(reopenedWindow.contentView!)
        let currentEditor = try #require(views.compactMap { $0 as? AIQuestionEditor }.first)
        let start = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == (toAuto ? "開始" : "送信") })
        let destination = try #require(views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "送信先" })
        let originalText = fromAuto == toAuto ? "編集中の議事録" : toAuto ? "議事録の依頼" : "手動の依頼"
        #expect(currentEditor.string == originalText && !start.isEnabled && !destination.isEnabled)
        start.performClick(nil)
        #expect(!session.snapshot.aiSchedule.active)
        await gate.release()
        for _ in 0..<200 {
            if start.isEnabled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(start.isEnabled)
        let switched = fromAuto == toAuto && !fail
        #expect(currentEditor.string == (switched ? "相談の依頼" : originalText))
        if toAuto {
            #expect(app.scheduleSheet?.draft.minutes == (switched ? 11 : 7))
            #expect(session.aiScheduleConfiguration?.slot == config.aiProfiles[switched ? 1 : 0].slot)
        } else {
            #expect(app.aiSheet?.owningSlot == session.aiConfiguration?.slot)
            #expect(session.aiConfiguration?.slot == config.aiProfiles[switched ? 1 : 0].slot)
        }
        #expect(!session.snapshot.aiSchedule.active)
    }

    @Test func 手動シートも宛先の既定と空欄を含む編集を独立して保持する() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = try ResolvedConfig(config: ConfigLoader.parse(toml: """
        [[ai]]
        name = "議事録"
        autoPrompt = "議事録を更新"
        [[ai]]
        name = "相談"
        autoPrompt = "疑問点を列挙"
        [[ai]]
        name = "空欄"
        """), home: root)
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
                                     aiStore: AIRecordStore(directory: root))
        let window = TranscriptWindowController(shouldReduceMotion: { true })
        window.window?.setFrameAutosaveName("")
        defer { window.window?.orderOut(nil) }
        let prepared = AIPreparedStore(directory: root)
        let app = AppDelegate(testingSession: session, config: config, preparedStore: prepared, window: window)
        app.showAISheet(parent: nil)
        defer { app.aiSheet?.close() }
        let sheet = try #require(app.aiSheet)
        let views = descendants(try #require(sheet.window.contentView))
        let editor = try #require(views.compactMap { $0 as? AIQuestionEditor }.first)
        let popup = try #require(views.compactMap { $0 as? NSPopUpButton }.first)
        func select(_ index: Int) {
            popup.selectItem(withTitle: config.aiProfiles[index].name)
            popup.sendAction(popup.action, to: popup.target)
        }
        #expect(editor.string == "議事録を更新")
        editor.string = "担当者も記録"; sheet.textDidChange(Notification(name: NSText.didChangeNotification))
        select(1)
        #expect(editor.string == "疑問点を列挙")
        select(0)
        #expect(editor.string == "担当者も記録")
        sheet.updateDestinations(session.aiDestinationItems, selected: config.aiProfiles[0].slot, participant: "議事録")
        #expect(editor.string == "担当者も記録")
        editor.string = ""; sheet.textDidChange(Notification(name: NSText.didChangeNotification))
        select(2)
        #expect(editor.string.isEmpty)
        select(0)
        #expect(editor.string.isEmpty)
        let close = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "閉じる" })
        close.performClick(nil)
        app.showAISheet(parent: nil)
        #expect(app.aiSheet?.draft == "")
        #expect(session.scheduleDraft(for: config.aiProfiles[0]).prompt == "議事録を更新")
        app.aiSheet?.onCancel?()
        session.beginNextMeetingForTesting(recording: true)
        app.showAISheet(parent: nil)
        #expect(app.aiSheet?.draft == "議事録を更新")
    }

    @Test func 実シートで宛先の既定と編集を往復し閉じて開いても復元する() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var config = ResolvedConfig(config: KikigakiConfig(), home: root)
        config.aiProfiles = try ResolvedConfig(config: ConfigLoader.parse(toml: """
        [[ai]]
        name = "議事録"
        autoPrompt = "議事録を更新"
        autoIntervalMinutes = 7
        [[ai]]
        name = "相談"
        autoPrompt = "疑問点を列挙"
        autoIntervalMinutes = 11
        [[ai]]
        name = "空欄"
        """), home: root).aiProfiles
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
                                     aiStore: AIRecordStore(directory: root))
        let profiles = config.aiProfiles
        let sheet = AIScheduleSheet(session: session, profile: profiles[0])
        let views = descendants(try #require(sheet.window.contentView))
        let picker = try #require(views.compactMap { $0 as? AIDestinationPicker }.first)
        let popup = try #require(descendants(picker).compactMap { $0 as? NSPopUpButton }.first)
        func select(_ profile: ResolvedAIConfig) {
            popup.selectItem(withTitle: profile.name)
            popup.sendAction(popup.action, to: popup.target)
        }
        let editor = try #require(views.compactMap { $0 as? AIQuestionEditor }.first)
        let interval = try #require(views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "送信間隔" })
        let start = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "開始" })
        #expect(sheet.draft.prompt == "議事録を更新" && sheet.draft.minutes == 7)
        editor.string = "担当者も記録"; sheet.textDidChange(Notification(name: NSText.didChangeNotification))
        interval.selectItem(withTag: 5)
        interval.sendAction(interval.action, to: interval.target)
        select(profiles[1])
        #expect(editor.string == "疑問点を列挙" && sheet.draft.minutes == 11)
        #expect(start.isEnabled)
        select(profiles[0])
        #expect(editor.string == "担当者も記録" && sheet.draft.minutes == 5)
        // 非同期で候補が更新されても、入力中の文面を巻き戻さない。
        sheet.updateDestinations(session.aiDestinationItems, selected: profiles[0].slot, participant: "議事録")
        #expect(editor.string == "担当者も記録")
        // 空の下書きも意図した編集。既定値へフォールバックさせない。
        editor.string = ""; sheet.textDidChange(Notification(name: NSText.didChangeNotification))
        select(profiles[2])
        #expect(editor.string.isEmpty && !start.isEnabled)
        select(profiles[0])
        #expect(editor.string.isEmpty && !start.isEnabled && sheet.draft.minutes == 5)
        let close = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "閉じる" })
        close.performClick(nil)
        let reopened = AIScheduleSheet(session: session, profile: profiles[0])
        #expect(reopened.draft.prompt.isEmpty && reopened.draft.minutes == 5)
        // 準備済みの紐づけ完了で、session側の宛先だけが先に切り替わる経路。
        // 表示中のAの下書きはBへ誤保存しない。
        session.selectAIProfile(slot: profiles[1].slot, forSchedule: true)
        reopened.onDestination?(profiles[1].slot)
        #expect(reopened.draft.prompt == "疑問点を列挙" && reopened.draft.minutes == 11)
        reopened.onDestination?(profiles[0].slot)
        #expect(reopened.draft.prompt.isEmpty && reopened.draft.minutes == 5)
        session.beginNextMeetingForTesting(recording: true)
        let next = AIScheduleSheet(session: session, profile: profiles[0])
        #expect(next.draft.prompt == "議事録を更新" && next.draft.minutes == 7)
    }
}
