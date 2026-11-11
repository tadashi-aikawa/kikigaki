import Foundation
import Testing
@testable import KikigakiCore

/// 動き続ける画面と、直近に公開した画面と比べる規則。既定値で確かめる。
/// 仕様は docs/screen-capture.md の「撮る契機の判定」
///
/// 画面は40×24マスの縮小画像で描く。観測は1秒ごと、判定は0.25秒ごと。
/// - 題: スライドごとに違う模様
/// - 図: 左に置き、絵ごとに違う模様
/// - 動く画像: 右下に置き、毎秒すべてのマスが変わる。図の枠とは5マス離す
@Suite struct ScreenChangeMotionTests {
    static let width = 40, height = 24

    /// 1つの観測の画面。
    struct Screen {
        var slide: Int
        var panel: Int? = nil
        var animated = false
        var video = false
        /// 描き込んだポインタ。題の下を1マスずつ動く。
        var pointer = false
    }

    static func draw(_ screen: Screen, frame: Int) -> ScreenThumbnail {
        var luma = [UInt8](repeating: 230, count: width * height)
        for y in 0..<height { for x in 0..<width {
            let cell = y * width + x
            if screen.video { luma[cell] = UInt8(20 + (frame * 41 + x * 13 + y * 7) % 200); continue }
            if (2...5).contains(y), (2...30).contains(x) { luma[cell] = UInt8(50 + (screen.slide * 37 + x * 7 + y * 3) % 100) }
            if let panel = screen.panel, (10...21).contains(y), (2...20).contains(x) { luma[cell] = UInt8(30 + (panel * 53 + x * 11 + y * 5) % 150) }
            if screen.animated, (12...21).contains(y), (26...37).contains(x) { luma[cell] = UInt8(20 + (frame * 41 + x * 13 + y * 7) % 200) }
        } }
        if screen.pointer { luma[8 * width + 2 + frame % 30] = 0 }
        return ScreenThumbnail(width: width, height: height, luma: luma)
    }

    struct Saved: Equatable { var frame: Int; var reason: ScreenChangeDetector.Decision.Reason; var order: Int }

    /// 0秒から `until` 秒まで1秒ごとに観測し、0.25秒ごとに判定する。決めたら受け付けて `result` で結果を返す。
    /// - result: 保存の結果。既定はその場で公開した成功
    static func run(until: Double, detector: inout ScreenChangeDetector, scene: (Double) -> Screen,
                    result: (inout ScreenChangeDetector, Saved, Double) -> Void = { detector, saved, time in
                        detector.saveSucceeded(frame: saved.frame, at: time)
                    }) -> [Saved] {
        var saves: [Saved] = []
        func settle(_ decision: ScreenChangeDetector.Decision?, at time: Double) {
            guard let decision else { return }
            let saved = Saved(frame: decision.frame, reason: decision.reason, order: saves.count)
            detector.accepted(frame: decision.frame, order: saved.order)
            saves.append(saved)
            result(&detector, saved, time)
        }
        var tick = 0.25
        for second in 0...Int(until) {
            let time = Double(second)
            while tick < time { settle(detector.tick(at: tick), at: tick); tick += 0.25 }
            settle(detector.observe(frame: second, at: time, thumbnail: draw(scene(time), frame: second)), at: time)
        }
        return saves
    }

    /// 観測の時刻が区間にある保存の数。
    static func count(_ saves: [Saved], _ range: Range<Double>) -> Int { saves.filter { range.contains(Double($0.frame)) }.count }

    @Test func 動く画像のスライドでは1枚だけ撮る() {
        var detector = ScreenChangeDetector()
        let saves = Self.run(until: 60, detector: &detector) { t in t < 10 ? Screen(slide: 1) : Screen(slide: 2, animated: true) }
        #expect(Self.count(saves, 10..<61) == 1)
        #expect(saves.last?.reason == .moving)
        // 外したのは動く画像の枠だけで、題は比べ続ける。
        #expect(detector.excludedCellCount > 0 && detector.excludedCellCount < 200)
    }

    @Test func 交互に変わる2枚は1枚ずつだけ撮る() {
        var detector = ScreenChangeDetector()
        let saves = Self.run(until: 70, detector: &detector) { t in
            t < 10 ? Screen(slide: 1) : Screen(slide: 2, panel: Int((t - 10) / 3) % 2)
        }
        #expect(Self.count(saves, 10..<71) == 2)
    }

