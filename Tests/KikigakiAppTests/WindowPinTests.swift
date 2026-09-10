import AppKit
import Testing
@testable import Kikigaki

@Suite @MainActor struct WindowPinTests {
    @Test func ピンボタンは最前面を切り替え表示更新でも保持する() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = TranscriptWindowController(shouldReduceMotion: { true })
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        let button = controller.compactFooter.pin
        #expect(window.level == .normal)
        button.performClick(nil)
        #expect(window.level == .floating && button.symbolName == "pin.fill")
        controller.apply(SessionSnapshot())
        #expect(window.level == .floating)
        button.performClick(nil)
        #expect(window.level == .normal && button.symbolName == "pin")
    }
}
