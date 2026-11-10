import Foundation

/// 画面を縮めた輝度画像。値は0〜255で、行は上から順に並ぶ。
public struct ScreenThumbnail: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let luma: [UInt8]

    public init(width: Int, height: Int, luma: [UInt8]) {
        precondition(width > 0 && height > 0 && luma.count == width * height)
        self.width = width; self.height = height; self.luma = luma
    }

    /// 縦横比を保って縮めたときの高さ。
    public static func height(forWidth width: Int, imageWidth: Int, imageHeight: Int) -> Int {
        max(1, Int((Double(width) * Double(imageHeight) / Double(imageWidth)).rounded()))
    }

    /// 等倍の輝度をマスごとの単純平均で縮める。補間の癖に判定を左右させない。
    /// - pixel: 行頭からの位置で1画素の輝度を返す。呼び出し側の画素の並び(BGRAなど)をここへ持ち込まない
    public static func average(width w: Int, height h: Int, to tw: Int, pixel: (_ x: Int, _ y: Int) -> UInt8) -> ScreenThumbnail {
        let th = height(forWidth: tw, imageWidth: w, imageHeight: h)
        var sums = [Int](repeating: 0, count: tw * th)
        var counts = [Int](repeating: 0, count: tw * th)
        let xmap = (0..<w).map { $0 * tw / w }
        for y in 0..<h {
            let rowBase = (y * th / h) * tw
            for x in 0..<w {
                sums[rowBase + xmap[x]] += Int(pixel(x, y))
                counts[rowBase + xmap[x]] += 1
            }
        }
        var luma = [UInt8](repeating: 0, count: tw * th)
        for cell in luma.indices where counts[cell] > 0 {
            let total: Int = sums[cell] + counts[cell] / 2
            luma[cell] = UInt8(total / counts[cell])
        }
        return ScreenThumbnail(width: tw, height: th, luma: luma)
    }
}

/// 撮る契機の判定に使う値。既定値は第0フェーズで決めた初期値。
/// 根拠: [画面の記録の試作の検証記録](docs/records/screen-capture-spike.md)
public struct ScreenChangeParameters: Equatable, Sendable {
    /// 比べる縮小画像の幅。高さは画面の縦横比から決める。64では1行の入力も拾えなかった。
    public var thumbnailWidth = 128
    /// 1マスの輝度差がこれを超えたら、そのマスは変わったとみなす。
    public var cellDelta = 8
    /// 落ち着きの判定: 直前の観測フレームと比べて変わったマスの割合がこれを超えたら「動いている」。
    public var motion = 0.0002
    /// 保存する価値の判定: 最後に保存した画像と比べて変わったマスの割合がこれを超えたら保存する。
    /// 動きのしきい値以下にしない。逆にすると、動きに数えない小さなアニメーションで保存し続ける。
    public var save = 0.001
    /// 動いていない状態がこの秒数続いたら「落ち着いた」。
    public var settle = 1.5
    /// 上端から比較に使わない高さ。画面の高さに対する割合。メニューバーの時計で保存しないため。
    public var excludedTopFraction = 0.0
    /// 保存に失敗してから、次の保存を決めるまでの秒数。ディスク満杯などで毎回の判定ごとに書き直さないため。
    public var retryInterval = 5.0

    public init() {}
}

