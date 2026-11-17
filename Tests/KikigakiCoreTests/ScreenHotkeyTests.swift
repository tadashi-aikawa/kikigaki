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

/// グローバルキーの「いま撮る」で撮れない理由。仕様は docs/screen-capture.md の「グローバルキー」
@Suite struct ScreenCaptureNowRefusalTests {
    private func check(recording: Bool = true, screenCapture: Bool = true, _ target: ScreenTarget<String>,
                       ready: Bool = true) -> ScreenCaptureNowRefusal? {
        ScreenCaptureNowRefusal.check(recording: recording, screenCapture: screenCapture, target: target, ready: ready)
    }

    /// EV3895を選んで撮り始めた状態。
    private func capturing() -> ScreenTarget<String> {
        var target = ScreenTarget<String>()
        guard case let .start(_, generation) = target.select("EV3895") else { Issue.record(); return target }
        _ = target.started(generation: generation)
        return target
    }

    @Test func フッターのメニューに_いま撮る_が出ている場面だけ撮る() {
        #expect(check(capturing()) == nil)
        // 撮影側に撮影に要るものが揃っていなければ、撮り始めるのを待つ間と同じに断る。
        #expect(check(capturing(), ready: false) == .starting)
    }

    @Test func 録音中でなければ_画面を撮らない会議より先に録音中だけと断る() {
        #expect(check(recording: false, capturing()) == .notRecording)
        #expect(check(recording: false, screenCapture: false, ScreenTarget<String>()) == .notRecording)
        #expect(check(screenCapture: false, ScreenTarget<String>()) == .noScreenCapture)
    }

    @Test func 撮らない_撮れなくなった後_撮り始めるのを待つ間は理由を分けて断る() {
        #expect(check(ScreenTarget<String>()) == .off)
        var stopped = capturing()
        _ = stopped.select(nil)
        #expect(check(stopped) == .off)

        var failed = capturing()
        _ = failed.failed(generation: failed.generation)
        #expect(check(failed) == .unavailable)
        // 撮れなくなった後に選び直し、始められるのを待つ間は待つ間として断る。
        _ = failed.select("EV3895")
        #expect(check(failed) == .starting)

        var switching = capturing()
        _ = switching.select("Built-in Retina Display")
        #expect(check(switching) == .starting)
        var resumed = capturing()
        resumed.resume()
        #expect(check(resumed) == .starting)
    }

    @Test func 断る文言() {
        #expect(ScreenCaptureNowRefusal.notRecording.reason == "録音中だけ撮れます")
        #expect(ScreenCaptureNowRefusal.noScreenCapture.reason == "この会議では画面を記録しません")
        #expect(ScreenCaptureNowRefusal.off.reason == "画面の記録を停止しています")
        #expect(ScreenCaptureNowRefusal.unavailable.reason == "画面を記録できていません")
        #expect(ScreenCaptureNowRefusal.starting.reason == "画面の記録を始めるのを待っています")
    }
}
