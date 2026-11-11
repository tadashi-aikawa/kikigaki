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

/// 撮る契機の判定に使う値。設定キーにはせず、判定器の定数として持つ。
/// 根拠: [画面の記録の試作の検証記録](docs/records/screen-capture-spike.md)、
/// [動き続ける画面と交互に変わる画面の規則の試作の検証記録](docs/records/screen-motion-alternation.md)
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

    // 動き続ける画面。試作の案Q
    /// 動いている状態がこの秒数続いたら、落ち着きを待たずにその時点の1枚を保存する。0なら撮らない。
    /// 動き続ける間は、この秒数ごとに次を試す。
    public var movingSeconds = 12.0
    /// 動き続けて撮った1枚の保存に成功したら、判定の時刻から直近この秒数に1回でも変わったマスを比較から外す。
    /// 動き始めた時刻より短くする。動き始めの直前の送りを外す候補に入れないため。12秒では、送る前から画面が動いていると送りが入り、本文の全体が外れた。
    public var excludeWindow = 10.0
    /// 外すマスを上下左右にこのマス数だけ広げる。動く画像の縁で一部だけ動くマスを外し残さないため。
    public var excludeGrow = 1
    /// 外したマスは、つながりごとに、変わらない状態がこの秒数続いたら比較へ戻す。
    public var excludeRelease = 3.0

    // 直近に公開した画面と比べる。試作の案P
    /// 最後に見てからこの秒数以内の公開した画面と同じなら保存しない。0なら比べない。
    /// 12秒の理由: 10秒おきの交互と、観測の間隔の最大1.4秒を足すと11.4秒
    public var recentSeconds = 12.0
    /// 直近の画面と比べるとき、外しているマスが比較に使うマスのこの割合以下なら、外しているマスを除いて比べる。超えたら全マスで比べる。
    /// 理由: 全画面の動画では外すマスが画面の全体になる。除くと動画の各フレームが前の画面と同じとみなされ、その画面へ戻っても撮らない
    public var recentExcludeLimit = 0.5

    public init() {}
}

/// 画面が意味のある変化をして落ち着いたときに保存を決める。時刻は単調な秒。
/// 仕様は [画面の記録](docs/screen-capture.md) の「撮る契機の判定」
/// - 落ち着き: 直前の観測フレームとの差がしきい値を超えない状態が `settle` 秒続く
/// - 保存する価値: 落ち着いている間の最新フレームが、比較の基準と十分に違う
/// - 基準が無いとき(開始・撮れない期間の後・最初の保存の失敗後)は、落ち着きを待たずに最新フレームを保存する
/// - `idle` の間はフレームが来ないので、呼び出し側が `tick` で時間を進める
/// - 動き続ける画面: 動いている状態が `movingSeconds` 続いたら1枚保存し、保存に成功したら動いたマスを比較から外す
/// - 直近に公開した画面: 最後に見てから `recentSeconds` 以内の公開した画面と同じなら保存しない
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
/// - 直近に公開した画面(`recent`)は、比較の基準とは別に持つ。新旧を比べず、最後に見た時刻だけで範囲を決める
///   - 入れるのは保存に成功して公開か保留した画像と、「いま撮る」の画像。比べる相手にするのは公開した画像だけ。保留した画像は `published` で公開を知らせるまで比べない
///   - 保留のまま捨てた画像は `discarded` で抜く。その画面へ戻ったら撮れるようにする
///   - その場の行き先は、保存の結果と一緒に `SaveOutcome` で1回で受け取る。後から知らせるのは、保留した画像の公開と破棄だけ
/// - 外すマスは、動き続けて撮った1枚の保存に成功した時点で確定する。決めた後に `restart`・`reset` を挟んだ決定は、成功しても確定しない
///
/// 試作 `experiments/screen-capture` の `ChangeDetector` と同じ入力で同じ決定を出す。`ScreenChangeReplayTests` が合成の観測の列で固定し、
/// 実画面の記録は手元で書き出したものを環境変数で渡して当てる。
public struct ScreenChangeDetector: Sendable {
    /// 保存に成功した画像の、その場で決まった行き先。保存の結果と一緒に1回で渡す。
    /// - published: その場で公開した。直近の画面として比べる
    /// - held: 無音の間なので保留した。公開か破棄は `published(order:)` / `discarded(order:)` で後から知らせる
    /// - discarded: 保存はしたが、届いた時点で公開せずに捨てた。「いま撮る」より前に受け付けた無音の中の画面が当たる
    ///   - 保存の失敗とは分ける。失敗にすると、再試行の間隔だけ次の保存を決めない
    ///   - 直近の画面に入れず、外すマスも確定しない。比較の基準には受付の番号の順で入る。後に受け付けた「いま撮る」より古いので、基準は手動の画像のまま
    public enum SaveOutcome: Equatable, Sendable { case published, held, discarded }

