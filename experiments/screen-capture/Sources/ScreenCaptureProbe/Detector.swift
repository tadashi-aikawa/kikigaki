import Foundation

/// 縮小した輝度画像。値は0〜255。行は上から順に並ぶ。
struct Thumb: Equatable {
    let width: Int
    let height: Int
    var luma: [UInt8]
}

/// 撮る契機の判定に使う値。設計案の「撮る契機」の2つの判定を、比べる相手を分けて持つ。
struct DetectorParams: CustomStringConvertible, Hashable {
    // 既定値は検証記録の初期値。`watch` をそのまま実行したときも記録と同じ判定で見る。
    /// 比べる縮小画像の幅。高さは画面の縦横比から決める。
    var thumbWidth = 128
    /// 1マスの輝度差がこれを超えたら、そのマスは変わったとみなす。
    var cellDelta = 8
    /// 落ち着きの判定: 直前の観測フレームと比べて変わったマスの割合がこれを超えたら「動いている」。
    var motion = 0.0002
    /// 保存する価値の判定: 最後に保存した画像と比べて変わったマスの割合がこれを超えたら保存する。
    var save = 0.001
    /// 動いていない状態がこの秒数続いたら「落ち着いた」。
    var settle = 1.5
    /// 上端から比較に使わない行の高さ。画面の高さに対する割合。メニューバーの時計を外す。
    var excludeTopFraction = 0.0
    /// 直近この秒数のうちに volatileCount 回以上変わったマスを、両方の比較から外す。0なら外さない。
    /// 外したマスは、変わらない状態が volatileRelease 秒続くまで外し続ける。
    /// 理由: 回数だけで決めると、時計の桁のように変わり方が揺れるマスが外れたり戻ったりし、戻るたびに保存が起きる。
    /// 初期値では外さない。外すと、大きな画面に小さな文字のページを続けて送ったとき、ページの中身が外れて取りこぼした。
    var volatileSeconds = 0.0
    var volatileCount = 3
    var volatileRelease = 10.0
    /// 直前との差がこの割合を超えたフレームは、外すマスの回数に数えない。
    /// 理由: ページ送りやスクロールを数えると、続けて送っただけで画面全体が比較から外れ、最後に見ていたページを保存しない。
    /// 外すのはカーソル・時計・回る印のような小さく動き続ける所だけにする。
    var volatileFrameLimit = 0.05

    var description: String {
        var parts = ["w=\(thumbWidth)", "cell=\(cellDelta)", "motion=\(motion)", "save=\(save)", "settle=\(settle)"]
        if excludeTopFraction > 0 { parts.append(String(format: "top=%.3f", excludeTopFraction)) }
        if volatileSeconds > 0 { parts.append("volatile=\(volatileCount)/\(volatileSeconds)s+\(volatileRelease)s<=\(volatileFrameLimit)") }
        return parts.joined(separator: " ")
    }
}

struct SaveDecision {
    enum Reason: String { case first, settled }
    /// 保存する画像が観測された時刻。保存を決めた時刻ではない。
    let frameTime: Double
    let frameIndex: Int
    let reason: Reason
    let diffSaved: Double
    let decidedAt: Double
}

struct FrameStats {
    let diffPrev: Double
    let moving: Bool
    let volatileCells: Int
}

/// 画面が意味のある変化をして落ち着いたときに保存を決める。時刻は単調な秒。
/// - 落ち着き: 直前の観測フレームとの差がしきい値を超えない状態が `settle` 秒続く
/// - 保存する価値: 落ち着いている間の最新フレームが、最後に保存した画像と十分に違う
/// - `idle` の間はフレームが来ないので、`tick` で時間だけ進める
final class ChangeDetector {
    let params: DetectorParams
    private var latest: (index: Int, time: Double, thumb: Thumb)?
    private var saved: Thumb?
    private var lastMotion = -Double.infinity
    private var changeTimes: [[Double]] = []
    private var volatileUntil: [Double] = []
    private var excludedRows = 0

