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

    // 案P 直近に保存した画面と比べる(2026-11-11の試作)。保存しようとした画面が、直近に保存した画面のどれかと同じなら保存しない。
    // 比べる相手は保存に成功した画像だけ。比べるときは案Qの外すマスを掛けない。
    /// 比べる枚数。最後に見た時刻の新しい順に数え、最後に保存した1枚も含む。1なら今までと同じ。0なら枚数で絞らない。
    var recentCount = 1
    /// 最後に見てからこの秒数以内の画像だけと比べる。0なら秒で絞らない。
    var recentSeconds = 0.0
    /// 比べる範囲にある画像と同じ画面を見ている間、その画像の「最後に見た時刻」を延ばす。
    /// 延ばさないなら、最後に見た時刻は保存した時刻のまま。
    var recentExtend = true
    /// 直近の画像と「同じ」とみなす差。変わったマスの割合で、0なら保存する価値のしきい値と同じ。
    /// マスの判定は `cellDelta` を使う。0.000001 は「全マスの輝度の差が cellDelta 以下」で、厳密な一致ではない。
    var recentSame = 0.0
    /// 縮小画像の輝度が全マスで一致するときだけ同じとみなす。比べる値の確認用で、推す初期値ではない。
    var recentExact = false
    var recentSameThreshold: Double { recentSame > 0 ? recentSame : save }

    // 案Q・案R 動き続けたら撮る(2026-11-11の試作)。
    /// 動いている状態がこの秒数続いたら、その時点の1枚を保存する。動き続ける間は、この秒数ごとに次を試す。0なら撮らない。
    var movingSeconds = 0.0
    /// 案Q: 動き続けて撮った1枚の保存に成功したら、直近この秒数に `maskCount` 回以上変わったマスを両方の比較から外す。0なら外さない(案R)。
    var maskWindow = 0.0
    var maskCount = 2
    /// 外したマスは、変わらない状態がこの秒数続いたら戻す。
    var maskRelease = 4.0
    /// 外すマスを上下左右にこのマス数だけ広げる。
    var maskGrow = 0
    /// 外すマスのつながりごとに、外接する長方形まで埋める。動く画像は長方形なので、玉が跳ねるだけの絵でも枠ごと外せる。
    var maskBox = false
    /// 直前との差がこの割合を超えたフレームでの1度だけの変化を、外す候補に数えない。0なら数える。
    /// 理由: 動いている間にスライドやウィンドウを切り替えると、切替で1度だけ変わった中身まで外れ、次の画面を隠し続ける(2026-11-11のレビュー 高1)。
    /// 2回以上変わったマスは、フレームの差によらず候補にする。動画は毎フレーム広く変わるが、同じマスが何度も変わる。
    var maskBroad = 0.0
    /// 外したマスを、つながりごとに戻す。false なら、外したマスのどれかが動く限り全体を保つ(2026-11-11の最初の形)。
    var maskRegional = false
    /// 外したマスでも、動いている間に見なかった明るさで落ち着いたマスは、基準との比較に戻す。
    /// 理由: 動く画像の枠の中にだけ新しい中身が出ると、枠が動く限り撮れない(2026-11-11のレビュー 高1)。
    /// 動く画像が元から出す明るさの範囲は、外すマスを決めた時点の直近 maskWindow 秒の観測から取る。
    var maskNovel = false
    /// 保存に失敗してから、次の保存を決めるまでの秒数。本体と同じ5秒。
    var retryInterval = 5.0

    var recentEnabled: Bool { recentCount != 1 || recentSeconds > 0 }

    var description: String {
        var parts = ["w=\(thumbWidth)", "cell=\(cellDelta)", "motion=\(motion)", "save=\(save)", "settle=\(settle)"]
        if excludeTopFraction > 0 { parts.append(String(format: "top=%.3f", excludeTopFraction)) }
        if volatileSeconds > 0 { parts.append("volatile=\(volatileCount)/\(volatileSeconds)s+\(volatileRelease)s<=\(volatileFrameLimit)") }
        if recentEnabled {
            parts.append("P[K=\(recentCount == 0 ? "∞" : String(recentCount)) T=\(recentSeconds == 0 ? "∞" : String(format: "%g", recentSeconds))\(recentExtend ? " 延長" : "")"
                         + (recentExact ? " 輝度が完全に一致" : recentSame > 0 ? String(format: " 同じ<=%g", recentSame) : "") + "]")
        }
        if movingSeconds > 0 {
            if maskWindow > 0 {
                var options = ""
                if maskBox { options += " 長方形" }
                if maskBroad > 0 { options += String(format: " 広い差>%g除く", maskBroad) }
                if maskRegional { options += " 領域ごと" }
                if maskNovel { options += " 見なかった明るさは比べる" }
                parts.append(String(format: "Q[N=%g 外す=%d/%gs 戻す=%gs 広げる=%d", movingSeconds, maskCount, maskWindow, maskRelease, maskGrow) + options + "]")
            } else {
                parts.append(String(format: "R[M=%g]", movingSeconds))
            }
        }
        return parts.joined(separator: " ")
    }
}