    public struct Decision: Equatable, Sendable {
        /// - moving: 動き続けて撮った1枚。保存に成功したら動いたマスを外す
        public enum Reason: Equatable, Sendable { case first, settled, moving }
        /// 保存する画像のフレームの番号。保存を決めた時刻ではなく、このフレームの観測時刻を使う。
        /// 呼び出し側は観測ごとに増える番号を渡す。`reset` の後も番号を戻さない。
        public let frame: Int
        public let reason: Reason

        public init(frame: Int, reason: Reason) { self.frame = frame; self.reason = reason }
    }

    private struct InFlight {
        let frame: Int
        /// 受付の番号。受け取るまではnil
        var order: Int?
        let thumbnail: ScreenThumbnail
        let reason: Decision.Reason
        let decidedAt: Double
        /// 動き続けて撮った1枚の、外すマスの候補。保存に成功したら確定する。
        let exclusion: [Bool]?
        /// 決めたときの観測の世代。
        let generation: Int
    }

    /// 直近に保存した画面。
    private struct Seen {
        let id: Int
        /// 受付の番号。保留の公開と破棄をこの番号で受け取る。
        let order: Int?
        let thumbnail: ScreenThumbnail
        var lastSeen: Double
        /// 公開した。保留中の画像はfalseで、比べる相手にしない。
        var published: Bool
    }

    public let parameters: ScreenChangeParameters
    /// acceptedBefore: 観測したときまでに受け付けた保存の数
    private var latest: (frame: Int, thumbnail: ScreenThumbnail, acceptedBefore: Int)?
    /// 最新の観測を使い終えた。保存に成功したか、「いま撮る」より前の観測だった。新しい観測で戻す。
    private var latestDone = false
    /// 保存に成功した画像のうち、受付の番号の最も新しいもの。自動の決定か「いま撮る」の画像。
    private var confirmed: (order: Int, thumbnail: ScreenThumbnail)?
    /// 結果を待っている決定。
    private var inFlight: [InFlight] = []
    private var retryNotBefore = -Double.infinity
    private var lastMotion = -Double.infinity
    private var excludedRows = 0
    /// 観測の世代。`restart` と `reset` で進める。古い世代で決めた外すマスの候補は確定しない。
    private var generation = 0
    /// 最後に受け取った時刻。時刻を渡さない `adopt` の、最後に見た時刻に使う。
    private var clock = -Double.infinity

    // 直近に公開した画面
    private var recent: [Seen] = []
    private var nextSeenID = 0
    /// 最新の観測と同じ画面の `recent` のid。
    private var latestMatches: Set<Int> = []
    /// 直近の画面との比較で除くマス。空なら除かない。
    private var recentExclusion: [Bool] = []

    // 動き続ける画面
    /// 落ち着いた状態から動き始めた時刻。動き続けて撮るたびに、その時刻へ進める。
    private var motionSince = -Double.infinity
    /// 直近 `excludeWindow` 秒の観測ごとの、直前の観測から変わったマス。
    private var movements: [(time: Double, cells: [Int32])] = []
    /// 外しているマスのつながりの番号。-1は外していない。外していなければ空。
    private var excludedRegion: [Int] = []
    /// つながりごとの、最後に変わった時刻。戻したつながりは -inf。
    private var regionLastChange: [Double] = []
    /// `excludedRegion` から作った、外しているマス。外していなければ空。
    private var exclusion: [Bool] = []

    public init(parameters: ScreenChangeParameters = ScreenChangeParameters()) {
        precondition(parameters.motion <= parameters.save, "動きのしきい値は保存のしきい値以下にする")
        self.parameters = parameters
    }

    /// 比較から外しているマスの数。診断と検証に使う。
    public var excludedCellCount: Int { exclusion.reduce(0) { $0 + ($1 ? 1 : 0) } }
    /// 直近の画面の数。公開した画像と、公開を待つ保留の画像を分けて数える。診断と検証に使う。
    public var recentScreenCount: (published: Int, held: Int) {
        (recent.filter(\.published).count, recent.filter { !$0.published }.count)
    }

