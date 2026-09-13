import AppKit
import Testing
@testable import Kikigaki

@Suite(.serialized) @MainActor struct MinutesHistoryUITests {
    private final class CountingDefaults: UserDefaults, @unchecked Sendable {
        var historyWrites = 0
        override func set(_ value: Any?, forKey key: String) {
            historyWrites += 1
            super.set(value, forKey: key)
        }
    }

    @Test func 先頭の再描画では履歴を永続化し直さない() throws {
        let suite = "minutes-history-writes-\(UUID().uuidString)"
        let defaults = try #require(CountingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MinutesHistoryStore(defaults: defaults)
        store.record("/tmp/会議A.md")
        store.record("/tmp/会議A.md")
        #expect(defaults.historyWrites == 1)
        store.record("/tmp/会議B.md")
        store.record("/tmp/会議A.md")
        #expect(defaults.historyWrites == 3)
        #expect(store.paths == ["/tmp/会議A.md", "/tmp/会議B.md"])
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }

    @Test func 描画成功だけを記録し人とAIと空ファイルを同じ履歴へ戻す() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.md"), b = root.appendingPathComponent("b.md")
        let empty = root.appendingPathComponent("empty.md"), bad = root.appendingPathComponent("bad.md")
        try Data("# 前回の会議".utf8).write(to: a); try Data("# 次の会議".utf8).write(to: b)
        try Data().write(to: empty); try Data([0xff, 0xfe, 0xff]).write(to: bad)
        let preferences = MinutesTestDefaults()
        let view = MinutesPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 740), defaults: preferences.value)
        defer { view.stop() }
        view.update(path: a.path, source: .human, active: true)
        #expect(view.history.paths.isEmpty)
        try await eventually { view.history.paths == [a.path] }
        view.resetContext()
        view.update(path: b.path, source: .ai, active: false)
        #expect(view.history.paths == [a.path])
        view.update(path: b.path, source: .ai, active: true)
        try await eventually { view.history.paths == [b.path, a.path] }
        view.update(path: bad.path, source: .human, active: true)
        try await eventually { view.message.stringValue.contains("UTF-8") }
        #expect(view.history.paths == [b.path, a.path])
        view.update(path: root.appendingPathComponent("missing.md").path, source: .human, active: true)
        try await eventually { view.message.stringValue.contains("まだありません") }
        #expect(view.history.paths == [b.path, a.path])
        view.update(path: a.path, source: .human, active: true)
        view.update(path: empty.path, source: .ai, active: true)
        try await eventually { view.history.paths == [empty.path, b.path, a.path] }
        #expect(view.message.stringValue == "議事録はまだ空です")
        view.update(path: a.path, source: .human, active: true)
        try await eventually { view.history.paths == [a.path, empty.path, b.path] }
        #expect(MinutesHistoryStore(defaults: preferences.value).paths == view.history.paths)
    }

    @Test func フォーカスで開き矢印確定とEscapeの優先順と失焦点を扱う() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let zero = MinutesHistoryPopup(frame: .zero)
        zero.needsLayout = true; zero.layoutSubtreeIfNeeded()
        #expect(zero.subviews.allSatisfy { $0.frame.origin.x.isFinite && $0.frame.origin.y.isFinite })
        let preferences = MinutesTestDefaults()
        preferences.value.set(["/tmp/会議A.md", "/tmp/会議B.md"], forKey: MinutesHistoryStore.key)
        let view = MinutesPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 740), defaults: preferences.value)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view; window.orderFront(nil); view.layoutSubtreeIfNeeded()
        defer { view.stop(); window.orderOut(nil) }
        var chosen: String?
        view.onSelect = { chosen = $0 }
        #expect(window.makeFirstResponder(view.pathField))
        try await eventually { !view.historyPopup.isHidden }
        #expect(view.historyPopup.selectedPath == "/tmp/会議A.md")
        let editor = try #require(view.pathField.currentEditor() as? NSTextView)
        func command(_ selector: Selector) -> Bool { view.control(view.pathField, textView: editor, doCommandBy: selector) }
        #expect(command(#selector(NSResponder.moveDown(_:))))
        #expect(command(#selector(NSResponder.moveDown(_:))))
        #expect(view.historyPopup.selectedPath == "/tmp/会議B.md")
        #expect(command(#selector(NSResponder.insertNewline(_:))))
        #expect(chosen == "/tmp/会議B.md" && view.historyPopup.isHidden)
        #expect(window.makeFirstResponder(view.pathField))
        try await eventually { !view.historyPopup.isHidden }
        view.pathField.stringValue = "/tmp/下書き.md"
        #expect(command(#selector(NSResponder.cancelOperation(_:))))
        #expect(view.historyPopup.isHidden && view.pathField.stringValue == "/tmp/下書き.md")
        #expect(view.pathField.currentEditor() != nil)
        #expect(command(#selector(NSResponder.cancelOperation(_:))))
        #expect(view.pathField.stringValue.isEmpty)
        #expect(window.makeFirstResponder(view.pathField))
        try await eventually { !view.historyPopup.isHidden }
        window.makeFirstResponder(nil)
        #expect(view.historyPopup.isHidden)
        preferences.value.set([], forKey: MinutesHistoryStore.key)
        #expect(window.makeFirstResponder(view.pathField))
        try await Task.sleep(for: .milliseconds(50))
        #expect(view.historyPopup.isHidden)
    }

    @Test func 行クリックと不存在の表示と余白と非キー化と高さ不足() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let preferences = MinutesTestDefaults()
        let missing = "/tmp/履歴テスト-\(UUID().uuidString)/未作成.md"
        preferences.value.set([missing, (missing as NSString).deletingLastPathComponent + "/次.md", "/別の場所/会議.md"], forKey: MinutesHistoryStore.key)
        let view = MinutesPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 740), defaults: preferences.value)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view; window.orderFront(nil); view.layoutSubtreeIfNeeded()
        defer { view.stop(); window.orderOut(nil) }
        func focus() async throws {
            window.makeFirstResponder(nil)
            #expect(window.makeFirstResponder(view.pathField))
            try await eventually { !view.historyPopup.isHidden }
        }
        var chosen: String?
        view.onSelect = { chosen = $0 }
        try await focus()
        let rows = view.historyPopup.rows
        #expect(rows.map(\.rowHeight) == [44, 28, 44])
        #expect(rows[0].filename.textColor == Washi.ink)
        #expect(!rows[0].missingLabel.isHidden)
        #expect(rows[0].announcement == "未作成.md、見つかりません")
        #expect(NSApp.sendAction(try #require(rows[0].action), to: rows[0].target, from: rows[0]))
        #expect(chosen == missing && view.historyPopup.isHidden)
        try await focus()
        let popup = view.historyPopup
        let point = popup.convert(NSPoint(x: 1, y: 1), to: window.contentView)
        #expect(popup.hitTest(point) === popup)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        popup.mouseDown(with: event)
        #expect(popup.isHidden && view.pathField.currentEditor() != nil)
        try await focus()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(popup.isHidden)
        try await focus()
        // NSWindowの最小寸法制約を避け、欄の下が44pt未満になる配置を直接与える。
        view.headerBar.setFrameOrigin(.zero)
        view.showHistory()
        #expect(popup.isHidden)
        let editor = try #require(view.pathField.currentEditor() as? NSTextView)
        #expect(!view.control(view.pathField, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
    }
}