/// 画面が意味のある変化をして落ち着いたときに保存を決める。時刻は単調な秒。
/// - 落ち着き: 直前の観測フレームとの差がしきい値を超えない状態が `settle` 秒続く
/// - 保存する価値: 落ち着いている間の最新フレームが、比較の基準と十分に違う
/// - 基準が無いとき(開始・撮れない期間の後・最初の保存の失敗後)は、落ち着きを待たずに最新フレームを保存する
/// - `idle` の間はフレームが来ないので、呼び出し側が `tick` で時間を進める
///
/// 保存の結果は呼び出し側が返す。決定を受け付けたら `accepted` で受付の番号を、結果は `saveSucceeded` / `saveFailed` で返す。
/// 結果が返るまでの決定は「保存中」として持つ。
/// - 保存に失敗した決定は捨て、基準はその前へ自然に戻る。複数の保存中の結果がどの順で返っても、未保存の画像を基準に残さない
///
/// 物差しは2つに分け、混ぜない。`adopt`・`restart`・`reset` も含め、どの操作の後も次の不変条件を保つ。
/// - 新旧の順序は受付の番号だけで比べる。受付の番号は、呼び出し側が自動の保存も「いま撮る」も1つのロックの中で振る、単調に増える番号
/// - フレームの番号は観測の同一性にだけ使う。どの観測が保存中か、どの観測を保存し終えたかを見分ける。新旧の比較には使わない
/// - 基準(`baselineEntry`): 保存中の決定と、保存に成功した画像(`confirmed`)のうち、受付の番号の新しい方
///   - 受付の番号をまだ受け取っていない保存中の決定は、決めたばかりなので最も新しいとみなす
///   - `confirmed` は受付の番号が新しくなるときだけ替える。完了の遅い古い受付が、新しい基準を上書きしない
/// - 決定するのは、保存中でも使い終えてもいない最新の観測(`latest`)だけ
///   - 保存に成功した観測は、その成功が基準へ入らなくても、新しい観測が来るまでもう一度保存しない
///   - 「いま撮る」より前の観測は、手動の画像を基準に採った時点で使い終える。後で保存すると、手動の画像より新しい受付の番号が付いて基準を古い画面へ戻すため
///     - 観測の前後は、観測したときまでに受け付けた保存の数(`acceptedBefore`)と、手動の画像の受付の番号を比べて決める。同じ受付の番号の物差しで、フレームの番号は使わない
///     - 手動の撮影より後の観測は残す
///   - 保存に失敗した観測は保存中から外れ、基準が前へ戻るので、間隔をおいて撮り直せる
public struct ScreenChangeDetector: Sendable {
    public struct Decision: Equatable, Sendable {
        public enum Reason: Equatable, Sendable { case first, settled }
        /// 保存する画像のフレームの番号。保存を決めた時刻ではなく、このフレームの観測時刻を使う。
        /// 呼び出し側は観測ごとに増える番号を渡す。`reset` の後も番号を戻さない。
        public let frame: Int
        public let reason: Reason
    }

    public let parameters: ScreenChangeParameters
    /// acceptedBefore: 観測したときまでに受け付けた保存の数
    private var latest: (frame: Int, thumbnail: ScreenThumbnail, acceptedBefore: Int)?
    /// 最新の観測を使い終えた。保存に成功したか、「いま撮る」より前の観測だった。新しい観測で戻す。
    private var latestDone = false
    /// 保存に成功した画像のうち、受付の番号の最も新しいもの。自動の決定か「いま撮る」の画像。
    private var confirmed: (order: Int, thumbnail: ScreenThumbnail)?
    /// 結果を待っている決定。order: 受付の番号。受け取るまではnil
    private var inFlight: [(frame: Int, order: Int?, thumbnail: ScreenThumbnail)] = []
    private var retryNotBefore = -Double.infinity
    private var lastMotion = -Double.infinity
    private var excludedRows = 0

    public init(parameters: ScreenChangeParameters = ScreenChangeParameters()) {
        precondition(parameters.motion <= parameters.save, "動きのしきい値は保存のしきい値以下にする")
        self.parameters = parameters
    }

    /// 新しいフレームを観測した。寸法が変わったら撮れない期間の後と同じく最初から数え直す。
    /// 一時停止をまたいで引き継いだ比較の基準とも寸法を比べる。
    /// - acceptedBefore: 観測したときまでに受け付けた保存の数。呼び出し側が受付の番号と同じロックの中で読む
    public mutating func observe(frame: Int, at time: Double, thumbnail: ScreenThumbnail, acceptedBefore: Int = 0) -> Decision? {
        if let previous = latest?.thumbnail ?? baseline, previous.width != thumbnail.width || previous.height != thumbnail.height {
            reset()
        }
        if let previous = latest {
            if changedFraction(previous.thumbnail, thumbnail) > parameters.motion { lastMotion = time }
        } else {
            excludedRows = min(thumbnail.height, Int((parameters.excludedTopFraction * Double(thumbnail.height)).rounded(.up)))
        }
        latest = (frame, thumbnail, acceptedBefore)
        latestDone = false
        return evaluate(now: time)
    }

    /// 時間だけ進める。`idle` の通知と、通知が来ない間の定期の呼び出しで使う。
    public mutating func tick(at time: Double) -> Decision? {
        latest == nil ? nil : evaluate(now: time)
    }

