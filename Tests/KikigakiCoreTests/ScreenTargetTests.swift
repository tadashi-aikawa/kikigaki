import Testing
@testable import KikigakiCore

/// 録音中の画面の記録の対象・対象の世代・フッターの表示・イベントの行。仕様は docs/screen-capture.md の「録音中の切り替え」
@Suite struct ScreenTargetTests {
    /// 選んで、その世代の開始を終える。
    @discardableResult
    private func choose(_ target: inout ScreenTarget<String>, _ name: String) -> Bool? {
        guard case let .start(_, generation) = target.select(name) else { return nil }
        return target.started(generation: generation)
    }

    @Test func 撮らずに始めて初めて選ぶと始め直し_始められるまで表示を替えない() {
        var target = ScreenTarget<String>()
        #expect(target.display == .off && target.selected == nil && target.generation == 0)
        #expect(target.select(nil) == .keep)
        #expect(target.select("EV3895") == .start("EV3895", generation: 1))
        #expect(target.display == .off && target.selected == "EV3895")
        #expect(!target.canCaptureNow(recording: true))
        // 撮らずに始めて初めて撮り始めたときは、`記録を再開` を残さない。
        #expect(target.started(generation: 1) == false)
        #expect(target.display == .on("EV3895") && target.canCaptureNow(recording: true))
        #expect(!target.canCaptureNow(recording: false))
        // 撮っている対象・開始を待っている対象を選び直しても何もしない。世代も替えない。
        #expect(target.select("EV3895") == .keep && target.generation == 1)
        // 一時停止からの再開は同じ世代でもう一度知らせる。
        #expect(target.started(generation: 1) == false)
    }

    @Test func 替えただけでは行を出さず_替える途中はいま撮るを出さない() {
        var target = ScreenTarget<String>()
        choose(&target, "EV3895")
        #expect(target.select("内蔵") == .start("内蔵", generation: 2))
        #expect(target.select("内蔵") == .keep)
        #expect(target.display == .on("EV3895") && !target.canCaptureNow(recording: true))
        #expect(target.started(generation: 2) == false)
        #expect(target.display == .on("内蔵") && target.canCaptureNow(recording: true))
    }

    @Test func 替えた後に元の対象へ戻すと_戻した開始を終えるまでいま撮るを出さない() {
        var target = ScreenTarget<String>()
        choose(&target, "EV3895")
        _ = target.select("内蔵")
        #expect(target.select("EV3895") == .start("EV3895", generation: 3))
        // 表示も選んだ対象もEV3895だが、戻した開始はまだ終わっていない。
        #expect(target.display == .on("EV3895") && target.selected == "EV3895")
        #expect(!target.canCaptureNow(recording: true))
        // 間の内蔵の開始が遅れて知らせても取り合わない。
        #expect(target.started(generation: 2) == nil)
        #expect(!target.canCaptureNow(recording: true) && target.display == .on("EV3895"))
        #expect(target.started(generation: 3) == false)
        #expect(target.canCaptureNow(recording: true))
    }

    @Test func 一時停止から再開すると世代を増やさずに開始待ちにする() {
        var target = ScreenTarget<String>()
        choose(&target, "EV3895")
        target.resume()
        #expect(target.generation == 1 && target.display == .on("EV3895"))
        #expect(!target.canCaptureNow(recording: true))
        #expect(target.started(generation: 1) == false)
        #expect(target.canCaptureNow(recording: true))
        // 撮らない・撮れなくなった後は開始を待たない。
        _ = target.select(nil)
        target.resume()
        #expect(target.select(nil) == .keep)
    }

    @Test func 撮っている対象を切ると記録を停止_入れ直すと記録を再開() {
        var target = ScreenTarget<String>()
        choose(&target, "EV3895")
        #expect(target.select(nil) == .stop(recordStopped: true, generation: 2))
        #expect(target.display == .off && target.selected == nil)
        #expect(target.select(nil) == .keep)
        #expect(choose(&target, "内蔵") == true)
        // 再開を残すのは切った後の最初の1回だけ。
        #expect(choose(&target, "EV3895") == false)
    }

