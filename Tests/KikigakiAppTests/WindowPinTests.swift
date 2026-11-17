import AppKit
import Testing
@testable import Kikigaki

extension AppKitTests {
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

    @Test func グローバルキーで固定すると隠れたウィンドウを前に出し_解除ではウィンドウを動かさない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = TranscriptWindowController(shouldReduceMotion: { true })
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        let button = controller.compactFooter.pin
        window.orderOut(nil)
        #expect(!window.isVisible)
        controller.togglePinFromHotkey()
        #expect(window.isVisible && window.level == .floating)
        #expect(button.symbolName == "pin.fill" && button.accessibilityValue() as? String == "ON")
        controller.togglePinFromHotkey()
        #expect(window.isVisible && window.level == .normal && button.symbolName == "pin")
        // 閉じたまま解除しても出さない。
        controller.togglePinFromHotkey()
        window.orderOut(nil)
        controller.togglePinFromHotkey()
        #expect(!window.isVisible && window.level == .normal)
        window.close()
    }
}
}