    /// 新しいフレームを観測した。寸法が変わったら撮れない期間の後と同じく最初から数え直す。
    /// 一時停止をまたいで引き継いだ比較の基準とも寸法を比べる。
    /// - acceptedBefore: 観測したときまでに受け付けた保存の数。呼び出し側が受付の番号と同じロックの中で読む
    public mutating func observe(frame: Int, at time: Double, thumbnail: ScreenThumbnail, acceptedBefore: Int = 0) -> Decision? {
        if let previous = latest?.thumbnail ?? baseline, previous.width != thumbnail.width || previous.height != thumbnail.height {
            reset()
        }
        clock = time
        if let previous = latest {
            // 動いたマスは外すマスを掛けずに数える。外したマスの動きは、戻す時刻を延ばすのに使う。
            if parameters.movingSeconds > 0 { recordMovement(from: previous.thumbnail, to: thumbnail, at: time) }
            releaseExclusion(now: time)
            if changedFraction(previous.thumbnail, thumbnail, excluding: exclusion) > parameters.motion {
                if time - lastMotion >= parameters.settle { motionSince = time }
                lastMotion = time
            }
        } else {
            excludedRows = min(thumbnail.height, Int((parameters.excludedTopFraction * Double(thumbnail.height)).rounded(.up)))
        }
        latest = (frame, thumbnail, acceptedBefore)
        latestDone = false
        return evaluate(now: time)
    }

    /// 時間だけ進める。`idle` の通知と、通知が来ない間の定期の呼び出しで使う。
    public mutating func tick(at time: Double) -> Decision? {
        guard latest != nil else { return nil }
        clock = time
        releaseExclusion(now: time)
        return evaluate(now: time)
    }

    /// 「いま撮る」で公開した画像を比較の基準にする。受付の番号が今の基準より新しいときだけ替える。
    /// - 理由: 保留していた自動の画像を「いま撮る」で捨てたとき、捨てた画像が基準に残ると、画面がそれへ戻っても変化なしとなり記録できない
    /// - order: 押したときに自動の保存と同じロックの中で振った受付の番号
    /// - time: 公開した時刻。直近に公開した画面の、最後に見た時刻にする。省くと最後に受け取った時刻
    /// - 押したときより前の最新の観測は、以後の判定で使わない。押した後の観測は残す
    /// - 手動の画像も公開した画面なので、直近の画面に入れる。基準の新旧とは別に、最後に見た時刻だけで比べる
    public mutating func adopt(order: Int, thumbnail: ScreenThumbnail, at time: Double? = nil) {
        if confirmed.map({ $0.order < order }) ?? true { confirmed = (order, thumbnail) }
        // 観測までに受け付けた数が手動の番号以下なら、手動の受付より前に観測した。
        if let latest, latest.acceptedBefore <= order { latestDone = true }
        remember(thumbnail, order: order, at: time ?? clock, published: true)
    }

    /// 保存を決めたフレームを受け付けた。受付の番号を保存中の決定に結びつける。
    public mutating func accepted(frame: Int, order: Int) {
        guard let index = inFlight.firstIndex(where: { $0.frame == frame }) else { return }
        inFlight[index].order = order
    }

    /// 一時停止から再開した。観測と動きは数え直し、比較の基準は引き継ぐ。保存中の決定の結果も、この後に返れば基準に入る。
    /// - 理由: 一時停止の直前に公開した画面と再開の直後の画面が同じなら、同じ画面を2枚続けて残さない
    /// - 一時停止の前の最後の画面は、無音の間に保留していても一時停止の直前に公開される。基準はその画面と一致する
    /// - 直近に公開した画面も基準と同じく引き継ぐ。最後に見た時刻は一時停止の間も進むので、12秒より長い一時停止の後は比べない
    /// - 外すマスと動き始めた時刻は捨て、観測の世代を進める。一時停止の前に決めた動き続けて撮った1枚が再開の後に成功しても、外すマスは確定しない
    ///   - 理由: 再開の後の画面に、一時停止の前の動きで決めたマスを掛けないため
    public mutating func restart() {
        latest = nil; latestDone = false
        lastMotion = -Double.infinity
        generation += 1
        clearMovement()
    }

    /// 撮れない期間に入った。保留中のフレームを後から保存しない。保存中の決定の結果は、この後に返っても無視する。
    public mutating func reset() {
        latest = nil; latestDone = false; confirmed = nil; inFlight = []
        retryNotBefore = -Double.infinity; lastMotion = -Double.infinity
        generation += 1
        recent = []; latestMatches = []; recentExclusion = []
        clearMovement()
    }