struct SaveDecision {
    enum Reason: String { case first, settled, moving }
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
///
/// 保存の結果は `saveSucceeded` / `saveFailed` で返す。本体の `ScreenChangeDetector` と同じく、基準・案Pの履歴・案Qの外すマスは成功で確定する。
/// `autoConfirm` が true(既定)なら、決めた時点で成功したとみなす。`watch` と自己点検の既存の確認はこの形で動く。
final class ChangeDetector {
    let params: DetectorParams
    var autoConfirm = true
    private var latest: (index: Int, time: Double, thumb: Thumb)?
    private var saved: Thumb?
    private var lastMotion = -Double.infinity
    private var changeTimes: [[Double]] = []
    private var volatileUntil: [Double] = []
    private var excludedRows = 0
    private var retryNotBefore = -Double.infinity
    /// 結果を待っている決定。案Qの決定は、成功で確定する外すマスの候補を持つ。
    private var pending: [(index: Int, thumb: Thumb, reason: SaveDecision.Reason, mask: [Bool]?)] = []
    /// 最新の観測を保存し終えた。新しい観測で戻す。
    private var latestDone = false
    // 案P: 保存した画像と最後に見た時刻。id は最新の観測と同じ画面かを覚えるための番号。
    private var history: [(id: Int, thumb: Thumb, lastSeen: Double)] = []
    private var nextHistoryID = 0
    /// 最新の観測と同じ画面の履歴の id。外すマスを掛けずに観測ごとに求める。
    private var latestMatches: Set<Int> = []
    // 案Q・案R
    /// 落ち着いた状態から動き始めた時刻。動き続けて撮るたびに、その時刻へ進める。
    private var motionSince = -Double.infinity
    /// 案Q: 直近 maskWindow 秒の観測ごとの、変わったマスと直前との差の割合。
    private var moveFrames: [(time: Double, fraction: Double, cells: [Int32])] = []
    /// 案Q: 外しているマスの領域の番号。-1は外していない。
    private var maskRegion: [Int] = []
    /// 案Q: 領域ごとの、最後に変わった時刻。領域ごとに戻さないときは1つだけ持つ。
    private var regionLastChange: [Double] = []
    /// 案Q(maskNovel): 直近 maskWindow 秒の観測、マスごとの最後に変わった時刻、外したマスが動く間に見た明るさの範囲。
    private var recentThumbs: [(time: Double, thumb: Thumb)] = []
    private var cellLastChange: [Double] = []
    private var rangeLow: [UInt8] = []
    private var rangeHigh: [UInt8] = []

    init(params: DetectorParams) { self.params = params }

    /// 撮れない期間に入った。古いフレームを後から「落ち着いた」として保存しない。
    /// 次に届くフレームは最初のフレームと同じく待たずに保存する。結果を待っている決定は、後から返っても無視する。
    func reset() {
        latest = nil; saved = nil; lastMotion = -Double.infinity
        changeTimes = []; volatileUntil = []
        retryNotBefore = -Double.infinity; pending = []; latestDone = false
        history = []; latestMatches = []
        motionSince = -Double.infinity; moveFrames = []; maskRegion = []; regionLastChange = []
        recentThumbs = []; cellLastChange = []; rangeLow = []; rangeHigh = []
    }

