import AppKit
import Testing
@testable import Kikigaki

@Suite @MainActor struct AISheetCloseLabelTests {
    @Test func 表示を閉じるシートは閉じると表記してEscの操作を保つ() throws {
        _ = NSApplication.shared
        let ask = AIQuestionSheet(participant: "迅雷", parentNumber: nil, draft: "下書き", voice: "", range: "", tentative: false, canSubmit: true)
        let schedule = AIScheduleSheet(prompt: "依頼", minutes: 3, workAllowed: true)
        let prepare = AIPrepareSheet(profiles: [(1, "迅雷")], selected: 1)
        var closed = 0
        ask.onCancel = { closed += 1 }; schedule.onCancel = { closed += 1 }; prepare.onCancel = { closed += 1 }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for window in [ask.window, schedule.window, prepare.window] {
            let buttons = descendants(window.contentView!).compactMap { $0 as? NSButton }
            #expect(!buttons.contains { $0.title == "取消" })
            let close = try #require(buttons.first { $0.title == "閉じる" })
            #expect(close.keyEquivalent == "\u{1b}")
            close.performClick(nil)
        }
        #expect(closed == 3)
    }
}
