import Testing
@testable import KikigakiCore

/// グローバルキーで画面の記録を切り替えたときの行き先。仕様は docs/screen-capture.md の「グローバルキー」
@Suite struct ScreenHotkeyTests {
    private let ev = ScreenHotkeyChoice.Display(id: 2, name: "EV3895")
    private let builtIn = ScreenHotkeyChoice.Display(id: 1, name: "Built-in Retina Display")
    private let sidecar = ScreenHotkeyChoice.Display(id: 3, name: "Sidecar")

    private func choose(engaged: Bool = false, last: ScreenHotkeyChoice.Display? = nil, sheet: String? = nil,
                        connected: [ScreenHotkeyChoice.Display], main: UInt32? = 1) -> ScreenHotkeyChoice {
        ScreenHotkeyChoice.choose(engaged: engaged, lastCaptured: last, sheetName: sheet, connected: connected, mainID: main)
    }

    @Test func 撮っている間と撮り始めるのを待つ間は止める() {
        #expect(choose(engaged: true, last: ev, connected: [builtIn, ev]) == .stop)
        #expect(choose(engaged: true, connected: []) == .stop)
    }

    @Test func 入れ直す先はこの会議で直前に撮っていたディスプレイ() {
        #expect(choose(last: ev, sheet: "Sidecar", connected: [builtIn, ev, sidecar]) == .start(index: 1))
        // つなぎ直して番号が変わっても、名前が同じなら同じディスプレイとみなす。
        let renumbered = ScreenHotkeyChoice.Display(id: 9, name: "EV3895")
        #expect(choose(last: ev, connected: [builtIn, renumbered]) == .start(index: 1))
        // 番号だけ同じで名前が違うものは、別のディスプレイとみなす。
        let reassigned = ScreenHotkeyChoice.Display(id: 2, name: "Sidecar")
        #expect(choose(last: ev, connected: [builtIn, reassigned]) == .start(index: 0))
    }

    @Test func 撮らずに始めた会議では開始シートで最後に選んだディスプレイ_無ければメイン() {
        #expect(choose(sheet: "Sidecar", connected: [builtIn, ev, sidecar]) == .start(index: 2))
        // 直前に撮っていたディスプレイが外れていても、同じ順で探す。
        #expect(choose(last: ev, sheet: "Sidecar", connected: [builtIn, sidecar]) == .start(index: 1))
        #expect(choose(sheet: "Sidecar", connected: [ev, builtIn]) == .start(index: 1))
        #expect(choose(sheet: "", connected: [ev, builtIn]) == .start(index: 1))
        #expect(choose(connected: [ev, builtIn], main: 2) == .start(index: 0))
        // メインが一覧に無ければ、つながっている最初のディスプレイ。
        #expect(choose(connected: [ev, sidecar], main: 1) == .start(index: 0))
        #expect(choose(connected: [ev, sidecar], main: nil) == .start(index: 0))
        #expect(choose(last: ev, sheet: "EV3895", connected: []) == .noDisplay)
    }
}