    @Test func 始める途中で切ると何も撮っていないので記録を停止を出さない() {
        var target = ScreenTarget<String>()
        _ = target.select("EV3895")
        #expect(target.select(nil) == .stop(recordStopped: false, generation: 2))
        // 切った後に届いた、切る前の開始の知らせは取り合わない。
        #expect(target.started(generation: 1) == nil && target.display == .off)
        #expect(choose(&target, "EV3895") == false)
    }

    @Test func 撮っている間に替えた先を始める途中で切ると記録を停止を出す() {
        // フッターは前の対象を出したままで、利用者から見れば撮っている記録を切った。
        var target = ScreenTarget<String>()
        choose(&target, "EV3895")
        _ = target.select("内蔵")
        #expect(target.select(nil) == .stop(recordStopped: true, generation: 3))
    }

    @Test func 撮れなくなった対象を選び直すと撮り直し_始められたら記録を再開() {
        var target = ScreenTarget<String>()
        _ = target.select("EV3895")
        let failed = target.failed(generation: 1)
        #expect(failed)
        #expect(target.display == .failed("EV3895") && target.isFailed && !target.canCaptureNow(recording: true))
        #expect(target.select("EV3895") == .start("EV3895", generation: 2))
        #expect(target.display == .failed("EV3895"))
        #expect(target.started(generation: 2) == true && target.display == .on("EV3895"))
    }

    @Test func 替える前の対象の取得不能の知らせは_替えた先を取得不能にしない() {
        var target = ScreenTarget<String>()
        choose(&target, "EV3895")
        _ = target.select("内蔵")
        let stale = target.failed(generation: 1)
        #expect(!stale)
        #expect(target.display == .on("EV3895") && !target.isFailed)
        #expect(target.started(generation: 2) == false)
        #expect(target.display == .on("内蔵") && target.canCaptureNow(recording: true))
        // 「撮らない」の後に届いた知らせも同じ。
        _ = target.select(nil)
        let afterCut = target.failed(generation: 2)
        #expect(!afterCut && target.display == .off)
    }

    @Test func 撮れなくなった後に撮らないを選んでも記録を停止を出さない() {
        // 撮れなくなった時点で `記録できません` の行が切れ目を示している。
        var target = ScreenTarget<String>()
        choose(&target, "EV3895")
        let failed = target.failed(generation: 1)
        #expect(failed)
        #expect(target.select(nil) == .stop(recordStopped: false, generation: 2))
        #expect(target.display == .off)
        #expect(choose(&target, "EV3895") == true)
    }

    @Test func 最後に撮り始めた対象は撮らないや撮れなくなった後も残し_グローバルキーの向きを決める() {
        var target = ScreenTarget<String>()
        #expect(target.lastCaptured == nil && !target.isEngaged)
        // 選んだだけでは撮っていない。始めるのを待つ間は止める向き。
        _ = target.select("EV3895")
        #expect(target.lastCaptured == nil && target.isEngaged)
        #expect(target.started(generation: 1) == false)
        #expect(target.lastCaptured == "EV3895")
        _ = target.select(nil)
        #expect(target.lastCaptured == "EV3895" && !target.isEngaged)
        choose(&target, "内蔵")
        let failed = target.failed(generation: 3)
        #expect(failed)
        // 撮れなくなった後は入れ直す向き。
        #expect(target.lastCaptured == "内蔵" && !target.isEngaged)
        // 選び直して開始を待つ間は、表示が撮れないままでも止める向き。
        #expect(target.select("内蔵") == .start("内蔵", generation: 4))
        #expect(target.isFailed && target.isEngaged)
        #expect(target.select(nil) == .stop(recordStopped: false, generation: 5))
        #expect(!target.isEngaged)
    }
}