    /// 保存を決めたフレームの画像を書けた。受付の番号が今の基準より新しいときだけ基準にする。
    /// - time: 直近の画面の最後に見た時刻と、外すマスを戻す時刻の起点。省くと保存を決めた時刻で、本体は省く
    ///   - 保存を決めた時刻にする理由: 結果が0.25〜1秒遅れて返る当て方で、試作の決定と食い違う数が書けた時刻より少なかった。
    ///     測った数は docs/screen-capture.md の「動き続ける画面」
    /// - outcome: その場で決まった行き先。保留した画像は、公開か破棄を受付の番号で後から知らせる
    ///   - 保留も比較の基準には入れる。保留した画面と同じ画面を続けて保存しないため
    public mutating func saveSucceeded(frame: Int, at time: Double? = nil, outcome: SaveOutcome = .published) {
        guard let index = inFlight.firstIndex(where: { $0.frame == frame }) else { return }
        let decided = inFlight.remove(at: index)
        if latest?.frame == frame { latestDone = true }
        let time = time ?? decided.decidedAt
        if outcome != .discarded {
            remember(decided.thumbnail, order: decided.order, at: time, published: outcome == .published)
            if let candidate = decided.exclusion, decided.generation == generation { applyExclusion(candidate, now: time) }
        }
        guard let order = decided.order else { return }
        if confirmed.map({ $0.order < order }) ?? true { confirmed = (order, decided.thumbnail) }
    }

    /// 保存を決めたフレームの画像を書けなかった。その決定を捨て、`retryInterval` 秒は次の保存を決めない。
    /// 外すマスの候補も捨てる。動き続けて撮る決定なら、再試行の時刻にすぐ試せるよう、動き始めた時刻を戻す。
    public mutating func saveFailed(frame: Int, at time: Double) {
        guard let index = inFlight.firstIndex(where: { $0.frame == frame }) else { return }
        let decided = inFlight.remove(at: index)
        retryNotBefore = time + parameters.retryInterval
        if decided.reason == .moving, decided.generation == generation { motionSince = retryNotBefore - parameters.movingSeconds }
    }

    /// 保留していた自動の画像を公開した。受付の番号で知らせる。以後は直近の画面として比べる。
    /// 知らせるのは、保存の結果を `held` で返した画像だけ。結果より後に届く。
    /// 知らない番号は、対象を替えて判定器を作り直す前の画像か、範囲を出て捨てた画像なので、何もしない。
    public mutating func published(order: Int) {
        guard let index = recent.firstIndex(where: { $0.order == order }) else { return }
        recent[index].published = true
    }

    /// 保留していた自動の画像を、公開せずに捨てた。受付の番号で知らせる。直近の画面から抜き、その画面へ戻ったら撮れるようにする。
    /// 知らせるのは、保存の結果を `held` で返した画像だけ。届いた時点で捨てた画像は、結果の `discarded` で受け取る。
    public mutating func discarded(order: Int) {
        recent.removeAll { $0.order == order && !$0.published }
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
        guard let latest else { return nil }
        updateRecent(now: now, thumbnail: latest.thumbnail)
        // 保存中の観測と、保存に成功した観測は、同じ観測のうちはもう一度決めない。見分けはフレームの番号で行う。
        guard now >= retryNotBefore, !latestDone,
              !inFlight.contains(where: { $0.frame == latest.frame }) else { return nil }
        guard let baseline else { return decide(latest, now: now, reason: .first, exclusion: nil) }
        if now - lastMotion >= parameters.settle {
            guard changedFraction(baseline, latest.thumbnail, excluding: exclusion) > parameters.save, !seenRecently else { return nil }
            return decide(latest, now: now, reason: .settled, exclusion: nil)
        }
        // 動き続けている。動き始めてから movingSeconds 秒たったら、その時点の1枚を試す。
        guard parameters.movingSeconds > 0, now - motionSince >= parameters.movingSeconds else { return nil }
        motionSince = now
        // 比べるのは今の外すマスでの基準。候補のマスで比べると、全画面の動画が丸ごと外れて保存しない。
        guard changedFraction(baseline, latest.thumbnail, excluding: exclusion) > parameters.save, !seenRecently else { return nil }
        return decide(latest, now: now, reason: .moving, exclusion: exclusionCandidate(now: now, thumbnail: latest.thumbnail))
    }

