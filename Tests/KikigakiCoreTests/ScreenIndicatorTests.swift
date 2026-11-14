import CoreGraphics
import Testing
@testable import KikigakiCore

/// 撮っている画面の印。バッジを出す間と、切り替えた瞬間の知らせ。仕様は docs/screen-capture.md の「撮っている画面の印」
@Suite struct ScreenIndicatorTests {
    private typealias Indicator = ScreenIndicator<String>

    private func started(_ target: inout ScreenTarget<String>, _ name: String?) {
        if case let .start(_, generation) = target.select(name) { _ = target.started(generation: generation) }
    }

    @Test func 撮り始めた時点でバッジと撮り始めた知らせを出す() {
        var target = ScreenTarget<String>()
        _ = target.select("EV3895")
        let before = Indicator(target: target, paused: false)
        // 選んだだけでは出さない。撮り始めた時点で出す。
        #expect(before == .hidden && before.badge == nil)
        _ = target.started(generation: target.generation)
        let after = Indicator(target: target, paused: false)
        #expect(after.badge == "EV3895")
        #expect(after.notice(from: before) == .started("EV3895"))
        // 同じ状態が続く間は、知らせを出し直さない。
        #expect(after.notice(from: after) == nil)
    }

    @Test func 撮らないで止めた知らせを撮っていた画面に出す() {
        var target = ScreenTarget<String>()
        started(&target, "EV3895")
        let on = Indicator(target: target, paused: false)
        _ = target.select(nil)
        let off = Indicator(target: target, paused: false)
        #expect(off == .hidden && off.notice(from: on) == .stopped("EV3895"))
    }

    @Test func 一時停止で止めた知らせを出し_再開は撮り直した時点で撮り始めた知らせを出す() {
        var target = ScreenTarget<String>()
        started(&target, "EV3895")
        let on = Indicator(target: target, paused: false)
        let paused = Indicator(target: target, paused: true)
        #expect(paused.badge == nil && paused.notice(from: on) == .stopped("EV3895"))
        // 再開してストリームを準備し直している間は、まだ出さない。
        target.resume()
        let restarting = Indicator(target: target, paused: false)
        #expect(restarting == .switching("EV3895") && restarting.badge == nil && restarting.notice(from: paused) == nil)
        _ = target.started(generation: target.generation)
        let resumed = Indicator(target: target, paused: false)
        #expect(resumed.notice(from: restarting) == .started("EV3895"))
    }

    @Test func 対象を替えたら替えた先で撮り始めた知らせだけを出す() {
        var target = ScreenTarget<String>()
        started(&target, "EV3895")
        let first = Indicator(target: target, paused: false)
        _ = target.select("内蔵")
        // 替える途中は何も撮っていないのでバッジを黙って消す。止めた知らせは出さない。
        let switching = Indicator(target: target, paused: false)
        #expect(switching == .switching("EV3895") && switching.badge == nil && switching.notice(from: first) == nil)
        _ = target.started(generation: target.generation)
        let second = Indicator(target: target, paused: false)
        #expect(second.badge == "内蔵" && second.notice(from: switching) == .started("内蔵"))
    }

    @Test func 一時停止中に別の対象を選んで再開したら_替えた先で撮り始めるまで何も出さない() {
        var target = ScreenTarget<String>()
        started(&target, "EV3895")
        let paused = Indicator(target: target, paused: true)
        // 一時停止中に選んだ対象は、再開から撮る。フッターは前の対象のまま。
        _ = target.select("内蔵")
        #expect(Indicator(target: target, paused: true) == .hidden)
        let restarting = Indicator(target: target, paused: false)
        #expect(restarting.badge == nil && restarting.notice(from: paused) == nil)
        _ = target.started(generation: target.generation)
        #expect(Indicator(target: target, paused: false).notice(from: restarting) == .started("内蔵"))
    }