    func frame(index: Int, time: Double, thumb: Thumb) -> (FrameStats, SaveDecision?) {
        guard let previous = latest else {
            excludedRows = min(thumb.height, Int((params.excludeTopFraction * Double(thumb.height)).rounded(.up)))
            changeTimes = Array(repeating: [], count: thumb.width * thumb.height)
            cellLastChange = Array(repeating: time, count: thumb.width * thumb.height)
            latest = (index, time, thumb)
            latestDone = false
            let decision = SaveDecision(frameTime: time, frameIndex: index, reason: .first, diffSaved: 1, decidedAt: time)
            pending.append((index, thumb, .first, nil))
            if autoConfirm { saveSucceeded(frameIndex: index, at: time) }
            return (FrameStats(diffPrev: 0, moving: false, volatileCells: 0), decision)
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
        if params.movingSeconds > 0, params.maskWindow > 0 {
            var cells: [Int32] = []
            for cell in considered(thumb) where Self.changed(previous.thumb.luma[cell], thumb.luma[cell], params.cellDelta) {
                cells.append(Int32(cell))
                cellLastChange[cell] = time
                if !maskRegion.isEmpty, maskRegion[cell] >= 0 {
                    regionLastChange[params.maskRegional ? maskRegion[cell] : 0] = time
                }
            }
            moveFrames.append((time, Double(cells.count) / Double(max(1, considered(thumb).count)), cells))
            moveFrames.removeAll { $0.time < time - params.maskWindow }
            if params.maskNovel {
                recentThumbs.append((time, thumb))
                recentThumbs.removeAll { $0.time < time - params.maskWindow }
            }
        }
        let volatile = volatileMask(now: time)
        let diffPrev = fraction(previous.thumb, thumb, volatile: volatile)
        let moving = diffPrev > params.motion
        if moving {
            if time - lastMotion >= params.settle { motionSince = time }
            lastMotion = time
        }
        latest = (index, time, thumb)
        latestDone = false
        if params.recentEnabled {
            // 案P: 外すマスを掛けずに比べる。掛けると、全画面が外れたとき動画の各フレームが履歴の全画像と一致し、
            // 動画の前の画面の「最後に見た時刻」まで延びる(2026-11-11のレビュー 高2)。
            latestMatches = Set(history.filter { same($0.thumb, thumb) }.map(\.id))
        }
        let stats = FrameStats(diffPrev: diffPrev, moving: moving, volatileCells: volatile.reduce(0) { $0 + ($1 ? 1 : 0) })
        return (stats, evaluate(now: time, volatile: volatile))
    }

    func tick(now: Double) -> SaveDecision? {
        guard latest != nil else { return nil }
        return evaluate(now: now, volatile: volatileMask(now: now))
    }

    /// 保存を決めたフレームの画像を書けた。基準・案Pの履歴・案Qの外すマスをここで確定する。
    func saveSucceeded(frameIndex: Int, at time: Double) {
        guard let offset = pending.firstIndex(where: { $0.index == frameIndex }) else { return }
        let decided = pending.remove(at: offset)
        saved = decided.thumb
        if latest?.index == frameIndex { latestDone = true }
        remember(decided.thumb, at: time)
        if let mask = decided.mask {
            applyMovingMask(mask, now: time)
        } else if params.maskNovel, !maskRegion.isEmpty {
            // 外したまま落ち着いて撮った画面の明るさは、もう見たものとして範囲に足す。同じ中身でもう一度撮らない。
            for cell in maskRegion.indices where maskRegion[cell] >= 0 {
                rangeLow[cell] = min(rangeLow[cell], decided.thumb.luma[cell]); rangeHigh[cell] = max(rangeHigh[cell], decided.thumb.luma[cell])
            }
        }
    }

    /// 保存を決めたフレームの画像を書けなかった。決定を捨て、外すマスの候補も捨てる。`retryInterval` 秒後に判定し直す。
    /// 動き続けて撮る決定なら、再試行の時刻にすぐ試せるよう、動き始めた時刻を戻す。
    func saveFailed(frameIndex: Int, at time: Double) {
        guard let offset = pending.firstIndex(where: { $0.index == frameIndex }) else { return }
        let decided = pending.remove(at: offset)
        retryNotBefore = time + params.retryInterval
        if decided.reason == .moving { motionSince = retryNotBefore - params.movingSeconds }
        if saved == nil, pending.isEmpty { latestDone = false }
    }

    private func evaluate(now: Double, volatile: [Bool]) -> SaveDecision? {
        guard let latest else { return nil }
        if params.recentEnabled, params.recentExtend {
            // 比べる範囲にある画像と同じ画面を見ている間は、最後に見た時刻を延ばす。範囲の外の画像は延ばさない。
            let eligible = eligibleIDs(now: now)
            for offset in history.indices where latestMatches.contains(history[offset].id) && eligible.contains(history[offset].id) {
                history[offset].lastSeen = now
            }
        }
        guard now >= retryNotBefore, !latestDone, !pending.contains(where: { $0.index == latest.index }) else { return nil }
        guard let saved else {
            // 最初の保存に失敗した後は、基準が無いので落ち着きを待たずに撮り直す。
            return decide(latest, now: now, reason: .first, diffSaved: 1, mask: nil)
        }
        let compared = comparisonMask(now: now, volatile: volatile)
        if now - lastMotion >= params.settle {
            let volatile = compared
            let diffSaved = fraction(saved, latest.thumb, volatile: volatile)
            guard diffSaved > params.save, !seenRecently(now: now) else { return nil }
            if Self.debug {
                let width = latest.thumb.width
                let cells = considered(latest.thumb).filter { (volatile.isEmpty || !volatile[$0]) && Self.changed(saved.luma[$0], latest.thumb.luma[$0], params.cellDelta) }
                let xs = cells.map { $0 % width }, ys = cells.map { $0 / width }
                print(String(format: "  [保存] %.2f 落ち着いた。基準との差%.4f 外したマス%d 差の範囲 x%d〜%d y%d〜%d", now, diffSaved,
                             volatile.filter { $0 }.count, xs.min() ?? -1, xs.max() ?? -1, ys.min() ?? -1, ys.max() ?? -1))
            }
            return decide(latest, now: now, reason: .settled, diffSaved: diffSaved, mask: nil)
        }
        // 動き続けている。案Q・案R: 動き始めてから movingSeconds 秒たったら、その時点の1枚を試す。
        guard params.movingSeconds > 0, now - motionSince >= params.movingSeconds else { return nil }
        motionSince = now
        // 比べるのは今の外すマスでの基準。候補のマスで比べると、全画面の動画が丸ごと外れて保存しない。
        let diffSaved = fraction(saved, latest.thumb, volatile: compared)
        guard diffSaved > params.save, !seenRecently(now: now) else { return nil }
        // 外すマスは候補として決定に持たせ、保存に成功したら確定する(2026-11-11のレビュー 高3)。
        return decide(latest, now: now, reason: .moving, diffSaved: diffSaved, mask: params.maskWindow > 0 ? movingMaskCandidate(now: now) : nil)
    }

    private func decide(_ latest: (index: Int, time: Double, thumb: Thumb), now: Double, reason: SaveDecision.Reason, diffSaved: Double, mask: [Bool]?) -> SaveDecision {
        pending.append((latest.index, latest.thumb, reason, mask))
        let decision = SaveDecision(frameTime: latest.time, frameIndex: latest.index, reason: reason, diffSaved: diffSaved, decidedAt: now)
        if autoConfirm { saveSucceeded(frameIndex: latest.index, at: now) }
        return decision
    }

    // MARK: 案P

    private func remember(_ thumb: Thumb, at time: Double) {
        guard params.recentEnabled else { return }
        history.append((nextHistoryID, thumb, time))
        if let latest, same(thumb, latest.thumb) { latestMatches.insert(nextHistoryID) }
        nextHistoryID += 1
        // 比べる範囲を超えて古い画像は持たない。範囲が秒だけなら、その秒数より前に見た画像を捨てる。
        history.sort { $0.lastSeen > $1.lastSeen }
        if params.recentCount > 0, history.count > params.recentCount { history.removeLast(history.count - params.recentCount) }
        if params.recentSeconds > 0 { history.removeAll { time - $0.lastSeen > params.recentSeconds } }
        if history.count > 64 { history.removeLast(history.count - 64) }
    }

    /// 案Pの「同じ画面」。外すマスは掛けない。
    private func same(_ a: Thumb, _ b: Thumb) -> Bool {
        if params.recentExact { return considered(b).allSatisfy { a.luma[$0] == b.luma[$0] } }
        return fraction(a, b, volatile: []) <= params.recentSameThreshold
    }

    /// 比べる範囲にある画像。最後に見た時刻の新しい順に recentCount 枚、かつ recentSeconds 秒以内。
    private func eligibleIDs(now: Double) -> Set<Int> {
        let ordered = history.sorted { $0.lastSeen > $1.lastSeen }
        let counted = params.recentCount > 0 ? Array(ordered.prefix(params.recentCount)) : ordered
        return Set(counted.filter { params.recentSeconds <= 0 || now - $0.lastSeen <= params.recentSeconds }.map(\.id))
    }

    private func seenRecently(now: Double) -> Bool {
        guard params.recentEnabled, !latestMatches.isEmpty else { return false }
        let hit = !latestMatches.isDisjoint(with: eligibleIDs(now: now))
        if hit, Self.debug, let latest {
            let matched = history.filter { latestMatches.contains($0.id) }.map { String(format: "#%d(最後に見た%.1f)", $0.id, $0.lastSeen) }
            print(String(format: "  [P] %.2f 観測%.2f を保存しない。同じ画面: ", now, latest.time) + matched.joined(separator: " "))
        }
        return hit
    }

    static let debug = ProcessInfo.processInfo.environment["PROBE_DEBUG"] != nil

    // MARK: 案Q

    /// 直近 maskWindow 秒に maskCount 回以上変わったマスを候補にする。前に外していたマスは引き継がず、決め直す。
    /// 理由: 引き継ぐと、送る前のスライドの動く画像の位置が、次のスライドでも外れ続ける。
    /// 広い差のフレームでの1度だけの変化は数えない(`maskBroad`)。
    private func movingMaskCandidate(now: Double) -> [Bool]? {
        guard let latest else { return nil }
        let width = latest.thumb.width, height = latest.thumb.height
        var all = [Int](repeating: 0, count: width * height)
        var narrow = [Int](repeating: 0, count: width * height)
        for frame in moveFrames where frame.time >= now - params.maskWindow {
            let broad = params.maskBroad > 0 && frame.fraction > params.maskBroad
            for cell in frame.cells { all[Int(cell)] += 1; if !broad { narrow[Int(cell)] += 1 } }
        }
        var mask = [Bool](repeating: false, count: width * height)
        var any = false
        for cell in considered(latest.thumb) {
            let candidate = params.maskBroad > 0
                ? (all[cell] >= max(params.maskCount, 2) || (all[cell] >= params.maskCount && narrow[cell] >= 1))
                : all[cell] >= params.maskCount
            guard candidate else { continue }
            any = true
            let x = cell % width, y = cell / width
            for dy in -params.maskGrow...params.maskGrow { for dx in -params.maskGrow...params.maskGrow {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < width, ny >= excludedRows, ny < height else { continue }
                mask[ny * width + nx] = true
            } }
        }
        guard any else { return nil }
        return params.maskBox ? Self.boxes(mask, width: width, height: height) : mask
    }

    private func applyMovingMask(_ mask: [Bool], now: Double) {
        guard let latest else { return }
        let (labels, count) = Self.label(mask, width: latest.thumb.width, height: latest.thumb.height)
        maskRegion = labels
        regionLastChange = Array(repeating: now, count: params.maskRegional ? count : 1)
        if params.maskNovel {
            rangeLow = [UInt8](repeating: 255, count: mask.count); rangeHigh = [UInt8](repeating: 0, count: mask.count)
            for (_, thumb) in recentThumbs where thumb.luma.count == mask.count {
                for cell in mask.indices where mask[cell] {
                    rangeLow[cell] = min(rangeLow[cell], thumb.luma[cell]); rangeHigh[cell] = max(rangeHigh[cell], thumb.luma[cell])
                }
            }
        }
    }

    /// 基準と比べるときに外すマス。maskNovel なら、落ち着いた見なかった明るさのマスを外さない。
    private func comparisonMask(now: Double, volatile: [Bool]) -> [Bool] {
        guard params.maskNovel, !maskRegion.isEmpty, !volatile.isEmpty, let latest else { return volatile }
        var result = volatile
        let delta = params.cellDelta
        for cell in maskRegion.indices where maskRegion[cell] >= 0 && now - cellLastChange[cell] >= params.settle {
            let value = Int(latest.thumb.luma[cell])
            if value < Int(rangeLow[cell]) - delta || value > Int(rangeHigh[cell]) + delta { result[cell] = false }
        }
        return result
    }

    /// つながったマス(上下左右)に番号を振る。
    static func label(_ mask: [Bool], width: Int, height: Int) -> ([Int], Int) {
        var label = [Int](repeating: -1, count: mask.count)
        var next = 0
        for start in mask.indices where mask[start] && label[start] < 0 {
            var stack = [start]
            label[start] = next
            while let cell = stack.popLast() {
                let x = cell % width, y = cell / width
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && nx < width && ny >= 0 && ny < height {
                    let neighbor = ny * width + nx
                    if mask[neighbor], label[neighbor] < 0 { label[neighbor] = next; stack.append(neighbor) }
                }
            }
            next += 1
        }
        return (label, next)
    }

    /// つながったマス(上下左右)ごとに、外接する長方形を埋める。埋めた長方形どうしが重なれば、もう一度つなぐ。
    static func boxes(_ mask: [Bool], width: Int, height: Int) -> [Bool] {
        var current = mask
        while true {
            let (labels, count) = label(current, width: width, height: height)
            var minX = [Int](repeating: width, count: count), maxX = [Int](repeating: -1, count: count)
            var minY = [Int](repeating: height, count: count), maxY = [Int](repeating: -1, count: count)
            for cell in labels.indices where labels[cell] >= 0 {
                let r = labels[cell], x = cell % width, y = cell / width
                minX[r] = min(minX[r], x); maxX[r] = max(maxX[r], x); minY[r] = min(minY[r], y); maxY[r] = max(maxY[r], y)
            }
            var result = current
            for r in 0..<count { for y in minY[r]...maxY[r] { for x in minX[r]...maxX[r] { result[y * width + x] = true } } }
            if result == current { return result }
            current = result
        }
    }

    private func considered(_ thumb: Thumb) -> Range<Int> { (excludedRows * thumb.width)..<(thumb.width * thumb.height) }

    private func volatileMask(now: Double) -> [Bool] {
        // 案Q: 外したマスがmaskRelease 秒変わらなければ戻す。領域ごとに戻すときは、その領域だけを戻す。
        if !maskRegion.isEmpty {
            var released = false
            for region in regionLastChange.indices where regionLastChange[region].isFinite && now - regionLastChange[region] >= params.maskRelease {
                regionLastChange[region] = -Double.infinity
                released = true
            }
            if released {
                for cell in maskRegion.indices where maskRegion[cell] >= 0 {
                    let region = params.maskRegional ? maskRegion[cell] : 0
                    if !regionLastChange[region].isFinite { maskRegion[cell] = -1 }
                }
                if !maskRegion.contains(where: { $0 >= 0 }) { maskRegion = []; regionLastChange = [] }
            }
        }
        let old: [Bool] = (params.volatileSeconds > 0 && !volatileUntil.isEmpty) ? volatileUntil.map { $0 > now } : []
        if maskRegion.isEmpty { return old }
        let moving = maskRegion.map { $0 >= 0 }
        if old.isEmpty { return moving }
        return zip(old, moving).map { $0 || $1 }
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
