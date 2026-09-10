import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct NarrowWindowTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @Test func 幅420で各録音状態の操作が収まり広げると文字が戻る() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = TranscriptWindowController(shouldReduceMotion: { true })
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        defer { window.orderOut(nil) }
        let content = try #require(window.contentView)
        for state: RecordingState in [.idle, .preparing, .recording, .paused, .finishing] {
            let snapshot = SessionSnapshot(state: state, elapsed: 36_000,
                markdownURL: URL(fileURLWithPath: "/tmp/layout-meeting.md"), saved: state == .idle)
            controller.apply(snapshot)
            // 実際のドラッグと同じwillResize経路を通してからフレームを反映する。
            let size = controller.windowWillResize(window, to: NSSize(width: 420, height: 650))
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
            content.layoutSubtreeIfNeeded()
            #expect(abs(window.frame.width - 420) < 1)
            let buttons = descendants(content).compactMap { $0 as? WashiActionButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
            #expect(!buttons.isEmpty)
            for button in buttons {
                #expect(button.title.isEmpty && button.image != nil)
                #expect(button.toolTip?.isEmpty == false && button.frame.width >= 32)
                let rect = button.convert(button.bounds, to: content)
                #expect(rect.minX >= 0 && rect.maxX <= content.bounds.width)
            }
            let header = try #require(buttons.first?.superview as? NSStackView)
            let visible = header.arrangedSubviews.filter { !$0.isHiddenOrHasHiddenAncestor }
            for pair in zip(visible, visible.dropFirst()) {
                #expect(pair.0.frame.maxX <= pair.1.frame.minX + 1)
            }
            controller.showSearch(nil)
            content.layoutSubtreeIfNeeded()
            #expect(abs(window.frame.width - 420) < 1)
            #expect(controller.searchField.frame.width >= 80)
            controller.closeSearch(nil)
            if let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] {
                let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent("narrow-\(state).png"))
            }
            window.setContentSize(NSSize(width: 600, height: 650))
            controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
            content.layoutSubtreeIfNeeded()
            #expect(buttons.allSatisfy { !$0.title.isEmpty })
        }
    }
}