    @Test func 替える途中で元の対象へ戻したら_止めた知らせを出さず撮り直した時点で撮り始めた知らせを出す() {
        var target = ScreenTarget<String>()
        started(&target, "EV3895")
        let first = Indicator(target: target, paused: false)
        _ = target.select("内蔵")
        let toBuiltIn = Indicator(target: target, paused: false)
        _ = target.select("EV3895")
        let back = Indicator(target: target, paused: false)
        #expect(toBuiltIn.notice(from: first) == nil && back.notice(from: toBuiltIn) == nil && back.badge == nil)
        _ = target.started(generation: target.generation)
        #expect(Indicator(target: target, paused: false).notice(from: back) == .started("EV3895"))
    }

    @Test func 替える途中で撮らないにしたら何も出さない() {
        var target = ScreenTarget<String>()
        started(&target, "EV3895")
        _ = target.select("内蔵")
        let switching = Indicator(target: target, paused: false)
        _ = target.select(nil)
        #expect(Indicator(target: target, paused: false).notice(from: switching) == nil)
    }

    @Test func 撮れなかった対象をまた選んで撮れなければ出さず_別の対象で撮れなければ出す() {
        var target = ScreenTarget<String>()
        started(&target, "EV3895")
        _ = target.failed(generation: target.generation)
        let failed = Indicator(target: target, paused: false)
        // 同じ対象を選び直す。撮り直しを待つ間も撮れないまま。
        _ = target.select("EV3895")
        let retry = Indicator(target: target, paused: false)
        #expect(retry == failed && retry.notice(from: failed) == nil)
        _ = target.failed(generation: target.generation)
        #expect(Indicator(target: target, paused: false).notice(from: retry) == nil)
        // 別の対象でも撮れなかった。
        _ = target.select("内蔵")
        let other = Indicator(target: target, paused: false)
        _ = target.failed(generation: target.generation)
        #expect(Indicator(target: target, paused: false).notice(from: other) == .unavailable("内蔵"))
    }

    @Test func 撮れなくなったら撮れない知らせを出してバッジを消す() {
        var target = ScreenTarget<String>()
        started(&target, "EV3895")
        let on = Indicator(target: target, paused: false)
        let accepted = target.failed(generation: target.generation)
        #expect(accepted)
        let failed = Indicator(target: target, paused: false)
        #expect(failed.badge == nil && failed.notice(from: on) == .unavailable("EV3895"))
        // 撮り始める前に撮れなくなったときも同じ知らせを出す。
        var fresh = ScreenTarget<String>()
        _ = fresh.select("EV3895")
        let waiting = Indicator(target: fresh, paused: false)
        _ = fresh.failed(generation: fresh.generation)
        #expect(Indicator(target: fresh, paused: false).notice(from: waiting) == .unavailable("EV3895"))
        // 撮れなくなった後に撮らないへ切っても、何も出さない。
        _ = target.select(nil)
        #expect(Indicator(target: target, paused: false).notice(from: failed) == nil)
    }

    @Test func 会議を止めたら止めた知らせを出す() {
        var target = ScreenTarget<String>()
        started(&target, "EV3895")
        let on = Indicator(target: target, paused: false)
        // 停止後は画面の操作が無い。
        let stopped = Indicator(target: nil, paused: false)
        #expect(stopped.notice(from: on) == .stopped("EV3895"))
    }

    @Test func バッジは右下の隅に_知らせは画面の中央に置く() {
        // 2枚目のディスプレイは原点がずれている。
        let screen = CGRect(x: 1512, y: -200, width: 1800, height: 1169)
        let badge = ScreenIndicatorLayout.badgeFrame(width: 60, in: screen)
        #expect(badge == CGRect(x: 1512 + 1800 - 10 - 60, y: -200 + 10, width: 60, height: 20))
        let notice = ScreenIndicatorLayout.noticeFrame(width: 240, in: screen)
        #expect(notice.midX == screen.midX && notice.height == 64)
        #expect(abs(notice.midY - screen.midY) <= 0.5)
    }
}
