import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite(.serialized) @MainActor struct MinutesPerformanceTests {
    @Test func 四MiBの描画更新と検索を測る() async throws {
        guard ProcessInfo.processInfo.environment["KIKIGAKI_MINUTES_PERF"] == "1" else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let preferences = MinutesTestDefaults()
        let view = MinutesPreviewView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), defaults: preferences.value)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view; window.orderFront(nil)
        defer { view.stop(); window.orderOut(nil) }
        let unit = String(repeating: "会議の決定事項と担当を確認します。", count: 6) + "\n\n"
        var text = String(repeating: unit, count: MinutesPath.bodyBytes / unit.utf8.count)
        text += String(repeating: "a", count: MinutesPath.bodyBytes - text.utf8.count)
        #expect(text.utf8.count == 4 * 1_048_576)
        view.layoutSubtreeIfNeeded()
        let started = Date()
        view.receive(.body(text, []))
        for _ in 0..<1000 {
            if !view.document.renderedText.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!view.document.renderedText.isEmpty)
        let changed = "b" + text.dropFirst()
        let updated = Date()
        view.receive(.body(changed, []))
        for _ in 0..<1000 {
            if view.document.renderedText.hasPrefix("b") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(view.document.renderedText.hasPrefix("b"))
        let searched = Date()
        let result = try await view.document.webView.evaluateJavaScript("window.minutes.search('担当')") as? [String: Int]
        #expect(result?["count"] == 10000)
        print("MINUTES_PERF initial_s=\(updated.timeIntervalSince(started)) update_s=\(searched.timeIntervalSince(updated)) search_s=\(Date().timeIntervalSince(searched)) bytes=\(text.utf8.count)")
    }
}
