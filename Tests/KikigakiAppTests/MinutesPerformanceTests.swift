import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite(.serialized) @MainActor struct MinutesPerformanceTests {
    @Test func 四MiB更新のメインスレッド占有を測る() async throws {
        guard ProcessInfo.processInfo.environment["KIKIGAKI_MINUTES_PERF"] == "1" else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let view = MinutesPreviewView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view; window.orderFront(nil)
        defer { view.stop(); window.orderOut(nil) }
        let unit = String(repeating: "会議の決定事項と担当を確認します。", count: 6) + "\n\n"
        var text = String(repeating: unit, count: MinutesPath.bodyBytes / unit.utf8.count)
        text += String(repeating: "a", count: MinutesPath.bodyBytes - text.utf8.count)
        #expect(text.utf8.count == 4 * 1_048_576)
        let blocks = MarkdownBlocks.parse(text, minutes: true)
        view.layoutSubtreeIfNeeded()
        view.receive(.body(text, blocks))
        for _ in 0..<1000 {
            if !view.textView.string.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!view.textView.string.isEmpty)
        let changed = "b" + text.dropFirst()
        let next = MarkdownBlocks.parse(changed, minutes: true)
        view.receive(.body(changed, next))
        for _ in 0..<1000 {
            if view.textView.string.hasPrefix("b") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(view.textView.string.hasPrefix("b"))
        print("MINUTES_PERF update_main_ms=\(view.lastRenderMainMilliseconds) bytes=\(text.utf8.count)")
    }
}