    /// 「いま撮る」で公開した画像を比較の基準にする。受付の番号が今の基準より新しいときだけ替える。
    /// - 理由: 保留していた自動の画像を「いま撮る」で捨てたとき、捨てた画像が基準に残ると、画面がそれへ戻っても変化なしとなり記録できない
    /// - order: 押したときに自動の保存と同じロックの中で振った受付の番号
    /// - 押したときより前の最新の観測は、以後の判定で使わない。押した後の観測は残す
    public mutating func adopt(order: Int, thumbnail: ScreenThumbnail) {
        if confirmed.map({ $0.order < order }) ?? true { confirmed = (order, thumbnail) }
        // 観測までに受け付けた数が手動の番号以下なら、手動の受付より前に観測した。
        if let latest, latest.acceptedBefore <= order { latestDone = true }
    }

    /// 保存を決めたフレームを受け付けた。受付の番号を保存中の決定に結びつける。
    public mutating func accepted(frame: Int, order: Int) {
        guard let index = inFlight.firstIndex(where: { $0.frame == frame }) else { return }
        inFlight[index].order = order
    }

    /// 一時停止から再開した。観測と動きは数え直し、比較の基準は引き継ぐ。保存中の決定の結果も、この後に返れば基準に入る。
    /// - 理由: 一時停止の直前に公開した画面と再開の直後の画面が同じなら、同じ画面を2枚続けて残さない
    /// - 一時停止の前の最後の画面は、無音の間に保留していても一時停止の直前に公開される。基準はその画面と一致する
    public mutating func restart() {
        latest = nil; latestDone = false
        lastMotion = -Double.infinity
    }

    /// 撮れない期間に入った。保留中のフレームを後から保存しない。保存中の決定の結果は、この後に返っても無視する。
    public mutating func reset() {
        latest = nil; latestDone = false; confirmed = nil; inFlight = []
        retryNotBefore = -Double.infinity; lastMotion = -Double.infinity
    }

    /// 保存を決めたフレームの画像を書けた。受付の番号が今の基準より新しいときだけ基準にする。
    public mutating func saveSucceeded(frame: Int) {
        guard let index = inFlight.firstIndex(where: { $0.frame == frame }) else { return }
        let decided = inFlight.remove(at: index)
        if latest?.frame == frame { latestDone = true }
        guard let order = decided.order else { return }
        if confirmed.map({ $0.order < order }) ?? true { confirmed = (order, decided.thumbnail) }
    }

    /// 保存を決めたフレームの画像を書けなかった。その決定を捨て、`retryInterval` 秒は次の保存を決めない。
    public mutating func saveFailed(frame: Int, at time: Double) {
        guard let index = inFlight.firstIndex(where: { $0.frame == frame }) else { return }
        inFlight.remove(at: index)
        retryNotBefore = time + parameters.retryInterval
    }

    /// 結果待ちの決定と保存済みのうち、受付の番号の新しい方。古い結果待ちが残っていても、後で成功した画像を基準にする。
    /// 受付の番号をまだ受け取っていない決定は、決めたばかりなので最も新しいとみなす。
    private var baselineEntry: (order: Int, thumbnail: ScreenThumbnail)? {
        var newest = confirmed
        // 受付の番号の無い決定どうしは、後に決めた方を新しいとみなす。保存中は決めた順に並ぶ。
        for decided in inFlight where newest.map({ ($0.order) <= (decided.order ?? .max) }) ?? true {
            newest = (decided.order ?? .max, decided.thumbnail)
        }
        return newest
    }
    private var baseline: ScreenThumbnail? { baselineEntry?.thumbnail }

    private mutating func evaluate(now: Double) -> Decision? {
        // 保存中の観測と、保存に成功した観測は、同じ観測のうちはもう一度決めない。見分けはフレームの番号で行う。
        guard let latest, now >= retryNotBefore, !latestDone,
              !inFlight.contains(where: { $0.frame == latest.frame }) else { return nil }
        let reason: Decision.Reason
        if let baseline {
            guard now - lastMotion >= parameters.settle, changedFraction(baseline, latest.thumbnail) > parameters.save else { return nil }
            reason = .settled
        } else {
            reason = .first
        }
        inFlight.append((latest.frame, nil, latest.thumbnail))
        return Decision(frame: latest.frame, reason: reason)
    }

    private func changedFraction(_ a: ScreenThumbnail, _ b: ScreenThumbnail) -> Double {
        // 「いま撮る」で受け取った基準は寸法が違いうる。比べられなければ全部変わったとみなす。
        guard a.width == b.width, a.height == b.height else { return 1 }
        let range = (excludedRows * b.width)..<(b.width * b.height)
        guard !range.isEmpty else { return 0 }
        var count = 0
        for cell in range where abs(Int(a.luma[cell]) - Int(b.luma[cell])) > parameters.cellDelta { count += 1 }
        return Double(count) / Double(range.count)
    }
}