    private mutating func decide(_ latest: (frame: Int, thumbnail: ScreenThumbnail, acceptedBefore: Int), now: Double,
                                 reason: Decision.Reason, exclusion candidate: [Bool]?) -> Decision {
        inFlight.append(InFlight(frame: latest.frame, order: nil, thumbnail: latest.thumbnail, reason: reason,
                                 decidedAt: now, exclusion: candidate, generation: generation))
        return Decision(frame: latest.frame, reason: reason)
    }

    // MARK: - 直近に公開した画面

    /// 最新の観測と同じ画面を、今の外すマスで求め直し、見ている間は最後に見た時刻を延ばす。
    /// 外すマスは観測の間にも戻るので、観測ごとではなく判定ごとに求める。
    /// - 走査するのは、最後に見た時刻で範囲に残る画面の全部。最大64件。保存した時刻ではなく最後に見た時刻で保つので、
    ///   直近12秒に1枚も保存していなくても、見続けて延ばした画面は残る
    /// - 保留中の画像も走査し、見ている間は延ばす。保存を止める所(`seenRecently`)でだけ公開の状態を見る
    private mutating func updateRecent(now: Double, thumbnail: ScreenThumbnail) {
        guard parameters.recentSeconds > 0 else { return }
        // 範囲の外へ出た画面は、二度と範囲へ戻らない。最後に見た時刻は範囲の中でだけ延ばすため。
        recent.removeAll { now - $0.lastSeen > parameters.recentSeconds }
        recentExclusion = recentExclusionUsable(for: thumbnail) ? exclusion : []
        latestMatches = Set(recent.filter { same($0.thumbnail, thumbnail) }.map(\.id))
        for index in recent.indices where latestMatches.contains(recent[index].id) { recent[index].lastSeen = now }
    }

    /// 最新の観測が、範囲の中の公開した画面と同じ。
    private var seenRecently: Bool {
        parameters.recentSeconds > 0 && recent.contains { $0.published && latestMatches.contains($0.id) }
    }

    private mutating func remember(_ thumbnail: ScreenThumbnail, order: Int?, at time: Double, published: Bool) {
        guard parameters.recentSeconds > 0 else { return }
        recent.append(Seen(id: nextSeenID, order: order, thumbnail: thumbnail, lastSeen: time, published: published))
        if let latest, same(thumbnail, latest.thumbnail) { latestMatches.insert(nextSeenID) }
        nextSeenID += 1
        recent.sort { $0.lastSeen > $1.lastSeen }
        recent.removeAll { time - $0.lastSeen > parameters.recentSeconds }
        // 範囲は秒で絞る。並んだ画面を数で絞らないが、際限なく持たないよう上限を置く。
        if recent.count > 64 { recent.removeLast(recent.count - 64) }
    }

