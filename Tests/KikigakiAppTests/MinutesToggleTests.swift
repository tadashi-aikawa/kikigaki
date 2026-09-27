import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite(.serialized) @MainActor struct MinutesToggleTests {
    private func controller(width: CGFloat) throws -> (TranscriptWindowController, UserDefaults, String) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "minutes-toggle-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults)
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        window.setFrame(NSRect(x: 0, y: 100, width: width, height: 700), display: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        return (controller, defaults, suite)
    }
    /// 画像の書き出しは `KIKIGAKI_UI_CAPTURE` を渡したときだけ行う。
    private func capture(_ name: String, _ controller: TranscriptWindowController) throws {
        guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"],
              let content = controller.window?.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathComponent("minutes-toggle-\(name).png"))
    }

    @Test func 開閉ボタンはウィンドウの右上から動かず開いている間は押し込み表示になる() throws {
        let (controller, defaults, suite) = try controller(width: 800)
        defer { defaults.removePersistentDomain(forName: suite); controller.minutesSplit.preview.stop() }
        let window = try #require(controller.window), content = try #require(window.contentView)
        let button = controller.minutesButton
        func place() -> (right: CGFloat, midY: CGFloat) {
            content.layoutSubtreeIfNeeded()
            let rect = button.convert(button.bounds, to: content)
            return (content.bounds.maxX - rect.maxX, rect.midY)
        }
        let closed = place()
        try capture("closed", controller)
        #expect(!button.isOn && button.title == "議事録" && button.accessibilityValue() as? String == "OFF")
        #expect(button.isDescendant(of: controller.minutesSplit.left))
        controller.toggleMinutes()
        let open = place()
        try capture("open", controller)
        controller.minutesSplit.preview.update(path: "/tmp/kikigaki-toggle-example.md", source: .human, active: false)
        try capture("open-path", controller)
        #expect(button.isOn && button.title.isEmpty && button.accessibilityValue() as? String == "ON")
        #expect(button.toolTip == "議事録を隠す" && button.superview === controller.minutesSplit.preview.headerBar)
        #expect(abs(open.right - closed.right) < 0.5 && abs(open.midY - closed.midY) < 0.5)
        #expect(abs(button.frame.width - 32) < 0.5 && abs(button.frame.height - 32) < 0.5, "\(button.frame)")
        // パス欄の行はボタンの手前で終わり、重ならない。
        let preview = controller.minutesSplit.preview
        let field = preview.pathField.convert(preview.pathField.bounds, to: content)
        #expect(field.maxX <= button.convert(button.bounds, to: content).minX)
        controller.toggleMinutes()
        let back = place()
        #expect(!button.isOn && button.title == "議事録" && button.isDescendant(of: controller.minutesSplit.left))
        #expect(abs(back.right - closed.right) < 0.5 && abs(back.midY - closed.midY) < 0.5)
    }

    @Test func 伸ばせるウィンドウは会話の幅を保って右へ伸び閉じると元へ戻る() throws {
        let (controller, defaults, suite) = try controller(width: 600)
        defer { defaults.removePersistentDomain(forName: suite); controller.minutesSplit.preview.stop() }
        let window = try #require(controller.window), split = controller.minutesSplit!
        split.animates = { true }
        let start = window.frame
        split.setVisible(true)
        // 状態・AX・メニューは押した時点で切り替わり、配置だけが後を追う。
        #expect(split.isPreviewVisible && split.isTransitioning && !split.preview.isHidden)
        #expect(controller.minutesButton.accessibilityValue() as? String == "ON")
        split.stepTransition(progress: 0.5)
        let middle = window.frame.width
        #expect(middle > start.width && abs(split.left.frame.width - 600) < 0.5)
        let previewWidth = split.preview.frame.width
        split.stepTransition(progress: 1)
        #expect(!split.isTransitioning && window.frame.width > middle)
        // 途中の議事録ペインは最終の幅のまま右端から現れ、中身を細い幅で組み直さない。
        #expect(abs(split.preview.frame.width - previewWidth) < 0.5 && abs(split.left.frame.width - 600) < 0.5)
        let opened = window.frame
        split.setVisible(false)
        split.stepTransition(progress: 0.5)
        #expect(!split.preview.isHidden && abs(split.preview.frame.width - previewWidth) < 0.5)
        split.stepTransition(progress: 1)
        #expect(split.preview.isHidden && abs(window.frame.width - start.width) < 0.5 && split.left.frame == split.bounds)
        // 動かさない経路と同じ最終配置になる。
        split.animates = { false }
        split.setVisible(true)
        #expect(!split.isTransitioning && window.frame == opened && abs(split.preview.frame.width - previewWidth) < 0.5)
    }

    @Test func 伸ばせないウィンドウは議事録ペインが右端から滑り込み会話側が縮む() throws {
        // 画面の無いテストでは1800幅を画面とみなす。全幅のウィンドウは伸ばせず、分割だけで開く。
        let (controller, defaults, suite) = try controller(width: 1800)
        defer { defaults.removePersistentDomain(forName: suite); controller.minutesSplit.preview.stop() }
        let window = try #require(controller.window), split = controller.minutesSplit!
        split.animates = { true }
        let frame = window.frame
        split.setVisible(true)
        split.stepTransition(progress: 0.5)
        try capture("slide-middle", controller)
        let middleLeft = split.left.frame.width, previewWidth = split.preview.frame.width
        #expect(window.frame == frame && middleLeft < split.bounds.width)
        #expect(split.preview.frame.minX > split.bounds.width - previewWidth)
        split.stepTransition(progress: 1)
        #expect(window.frame == frame && split.left.frame.width < middleLeft)
        #expect(abs(split.preview.frame.maxX - split.bounds.width) < 0.5 && abs(split.preview.frame.width - previewWidth) < 0.5)
        // 途中で閉じても、その場から戻り、希望幅を途中の幅で上書きしない。閉じ始めの会話幅だけを希望幅にする。
        let settled = split.left.frame.width
        split.setVisible(false)
        let preferred = split.preference.leftWidth
        #expect(preferred == settled)
        split.stepTransition(progress: 0.3)
        split.setVisible(true)
        split.stepTransition(progress: 0.4)
        split.setVisible(false)
        split.finishTransition()
        #expect(split.preference.leftWidth == preferred && split.preview.isHidden && split.left.frame == split.bounds)
    }

    @Test func ライブリサイズ以外で変わった幅も開く直前の会話幅を保って右へ伸ばす() throws {
        // 保存値が狭いまま、ズームボタンやウィンドウ管理アプリで閉じたウィンドウだけを広げた場面。
        let suite = "minutes-toggle-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(MinutesLayout(visible: false, leftWidth: 428, rightWidth: 900)), forKey: MinutesLayout.key)
        NSApplication.shared.setActivationPolicy(.prohibited)
        for animated in [false, true] {
            let controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults)
            defer { controller.minutesSplit.preview.stop() }
            let window = try #require(controller.window), split = controller.minutesSplit!
            window.setFrameAutosaveName("")
            window.setFrame(NSRect(x: 0, y: 100, width: 800, height: 700), display: false)
            split.animates = { animated }
            split.setVisible(true)
            if animated {
                split.stepTransition(progress: 0.5)
                #expect(abs(split.left.frame.width - 800) < 0.5)
                split.stepTransition(progress: 1)
            }
            #expect(abs(split.left.frame.width - 800) < 0.5 && window.frame.width > 800)
            #expect(split.preference.leftWidth == 800)
            split.setVisible(false); split.finishTransition()
            #expect(abs(window.frame.width - 800) < 0.5 && split.left.frame == split.bounds)
            defaults.set(try JSONEncoder().encode(MinutesLayout(visible: false, leftWidth: 428, rightWidth: 900)), forKey: MinutesLayout.key)
        }
    }

    @Test(arguments: [false, true])
    func 閉じると開いていた会話幅を保ち議事録の分だけウィンドウを縮める(animated: Bool) throws {
        let fallback = NSRect(x: 0, y: 0, width: 1800, height: 1000)
        // 初期サイズ・手で広げたサイズ・画面いっぱい(タイル推定)の3状態。
        for name in ["initial", "widened", "tiled"] {
            let (controller, defaults, suite) = try controller(width: 600)
            defer { defaults.removePersistentDomain(forName: suite); controller.minutesSplit.preview.stop() }
            let window = try #require(controller.window), split = controller.minutesSplit!
            let screen = window.screen?.visibleFrame ?? fallback
            switch name {
            case "widened": window.setFrame(NSRect(x: screen.minX + 40, y: screen.minY + 40, width: 1100, height: 700), display: false)
            case "tiled":
                window.setFrame(screen, display: false)
                if window.screen != nil {
                    #expect(MinutesLayout.constrained(frame: window.frame, screen: screen, fullScreen: false), "\(name)")
                }
            default: break
            }
            split.animates = { animated }
            func settle() { if animated { split.stepTransition(progress: 0.5); split.stepTransition(progress: 1) } }
            let closedLeft = window.frame.minX
            split.setVisible(true); settle()
            let openLeft = split.left.frame.width
            #expect(!split.isTransitioning && openLeft >= MinutesLayout.minimumLeft, "\(name)")
            split.setVisible(false)
            if animated {
                split.stepTransition(progress: 0.5)
                #expect(abs(split.left.frame.width - openLeft) < 0.5 && !split.preview.isHidden, "\(name)")
                split.stepTransition(progress: 1)
            }
            #expect(abs(window.frame.width - openLeft) < 0.5 && abs(window.frame.minX - closedLeft) < 0.5, "\(name)")
            #expect(split.left.frame == split.bounds && split.preview.isHidden && split.preference.leftWidth == openLeft, "\(name)")
            // 開く側は変えない。閉じた幅から右へ伸ばし、会話幅はそのまま。
            split.setVisible(true); settle()
            #expect(abs(split.left.frame.width - openLeft) < 0.5 && abs(window.frame.minX - closedLeft) < 0.5, "\(name)")
        }
    }

    @Test func 閉じる枠はフルスクリーンだけ保ちそれ以外は会話幅まで縮める() {
        let frame = NSRect(x: 100, y: 50, width: 1800, height: 1000)
        #expect(MinutesLayout.closingFrame(frame: frame, leftWidth: 700, fullScreen: true) == frame)
        #expect(MinutesLayout.closingFrame(frame: frame, leftWidth: 700, fullScreen: false) == NSRect(x: 100, y: 50, width: 700, height: 1000))
        // 最小幅を下回らず、閉じても今より広げない。
        #expect(MinutesLayout.closingFrame(frame: frame, leftWidth: 300, fullScreen: false).width == MinutesLayout.minimumLeft)
        #expect(MinutesLayout.closingFrame(frame: NSRect(x: 0, y: 0, width: 500, height: 600), leftWidth: 900, fullScreen: false).width == 500)
    }

    @Test func 見えていないウィンドウでは開閉を一瞬で切り替える() throws {
        let (controller, defaults, suite) = try controller(width: 600)
        defer { defaults.removePersistentDomain(forName: suite); controller.minutesSplit.preview.stop() }
        controller.toggleMinutes()
        #expect(!controller.minutesSplit.isTransitioning && !controller.minutesSplit.preview.isHidden)
        controller.toggleMinutes()
        #expect(!controller.minutesSplit.isTransitioning && controller.minutesSplit.preview.isHidden)
    }
}
