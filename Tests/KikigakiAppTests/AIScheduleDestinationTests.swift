import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

// 実際にシートを開くケースは順番に実行し、複数のモーダル表示を競合させない。
@Suite(.serialized) @MainActor struct AIScheduleDestinationTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

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
        let app = AppDelegate(testingSession: session, config: config, window: window)
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
        // session側の宛先だけが先に切り替わる経路。表示中のAの下書きはBへ誤保存しない。
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