    @Test(arguments: [0.0, 1.0])
    func 動く画像と交互の並ぶスライドでは1から2枚(lead: Double) {
        // 送る lead 秒前から、描き込んだポインタで画面が動き始める。
        var detector = ScreenChangeDetector()
        let send = 10 + lead
        let saves = Self.run(until: 70, detector: &detector) { t in
            if t < 10 { return Screen(slide: 1) }
            if t < send { return Screen(slide: 1, pointer: true) }
            return Screen(slide: 2, panel: Int((t - send) / 3.5) % 2, animated: true)
        }
        #expect((1...2).contains(Self.count(saves, send..<71)))
    }

    @Test func 直前に見た画面へ短く戻ったら撮らない() {
        var detector = ScreenChangeDetector()
        let saves = Self.run(until: 40, detector: &detector) { t in
            t < 10 ? Screen(slide: 1) : t < 20 ? Screen(slide: 2) : t < 25 ? Screen(slide: 3) : Screen(slide: 2)
        }
        #expect(Self.count(saves, 20..<25) == 1)
        #expect(Self.count(saves, 25..<41) == 0)
    }

    @Test func 最後に見てから12秒より後に戻ったら撮る() {
        var detector = ScreenChangeDetector()
        let saves = Self.run(until: 60, detector: &detector) { t in
            t < 10 ? Screen(slide: 1) : t < 20 ? Screen(slide: 2) : t < 40 ? Screen(slide: 3) : Screen(slide: 2)
        }
        #expect(Self.count(saves, 40..<61) == 1)
    }

    @Test func 全画面の動画は最初の1枚だけ撮り_動画を挟んで戻った画面を撮る() {
        var detector = ScreenChangeDetector()
        let saves = Self.run(until: 90, detector: &detector) { t in
            t < 10 || t >= 70 ? Screen(slide: 1) : Screen(slide: 0, video: true)
        }
        #expect(Self.count(saves, 10..<70) == 1)
        #expect(Self.count(saves, 70..<91) == 1)
    }

    /// 全画面の動画では外すマスが画面の全体になる。直近の画面との比較で除くと、動画の各フレームが前の画面と同じとみなされる。
    /// 既定の12秒では、強制で撮るのが動き始めの12秒後なので、前の画面は範囲を出ていて差が出ない。範囲を延ばして確かめる。
    @Test(arguments: [(0.5, 1), (1.0, 0)])
    func 外すマスが半分を超えたら直近の画面との比較で除かない(limit: Double, expected: Int) {
        var parameters = ScreenChangeParameters()
        parameters.recentSeconds = 20; parameters.recentExcludeLimit = limit
        var detector = ScreenChangeDetector(parameters: parameters)
        let saves = Self.run(until: 90, detector: &detector) { t in
            t < 10 || t >= 70 ? Screen(slide: 1) : Screen(slide: 0, video: true)
        }
        #expect(Self.count(saves, 70..<91) == expected)
    }