    init(params: DetectorParams) { self.params = params }

    /// 撮れない期間に入った。古いフレームを後から「落ち着いた」として保存しない。
    /// 次に届くフレームは最初のフレームと同じく待たずに保存する。
    func reset() {
        latest = nil; saved = nil; lastMotion = -Double.infinity
        changeTimes = []; volatileUntil = []
    }

    func frame(index: Int, time: Double, thumb: Thumb) -> (FrameStats, SaveDecision?) {
        guard let previous = latest else {
            excludedRows = min(thumb.height, Int((params.excludeTopFraction * Double(thumb.height)).rounded(.up)))
            changeTimes = Array(repeating: [], count: thumb.width * thumb.height)
            latest = (index, time, thumb)
            saved = thumb
            return (FrameStats(diffPrev: 0, moving: false, volatileCells: 0),
                    SaveDecision(frameTime: time, frameIndex: index, reason: .first, diffSaved: 1, decidedAt: time))
        }
        precondition(previous.thumb.width == thumb.width && previous.thumb.height == thumb.height, "縮小画像の寸法が途中で変わった")
        if params.volatileSeconds > 0, fraction(previous.thumb, thumb, volatile: []) <= params.volatileFrameLimit {
            if volatileUntil.isEmpty { volatileUntil = Array(repeating: -Double.infinity, count: changeTimes.count) }
            let from = time - params.volatileSeconds
            for cell in considered(thumb) where Self.changed(previous.thumb.luma[cell], thumb.luma[cell], params.cellDelta) {
                changeTimes[cell].removeAll { $0 < from }
                changeTimes[cell].append(time)
                if changeTimes[cell].count >= params.volatileCount || volatileUntil[cell] > time {
                    volatileUntil[cell] = time + params.volatileRelease
                }
            }
        }
        let volatile = volatileMask(now: time)
        let diffPrev = fraction(previous.thumb, thumb, volatile: volatile)
        let moving = diffPrev > params.motion
        if moving { lastMotion = time }
        latest = (index, time, thumb)
        let stats = FrameStats(diffPrev: diffPrev, moving: moving, volatileCells: volatile.reduce(0) { $0 + ($1 ? 1 : 0) })
        return (stats, evaluate(now: time, volatile: volatile))
    }

    func tick(now: Double) -> SaveDecision? {
        guard latest != nil else { return nil }
        return evaluate(now: now, volatile: volatileMask(now: now))
    }

    private func evaluate(now: Double, volatile: [Bool]) -> SaveDecision? {
        guard let latest, let saved, now - lastMotion >= params.settle else { return nil }
        let diffSaved = fraction(saved, latest.thumb, volatile: volatile)
        guard diffSaved > params.save else { return nil }
        self.saved = latest.thumb
        return SaveDecision(frameTime: latest.time, frameIndex: latest.index, reason: .settled, diffSaved: diffSaved, decidedAt: now)
    }

    private func considered(_ thumb: Thumb) -> Range<Int> { (excludedRows * thumb.width)..<(thumb.width * thumb.height) }

    private func volatileMask(now: Double) -> [Bool] {
        guard params.volatileSeconds > 0, !volatileUntil.isEmpty else { return [] }
        return volatileUntil.map { $0 > now }
    }

    /// 比較に使うマスのうち、変わったマスの割合。外したマスも分母に残し、外すほど小さくなる。
    private func fraction(_ a: Thumb, _ b: Thumb, volatile: [Bool]) -> Double {
        let range = considered(b)
        guard !range.isEmpty else { return 0 }
        var count = 0
        for cell in range where (volatile.isEmpty || !volatile[cell]) && Self.changed(a.luma[cell], b.luma[cell], params.cellDelta) {
            count += 1
        }
        return Double(count) / Double(range.count)
    }

    private static func changed(_ a: UInt8, _ b: UInt8, _ delta: Int) -> Bool { abs(Int(a) - Int(b)) > delta }
}
