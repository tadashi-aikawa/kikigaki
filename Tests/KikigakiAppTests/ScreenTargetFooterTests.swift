import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

extension AppKitTests {
/// フッターの画面の記録の操作。ピンの隣に置き、状態とディスプレイ名を出す。仕様は docs/screen-capture.md の「録音中の切り替え」
///
/// `KIKIGAKI_UI_CAPTURE=<出力先>` で、記録中・撮らない・一時停止中・撮れなくなった状態と、狭い幅と長い名前を撮る。
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct ScreenTargetFooterTests {
    private let display = ScreenDisplay(id: 1, name: "EV3895", points: CGSize(width: 64, height: 36), menuBarFraction: 0)
    private let long = ScreenDisplay(id: 2, name: "Built-in Retina Display", points: CGSize(width: 64, height: 36), menuBarFraction: 0)

    private func window(width: CGFloat) throws -> (TranscriptWindowController, UserDefaults, String) {
        _ = NSApplication.shared
        let suite = "ScreenTargetFooterTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults, textDefaults: defaults)
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        window.setContentSize(NSSize(width: width, height: 578))
        window.setFrameOrigin(NSPoint(x: 20000, y: 20000)); window.orderFront(nil)
        controller.apply(state(nil))
        let size = controller.windowWillResize(window, to: NSSize(width: width, height: 600))
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        #expect(abs(content.bounds.width - width) < 1)
        return (controller, defaults, suite)
    }

    /// モックと同じく、自動は「送らない」、手動は宛先を選んだ録音中の会議。
    private func state(_ control: ScreenControlState?, paused: Bool = false) -> SessionSnapshot {
        var state = SessionSnapshot(ai: AIViewState(conversation: AIConversation(meetingID: UUID())), state: paused ? .paused : .recording,
            utterances: [.init(speaker: 0, start: 0, end: 1, text: "資料の2ページ目を見てください。")])
        state.manualDestination = .init(slot: 2, name: "相談")
        state.manualDraftSendState = .ready(appendix: false)
        state.screenControl = control
        return state
    }

    private func capture(_ name: String, _ view: NSView) throws {
        guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] else { return }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // 描画キャッシュの中間物。確認用はcwebpで非可逆WebPへ変換する。
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathComponent("screen-footer-\(name).png"))
    }

    @Test(arguments: [820, 420]) func 画面の操作はピンの隣に置き_狭い幅では名前だけを省く(width: Int) throws {
        let (controller, defaults, suite) = try window(width: CGFloat(width))
        defer { defaults.removePersistentDomain(forName: suite); controller.window?.orderOut(nil) }
        let footer = controller.compactFooter
        let content = try #require(controller.window?.contentView)
        let cases: [(String, ScreenControlState?, Bool)] = [
            ("on", ScreenControlState(display: .on(display), selected: display, paused: false), false),
            ("off", ScreenControlState(display: .off, selected: nil, paused: false), false),
            ("paused", ScreenControlState(display: .on(display), selected: display, paused: true), true),
            ("failed", ScreenControlState(display: .failed(display), selected: display, paused: false), false),
            ("long", ScreenControlState(display: .on(long), selected: long, paused: false), false),
            ("stopped", nil, false)
        ]
        for (name, control, paused) in cases {
            controller.apply(state(control, paused: paused))
            content.layoutSubtreeIfNeeded()
            #expect(footer.screen.isHidden == (control == nil))
            if control != nil {
                // ピンのすぐ左。宛先の2段と重ならない。
                #expect(abs(footer.pin.frame.minX - footer.spacing - footer.screen.frame.maxX) < 1)
                #expect(footer.screen.frame.minX >= footer.destinations.frame.maxX)
                #expect(footer.screen.frame.width >= ScreenTargetButton.minimumWidth - 0.5)
                #expect(footer.screen.frame.width <= ScreenTargetButton.maximumWidth + 0.5)
                #expect(footer.more.frame.maxX <= footer.bounds.maxX)
            }
            try capture("\(name)-\(width)", footer)
        }
        // 撮れなくなった状態は、ヘッダーの1行と合わせてウィンドウ全体でも撮る。
        var failed = state(ScreenControlState(display: .failed(display), selected: display, paused: false))
        failed.screenCaptureWarning = "画面を記録できません: ディスプレイが見つかりません"
        controller.apply(failed)
        try capture("full-failed-\(width)", content)
    }
}
}
