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
/// 保存の結果は呼び出し側が `saveSucceeded` / `saveFailed` で返す。結果が返るまでの決定は「保存中」として持つ。
/// - 比較の基準は、保存中の決定の最新と、保存に成功した最新のうち、フレームの新しい方
/// - 保存に失敗した決定は捨て、基準はその前へ自然に戻る。複数の保存中の結果がどの順で返っても、未保存の画像を基準に残さない
public struct ScreenChangeDetector: Sendable {
    public struct Decision: Equatable, Sendable {
        public enum Reason: Equatable, Sendable { case first, settled }
        /// 保存する画像のフレームの番号。保存を決めた時刻ではなく、このフレームの観測時刻を使う。
        /// 呼び出し側は観測ごとに増える番号を渡す。`reset` の後も番号を戻さない。
        public let frame: Int
        public let reason: Reason
    }

    public let parameters: ScreenChangeParameters
    private var latest: (frame: Int, thumbnail: ScreenThumbnail)?
    /// 保存に成功した最も新しい決定。
    private var confirmed: (frame: Int, thumbnail: ScreenThumbnail)?
    /// 結果を待っている決定。フレームの番号の順。
    private var inFlight: [(frame: Int, thumbnail: ScreenThumbnail)] = []
    private var retryNotBefore = -Double.infinity
    private var lastMotion = -Double.infinity
    private var excludedRows = 0

    public init(parameters: ScreenChangeParameters = ScreenChangeParameters()) {
        precondition(parameters.motion <= parameters.save, "動きのしきい値は保存のしきい値以下にする")
        self.parameters = parameters
    }

    /// 新しいフレームを観測した。寸法が変わったら撮れない期間の後と同じく最初から数え直す。
    public mutating func observe(frame: Int, at time: Double, thumbnail: ScreenThumbnail) -> Decision? {
        if let previous = latest, previous.thumbnail.width != thumbnail.width || previous.thumbnail.height != thumbnail.height {
            reset()
        }
        if let previous = latest {
            if changedFraction(previous.thumbnail, thumbnail) > parameters.motion { lastMotion = time }
        } else {
            excludedRows = min(thumbnail.height, Int((parameters.excludedTopFraction * Double(thumbnail.height)).rounded(.up)))
        }
        latest = (frame, thumbnail)
        return evaluate(now: time)
    }

    /// 時間だけ進める。`idle` の通知と、通知が来ない間の定期の呼び出しで使う。
    public mutating func tick(at time: Double) -> Decision? {
        latest == nil ? nil : evaluate(now: time)
    }

    /// 撮れない期間に入った。保留中のフレームを後から保存しない。保存中の決定の結果は、この後に返っても無視する。
    public mutating func reset() {
        latest = nil; confirmed = nil; inFlight = []
        retryNotBefore = -Double.infinity; lastMotion = -Double.infinity
    }

    /// 保存を決めたフレームの画像を書けた。
    public mutating func saveSucceeded(frame: Int) {
        guard let index = inFlight.firstIndex(where: { $0.frame == frame }) else { return }
        let decided = inFlight.remove(at: index)
        if confirmed.map({ $0.frame < decided.frame }) ?? true { confirmed = decided }
    }

    /// 保存を決めたフレームの画像を書けなかった。その決定を捨て、`retryInterval` 秒は次の保存を決めない。
    public mutating func saveFailed(frame: Int, at time: Double) {
        guard let index = inFlight.firstIndex(where: { $0.frame == frame }) else { return }
        inFlight.remove(at: index)
        retryNotBefore = time + parameters.retryInterval
    }

    /// 結果待ちの最新と保存済みのうち、フレームの新しい方。古い結果待ちが残っていても、後で成功した画像を基準にする。
    private var baseline: ScreenThumbnail? {
        switch (inFlight.last, confirmed) {
        case let (pending?, saved?): return pending.frame > saved.frame ? pending.thumbnail : saved.thumbnail
        case let (pending?, nil): return pending.thumbnail
        case let (nil, saved): return saved?.thumbnail
        }
    }

    private mutating func evaluate(now: Double) -> Decision? {
        guard let latest, now >= retryNotBefore, !inFlight.contains(where: { $0.frame == latest.frame }) else { return nil }
        let reason: Decision.Reason
        if let baseline {
            guard now - lastMotion >= parameters.settle, changedFraction(baseline, latest.thumbnail) > parameters.save else { return nil }
            reason = .settled
        } else {
            reason = .first
        }
        inFlight.append(latest)
        return Decision(frame: latest.frame, reason: reason)
    }

    private func changedFraction(_ a: ScreenThumbnail, _ b: ScreenThumbnail) -> Double {
        let range = (excludedRows * b.width)..<(b.width * b.height)
        guard !range.isEmpty else { return 0 }
        var count = 0
        for cell in range where abs(Int(a.luma[cell]) - Int(b.luma[cell])) > parameters.cellDelta { count += 1 }
        return Double(count) / Double(range.count)
    }
}
