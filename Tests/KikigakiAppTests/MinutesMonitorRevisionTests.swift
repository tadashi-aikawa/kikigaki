import AppKit
import Darwin
import Testing
@testable import Kikigaki

@Suite(.serialized) @MainActor struct MinutesMonitorRevisionTests {
    private actor Gate {
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
    @Test func 読込中の旧世代は停止後に完了しても結果を返さない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("a.md"); try Data("a".utf8).write(to: path)
        let gate = Gate()
        var received = false
        let monitor = MinutesFileMonitor(path: path.path, interval: 0.05, read: { _ in
            await gate.wait(); return .body("古い本文", [])
        }) { _ in received = true }
        for _ in 0..<100 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await gate.entered)
        monitor.stop(); await gate.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!received)
    }
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
    @Test func FIFO監視は即座に戻り読取失敗を繰り返さない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("fifo.md")
        #expect(mkfifo(path.path, 0o600) == 0)
        var failures = 0
        let start = Date()
        let monitor = MinutesFileMonitor(path: path.path, interval: 0.05) {
            if case .failure = $0 { failures += 1 }
        }
        defer { monitor.stop() }
        #expect(Date().timeIntervalSince(start) < 0.1)
        try await eventually { failures == 1 }
        try await Task.sleep(for: .milliseconds(400))
        #expect(failures == 1)
    }
    @Test func 同サイズ保存と親交換とsymlink交換を走査の手動呼出しなしで検出する() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let path = parent.appendingPathComponent("a.md"), link = root.appendingPathComponent("link.md")
        try Data("初版".utf8).write(to: path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        var body = ""
        let monitor = MinutesFileMonitor(path: link.path, interval: 0.05) { if case .body(let text, _) = $0 { body = text } }
        defer { monitor.stop() }
        try await eventually { body == "初版" }
        try Data("新版".utf8).write(to: path)
        try await eventually { body == "新版" }
        try FileManager.default.moveItem(at: parent, to: root.appendingPathComponent("old"))
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("親交換".utf8).write(to: path)
        try await eventually { body == "親交換" }
        let other = root.appendingPathComponent("b.md")
        try Data("リンク交換".utf8).write(to: other)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        try await eventually { body == "リンク交換" }
    }
    @Test func 読込待ちの対象切替と非表示停止から再表示を通す() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.md"), b = root.appendingPathComponent("b.md")
        try Data("前会議".utf8).write(to: a); try Data("次会議".utf8).write(to: b)
        let view = MinutesPreviewView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { view.stop() }
        view.update(path: a.path, source: .human, active: true)
        view.resetContext()
        view.update(path: b.path, source: .human, active: true)
        try await eventually { view.textView.string == "次会議" }
        try await Task.sleep(for: .milliseconds(350)); #expect(!view.textView.string.contains("前会議"))
        view.update(path: b.path, source: .human, active: false)
        try Data("非表示中更新".utf8).write(to: b)
        try await Task.sleep(for: .milliseconds(350)); #expect(view.textView.string == "次会議")
        view.update(path: b.path, source: .human, active: true)
        try await eventually { view.textView.string == "非表示中更新" }
        view.update(path: b.path, source: .human, active: false)
        view.update(path: b.path, source: .human, active: true)
        try await eventually { !view.scroll.isHidden }
        #expect(view.textView.string == "非表示中更新")
        view.receive(.body("背景生成中", [.paragraph([.init("背景生成中")])]))
        view.update(path: b.path, source: .human, active: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.textView.string == "非表示中更新")
        view.receive(.body("途中版", [.paragraph([.init("途中版")])]))
        view.receive(.body("非表示中更新", [.paragraph([.init("非表示中更新")])]))
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.textView.string == "非表示中更新")
    }
}
