import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite(.serialized) @MainActor struct MinutesWindowRevisionTests {
    @Test func メニューは閉じた画面を開いて切り替え表題とAXを更新する() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TranscriptWindowController(minutesDefaults: defaults)
        let window = try #require(controller.window)
        defer { window.orderOut(nil); controller.minutesSplit.preview.stop() }
        let status = StatusItem()
        controller.onMinutesVisibility = { status.setMinutesVisible($0) }
        status.onToggleMinutes = { controller.show(); controller.toggleMinutes() }
        let item = NSMenuItem(title: "", action: #selector(TranscriptWindowController.toggleMinutes), keyEquivalent: "")
        #expect(controller.validateMenuItem(item) && item.title == "議事録を表示" && item.state == .off)
        window.orderOut(nil)
        status.toggleMinutes()
        #expect(window.isVisible && controller.minutesSplit.isPreviewVisible)
        #expect(status.minutesItem.title == "議事録を隠す" && status.minutesItem.state == .on)
        #expect(controller.validateMenuItem(item) && item.title == "議事録を隠す" && item.state == .on)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let button = try #require(descendants(controller.minutesSplit.left).compactMap { $0 as? NSButton }.first { $0.toolTip == "議事録を隠す" })
        #expect(button.accessibilityValue() as? String == "ON")
        status.toggleMinutes()
        #expect(status.minutesItem.title == "議事録を表示" && status.minutesItem.state == .off)
        #expect(button.accessibilityValue() as? String == "OFF")
    }
    @Test func 幅の保存と再ONと復元および制約判定を固定する() throws {
        let suite = UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let split = MinutesSplitView(left: NSView(), defaults: defaults)
        split.frame = NSRect(x: 0, y: 0, width: 1800, height: 800)
        split.setVisible(true)
        split.left.frame.size.width = 680; split.preview.frame.size.width = 900
        split.rememberWidths()
        split.setVisible(false)
        split.left.frame.size.width = 1512 // OFF中の画面制約をON時に希望幅へ写さない
        split.setVisible(true)
        #expect(split.preference.leftWidth == 680 && split.preference.rightWidth == 900)
        let restored = MinutesSplitView(left: NSView(), defaults: defaults)
        #expect(restored.preference == split.preference)
        let screen = NSRect(x: 0, y: 0, width: 1800, height: 1000)
        #expect(MinutesLayout.constrained(frame: .zero, screen: screen, fullScreen: true))
        #expect(MinutesLayout.constrained(frame: NSRect(x: 0, y: 0, width: 900, height: 1000), screen: screen, fullScreen: false))
        #expect(MinutesLayout.constrained(frame: screen, screen: screen, fullScreen: false))
        #expect(!MinutesLayout.constrained(frame: NSRect(x: 0, y: 0, width: 600, height: 1000), screen: screen, fullScreen: false))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = restored
        defer { window.orderOut(nil) }
        if let actual = window.screen?.visibleFrame {
            window.setFrame(NSRect(x: actual.minX, y: actual.minY, width: actual.width / 2, height: actual.height), display: false)
            let before = restored.preference
            restored.left.frame.size.width = 430; restored.preview.frame.size.width = 330
            restored.rememberWidths()
            restored.setVisible(false); restored.setVisible(true)
            #expect(restored.preference == before)
        }
    }
    @Test func フォーカスだけでドラフトを守り確定エラーを次の更新でも残す() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let view = MinutesPreviewView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view; window.orderFront(nil)
        defer { window.orderOut(nil); view.stop() }
        view.update(path: "/tmp/old.md", source: .human, active: false)
        #expect(window.makeFirstResponder(view.pathField))
        view.update(path: "/tmp/new.md", source: .ai, active: false)
        #expect(view.pathField.stringValue == "/tmp/old.md")
        view.pathField.stringValue = "relative.md"; view.commitPath()
        view.update(path: "/tmp/new.md", source: .ai, active: false)
        #expect(!view.notice.isHidden && view.notice.stringValue.contains("絶対パス"))
        var selected: String?
        view.onSelect = { selected = $0 }
        view.pathField.stringValue = "~/minutes.md"; view.commitPath()
        #expect(selected == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("minutes.md").path)
        #expect(view.notice.isHidden)
        view.update(path: "/tmp/none.md", source: .ai, active: false)
        view.receive(.missing)
        #expect(view.message.stringValue.hasPrefix("AIが通知したファイル"))
    }
    @Test func 待機指定は開始取消再開始と二回目の準備でも一度だけ適用する() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = ResolvedConfig(config: try ConfigLoader.parse(toml: ""), home: root)
        let records = AIRecordStore(directory: root)
        let session = MeetingSession(config: config, models: { throw CancellationError() }, log: { _ in }, aiStore: records)
        try session.selectMinutes("/tmp/初回.md")
        session.setMinutesPreparationForTesting()
        try session.completeMinutesPreparationForTesting(at: root.appendingPathComponent("first.md"))
        #expect(try session.previewMinutesStore()?.state.humanMinutesPath == "/tmp/初回.md")
        #expect(session.waitingMinutesPath == nil)
        await session.abandon()
        #expect(session.waitingMinutesPath == "/tmp/初回.md")
        session.setMinutesPreparationForTesting()
        try session.completeMinutesPreparationForTesting(at: root.appendingPathComponent("restart.md"))
        #expect(try session.previewMinutesStore()?.state.humanMinutesPath == "/tmp/初回.md")
        session.setMinutesPreparationForTesting()
        try session.selectMinutes("/tmp/二回目.md")
        session.setMinutesPreparationForTesting() // 開始取消後、次の準備へ。未適用の指定を保持
        #expect(session.waitingMinutesPath == "/tmp/二回目.md")
        try session.completeMinutesPreparationForTesting(at: root.appendingPathComponent("second.md"))
        #expect(try session.previewMinutesStore()?.state.humanMinutesPath == "/tmp/二回目.md")
        #expect(session.waitingMinutesPath == nil)
        session.setMinutesPreparationForTesting()
        try session.selectMinutes("/tmp/失敗.md")
        let store = try records.minutesStores.store(meetingID: session.aiMeetingID, markdownURL: root.appendingPathComponent("third.md"))
        var attempts = 0
        store.beforeSave = { attempts += 1; throw AIError.unsafeFile }
        try session.completeMinutesPreparationForTesting(at: root.appendingPathComponent("third.md"))
        _ = try session.previewMinutesStore(); _ = try session.previewMinutesStore()
        #expect(attempts == 1 && session.waitingMinutesPath == nil && store.warning != nil)
        store.beforeSave = nil; try session.selectMinutes("/tmp/再確定.md")
        #expect(store.state.humanMinutesPath == "/tmp/再確定.md")
    }
}