    /// 直近の画面との「同じ」。外すマスを除いたマスの輝度の差が全て `cellDelta` 以下。
    private func same(_ a: ScreenThumbnail, _ b: ScreenThumbnail) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        for cell in considered(b) where (recentExclusion.isEmpty || !recentExclusion[cell]) && changed(a.luma[cell], b.luma[cell]) { return false }
        return true
    }

    /// 外しているマスが、比較に使うマスの `recentExcludeLimit` 以下か。
    private func recentExclusionUsable(for thumbnail: ScreenThumbnail) -> Bool {
        guard parameters.recentExcludeLimit > 0, exclusion.count == thumbnail.luma.count else { return false }
        let range = considered(thumbnail)
        guard !range.isEmpty else { return false }
        let masked = range.reduce(0) { $0 + (exclusion[$1] ? 1 : 0) }
        return masked > 0 && Double(masked) / Double(range.count) <= parameters.recentExcludeLimit
    }

    // MARK: - 動き続ける画面

    private mutating func clearMovement() {
        motionSince = -Double.infinity; movements = []
        excludedRegion = []; regionLastChange = []; exclusion = []
        latestMatches = []; recentExclusion = []
    }

    /// 直前の観測から変わったマスを覚える。外しているマスが変わったら、そのつながりの最後に変わった時刻を進める。
    private mutating func recordMovement(from previous: ScreenThumbnail, to thumbnail: ScreenThumbnail, at time: Double) {
        var cells: [Int32] = []
        for cell in considered(thumbnail) where changed(previous.luma[cell], thumbnail.luma[cell]) {
            cells.append(Int32(cell))
            if !excludedRegion.isEmpty, excludedRegion[cell] >= 0 { regionLastChange[excludedRegion[cell]] = time }
        }
        movements.append((time, cells))
        movements.removeAll { $0.time < time - parameters.excludeWindow }
    }

    /// 外したマスを、つながりごとに `excludeRelease` 秒変わらなければ戻す。
    private mutating func releaseExclusion(now: Double) {
        guard !excludedRegion.isEmpty else { return }
        var released = false
        for region in regionLastChange.indices where regionLastChange[region].isFinite && now - regionLastChange[region] >= parameters.excludeRelease {
            regionLastChange[region] = -Double.infinity
            released = true
        }
        guard released else { return }
        for cell in excludedRegion.indices where excludedRegion[cell] >= 0 && !regionLastChange[excludedRegion[cell]].isFinite {
            excludedRegion[cell] = -1
        }
        if excludedRegion.contains(where: { $0 >= 0 }) {
            exclusion = excludedRegion.map { $0 >= 0 }
        } else {
            excludedRegion = []; regionLastChange = []; exclusion = []
        }
    }

    /// 判定の時刻から直近 `excludeWindow` 秒に1回でも変わったマスを、`excludeGrow` マス広げ、つながりごとに外接する長方形まで埋める。
    /// 前に外していたマスは引き継がず、決め直す。引き継ぐと、送る前のスライドの動く画像の位置が、次のスライドでも外れ続ける。
    private func exclusionCandidate(now: Double, thumbnail: ScreenThumbnail) -> [Bool]? {
        let width = thumbnail.width, height = thumbnail.height
        var counted = [Bool](repeating: false, count: width * height)
        for movement in movements where movement.time >= now - parameters.excludeWindow {
            for cell in movement.cells { counted[Int(cell)] = true }
        }
        var mask = [Bool](repeating: false, count: width * height)
        var any = false
        let grow = parameters.excludeGrow
        for cell in considered(thumbnail) where counted[cell] {
            any = true
            let x = cell % width, y = cell / width
            for dy in -grow...grow { for dx in -grow...grow {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < width, ny >= excludedRows, ny < height else { continue }
                mask[ny * width + nx] = true
            } }
        }
        return any ? Self.boxes(mask, width: width, height: height) : nil
    }

    /// 外すマスを確定する。つながりごとの最後に変わった時刻は、保存を決めた時刻から始める。
    /// 保存を決めてから成功が届くまでに観測した変化は、まだ外していないので `recordMovement` で時刻を進めていない。
    /// その間の変化を、つながりごとに引き継ぐ。引き継がないと、成功の直前まで動いていたつながりを、決めた時刻から3秒で戻してしまう。
    /// - now: 保存を決めた時刻
    private mutating func applyExclusion(_ mask: [Bool], now: Double) {
        guard let latest, mask.count == latest.thumbnail.luma.count else { return }
        let (labels, count) = Self.label(mask, width: latest.thumbnail.width, height: latest.thumbnail.height)
        excludedRegion = labels
        regionLastChange = Array(repeating: now, count: count)
        for movement in movements where movement.time > now {
            for cell in movement.cells where labels[Int(cell)] >= 0 {
                regionLastChange[labels[Int(cell)]] = max(regionLastChange[labels[Int(cell)]], movement.time)
            }
        }
        exclusion = labels.map { $0 >= 0 }
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

    /// つながったマスごとに、外接する長方形を埋める。埋めた長方形どうしが重なれば、もう一度つなぐ。
    /// 動く画像は長方形なので、玉が跳ねるだけの絵でも枠ごと外せる。
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

    // MARK: - 比べ方

    private func considered(_ thumbnail: ScreenThumbnail) -> Range<Int> { (excludedRows * thumbnail.width)..<(thumbnail.width * thumbnail.height) }

    private func changed(_ a: UInt8, _ b: UInt8) -> Bool { abs(Int(a) - Int(b)) > parameters.cellDelta }

    /// 比較に使うマスのうち、変わったマスの割合。外したマスも分母に残し、外すほど小さくなる。
    private func changedFraction(_ a: ScreenThumbnail, _ b: ScreenThumbnail, excluding mask: [Bool] = []) -> Double {
        // 「いま撮る」で受け取った基準は寸法が違いうる。比べられなければ全部変わったとみなす。
        guard a.width == b.width, a.height == b.height else { return 1 }
        let range = considered(b)
        guard !range.isEmpty else { return 0 }
        let masked = mask.count == b.luma.count
        var count = 0
        for cell in range where !(masked && mask[cell]) && changed(a.luma[cell], b.luma[cell]) { count += 1 }
        return Double(count) / Double(range.count)
    }
}