    @Test func 動き続けて撮った1枚の保存に失敗したら外すマスを確定せず_間隔をおいて撮り直す() {
        var detector = ScreenChangeDetector()
        var failed = false
        let saves = Self.run(until: 40, detector: &detector, scene: { t in t < 10 ? Screen(slide: 1) : Screen(slide: 2, animated: true) },
                             result: { detector, saved, time in
            if saved.reason == .moving, !failed {
                failed = true
                detector.saveFailed(frame: saved.frame, at: time)
                #expect(detector.excludedCellCount == 0)
            } else {
                detector.saveSucceeded(frame: saved.frame, at: time)
            }
        })
        let moving = saves.filter { $0.reason == .moving }
        #expect(moving.count == 2)
        // 失敗から再試行の間隔5秒の後に、待たずに撮り直す。
        if moving.count == 2 { #expect(moving[1].frame - moving[0].frame == 5) }
        #expect(detector.excludedCellCount > 0)
    }

    @Test func 一時停止の前に決めた動き続けた1枚が再開の後に成功しても外すマスを確定しない() {
        var detector = ScreenChangeDetector()
        var pending: Saved?
        _ = Self.run(until: 30, detector: &detector, scene: { t in t < 10 ? Screen(slide: 1) : Screen(slide: 2, animated: true) },
                     result: { detector, saved, time in
            if saved.reason == .moving { pending = saved } else { detector.saveSucceeded(frame: saved.frame, at: time) }
        })
        guard let pending else { Issue.record("動き続けた1枚を決めていない"); return }
        detector.restart()
        detector.saveSucceeded(frame: pending.frame, at: 40)
        #expect(detector.excludedCellCount == 0)
    }

    /// 動き続けて撮る1枚を22秒に決め、成功は23秒に届く。その間の22.9秒に、外す候補の動く画像が変わり、その後は止まる。
    /// 外すマスを戻すのは、最後の変化の22.9秒から3秒たった25.9秒。決めた時刻の22秒から数えると25秒で戻してしまう。
    @Test func 保存を待つ間に変わった外す候補は_その変化から3秒たつまで戻さない() {
        var detector = ScreenChangeDetector()
        var pending: Saved?
        _ = Self.run(until: 22, detector: &detector, scene: { t in t < 10 ? Screen(slide: 1) : Screen(slide: 2, animated: true) },
                     result: { detector, saved, time in
            if saved.reason == .moving { pending = saved } else { detector.saveSucceeded(frame: saved.frame, at: time) }
        })
        guard let pending, pending.frame == 22 else { Issue.record("22秒に動き続けた1枚を決めていない: \(String(describing: pending))"); return }
        _ = detector.observe(frame: 23, at: 22.9, thumbnail: Self.draw(Screen(slide: 2, animated: true), frame: 23))
        detector.saveSucceeded(frame: pending.frame)
        #expect(detector.excludedCellCount > 0)
        _ = detector.tick(at: 25.25)
        #expect(detector.excludedCellCount > 0, "最後の変化から3秒たつ前に戻した")
        _ = detector.tick(at: 26)
        #expect(detector.excludedCellCount == 0)
    }

    /// 無音の間に保留した画像は、公開を知らせるまで直近の画面として比べない。捨てたら抜く。
    @Test(arguments: [false, true])
    func 保留したまま捨てた画像は直近の画面に入らず_その画面へ戻れば撮る(publishHeld: Bool) {
        // S(0〜10) → A(10〜13) → B(13〜16) → A(16〜30)。Aは保留し、BでAを置き換えて捨てる。
        var detector = ScreenChangeDetector()
        let saves = Self.run(until: 30, detector: &detector, scene: { t in
            t < 10 ? Screen(slide: 1) : t < 13 ? Screen(slide: 2) : t < 16 ? Screen(slide: 3) : Screen(slide: 2)
        }, result: { detector, saved, time in
            let held = (10..<13).contains(Double(saved.frame))
            detector.saveSucceeded(frame: saved.frame, at: time, outcome: held ? .held : .published)
            if (13..<16).contains(Double(saved.frame)) {
                // Bを受け取った時点で、保留していたAの行き先が決まる。
                if publishHeld { detector.published(order: saved.order - 1) } else { detector.discarded(order: saved.order - 1) }
            }
        })
        #expect(Self.count(saves, 10..<13) == 1 && Self.count(saves, 13..<16) == 1)
        // 捨てたAへ戻ったら撮る。公開したAなら12秒以内なので撮らない。
        #expect(Self.count(saves, 16..<31) == (publishHeld ? 0 : 1))
    }

    @Test func いま撮るで公開した画面も直近の画面として比べる() {
        var detector = ScreenChangeDetector()
        let a = Self.draw(Screen(slide: 2), frame: 0)
        // S(0〜10)の後、Aを観測した直後に「いま撮る」でAを公開した。B(11〜14)を経てAへ戻る。
        var saves = Self.run(until: 10, detector: &detector) { _ in Screen(slide: 1) }
        _ = detector.observe(frame: 100, at: 10.5, thumbnail: a, acceptedBefore: saves.count)
        detector.adopt(order: saves.count, thumbnail: a, at: 10.5)
        var orders = saves.count + 1
        for second in 11...30 {
            let screen = second < 14 ? Screen(slide: 3) : Screen(slide: 2)
            for tick in 1...3 {
                if let decision = detector.tick(at: Double(second) - 1 + Double(tick) * 0.25) {
                    detector.accepted(frame: decision.frame, order: orders); orders += 1
                    detector.saveSucceeded(frame: decision.frame, at: Double(second))
                    saves.append(Saved(frame: decision.frame, reason: decision.reason, order: orders))
                }
            }
            if let decision = detector.observe(frame: 100 + second, at: Double(second), thumbnail: Self.draw(screen, frame: second), acceptedBefore: orders) {
                detector.accepted(frame: decision.frame, order: orders); orders += 1
                detector.saveSucceeded(frame: decision.frame, at: Double(second))
                saves.append(Saved(frame: decision.frame, reason: decision.reason, order: orders))
            }
        }
        // Bは撮り、手動で公開したAへ3秒で戻っても撮らない。
        #expect(saves.filter { (111..<114).contains($0.frame) }.count == 1)
        #expect(saves.filter { (114...130).contains($0.frame) }.isEmpty)
    }
}
