import AppKit
import CoreMedia
import KikigakiCore
import ScreenCaptureKit
import VideoToolbox

/// 開始シートで選べるディスプレイ。番号は再起動で変わりうるので、前回の選択は名前で覚える。
struct ScreenDisplay: Equatable {
    let id: CGDirectDisplayID
    let name: String
    let points: CGSize
    /// メニューバーの高さの、画面の高さに対する割合。メニューバーの無いディスプレイは0。
    let menuBarFraction: Double

    static func connected() -> [ScreenDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  screen.frame.height > 0 else { return nil }
            return ScreenDisplay(id: CGDirectDisplayID(number.uint32Value), name: screen.localizedName, points: screen.frame.size,
                                 menuBarFraction: max(0, screen.frame.maxY - screen.visibleFrame.maxY) / screen.frame.height)
        }
    }
}

/// 保存を決めた1枚。時刻は観測した時点で固定し、保存を決めた時刻や保存が終わった時刻を使わない。
struct ScreenShot {
    let image: CGImage
    let audioTime: Double
    let observedAt: Date
    let label: String
    /// 自動の判定で決めたときのフレーム番号。「いま撮る」はnil。
    let frame: Int?
    /// 受付の番号。自動も「いま撮る」も、受け付けるときに同じロックの中で1つ取る。受け付けるまではnil。
    /// 新旧の順序はこの番号だけで比べる。保留の破棄の境界、判定器の比較の基準の新旧、行の挿入位置のどれも同じ。
    var order: Int?
    /// 撮った対象の世代。録音中に対象を替えるたびに増える。替える前の画像を、替えた後の判定器の基準にしないため。
    var target: Int
}

/// 1つの会議の画面の記録。SCStreamを1x寸法・1秒間隔で開き、判定・WebP保存・公開の依頼までを持つ。
/// 仕様は [画面の記録](docs/screen-capture.md) の「撮影と保存」と「録音中の切り替え」
///
/// 録音できる会議ごとに1つ作り、撮る対象は録音中に `retarget` で替える。撮らない会議でも作り、対象をnilにしておく。
/// - 理由: 受付の番号・受け付けた数・まだ届いていない数を会議の中で1本に保つ。替える前に受け付けた保存も、
///   同じ番号の列で境界・行の位置が決まり、替えた後に届いても公開できる
///
/// 撮るかどうかは、MainActorの操作が `lock` の下で即座に切り替える(撮影中かと世代)。
/// - 一時停止・停止・取得不能・対象の切り替えは、ストリームの片付けを待たずに撮影を止める。片付けは後から順に流す
/// - 判定とフレームは `queue` で扱い、世代が変わっていたら判定器の観測を数え直してから読む。比較の基準は引き継ぐ
/// - 符号化と書き込みは `encodeQueue`。結果は成功も失敗も `DispatchQueue.main` の1本で順に返し、公開の可否はMainActorの `publish` が決める
///   - 無音の間の画面は、書き込みまで済ませてからMainActorが保留する。公開の契機で同期に出せるようにするため。
///     この型は保留を持たず、保留を受け付けたことを `held` として受け取る。保留の公開と破棄は `heldScreen(order:published:)` で受け取り、判定器へ渡す
///     - 判定器は、保留も比較の基準に入れ、直近に公開した画面として比べるのは公開を知らせた後だけにする
/// - 停止は `stopAccepting` で新しい保存を止め、`drain` で受付済みの処理を待ち、`invalidate` で残りを無効にする
///
/// 順序の物差しは受付の番号1本にそろえる。
/// - 受付の番号: 自動の保存も「いま撮る」も、`begin` の同じロックの中で単調に増える番号を1つ取る。受付の確認と番号の取得の間に、別の受付は挟まらない
/// - 使う所: 保留の破棄と公開の境界(`ScreenSilenceHold`)、判定器の比較の基準の新旧(`ScreenChangeDetector`)、行の挿入位置(`MeetingSession`)。どれもこの番号で比べる
/// - フレームの番号は、判定器の中で観測を見分けるためだけに使う。新旧の比較には使わない
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// 公開の結果。その場で決まった行き先で、判定器へは保存の結果と一緒に1回で渡す。
    /// - published: その場で行を足した
    /// - held: 無音の間なので保留へ入れた。公開か破棄は、後から `heldScreen(order:published:)` で受付の番号で知らせる
    /// - discarded: 届いた時点で、公開せずに捨てた。画像は捨てた側が片付けた。保存の失敗とは分ける
    /// - rejected: 公開を拒んだ。書いた画像は消し、判定器へは保存の失敗として返す
    enum PublishResult { case published, held, discarded, rejected }

    let queue = DispatchQueue(label: "kikigaki.screen.capture")
    private let encodeQueue = DispatchQueue(label: "kikigaki.screen.encode")
    private let lock = NSLock()
    private let capturesDirectory: URL
    /// 受け付けた音声の位置。音声スレッドと共有する一時停止フラグから読む。
    private let acceptedAudioTime: @Sendable () -> Double
    /// MainActorで公開の可否を決め、行を足す。rejectedなら書いた画像を `discardUnpublished` へ渡す。
    private let publish: @MainActor (ScreenRecorder, ScreenShot, URL) -> PublishResult
    /// 公開しなかった画像を消す。保留の破棄と同じ削除と消し直しへ渡す。停止の期限を超えた保存と、無効にした後の保存も通る。
    private let discardUnpublished: @MainActor (URL) -> Void
    private let failed: @MainActor (ScreenRecorder, String) -> Void
    /// 撮れなくなった。Int: 撮れなくなった対象の世代。いまの対象かは受け取った側が `ScreenTarget` で決める。
    private let becameUnavailable: @MainActor (ScreenRecorder, String, Int) -> Void
    /// 撮影を始められた。許可とディスプレイを確かめ、ストリームを開く直前にMainActorで呼ぶ。撮影の世代が今のときだけ。
    /// Int: 始めた対象の世代。
    private let started: @MainActor (ScreenRecorder, Int) -> Void
    /// その対象の世代がいまの対象か。判定は `ScreenTarget` の1か所に置き、この型は世代を運ぶだけにする。
    private let isCurrentTarget: @MainActor (Int) -> Bool

    // queue上だけで触る
    /// 判定器へ渡す今の時刻。保存の結果・失敗・定期の判定で読む。観測の時刻はフレームの `displayTime` から求める。
    private var clock: () -> Date = { Date() }
    private var detector = ScreenChangeDetector()
    private var seenEpoch = 0
    /// 判定器を作った対象の世代。替わっていたら比較の基準を引き継がずに作り直す。
    private var seenTarget = 0
    private var frameIndex = 0
    private var latest: ScreenShot?
    private var stream: SCStream?
    /// ストリームとタイマーを開いた世代。今の世代と一致する通知だけを判定へ渡す。
    private var streamEpoch = 0
    /// ストリームを開いた対象。題と失敗の文言に使う。
    private var streamDisplay: ScreenDisplay?
    private var timer: DispatchSourceTimer?

    /// 開いたストリームの対象の世代と、「いま撮る」の撮影に要るフィルタ。ストリームを準備し終えてから持ち、閉じたら消す。
    /// 「いま撮る」は受け付けた時点でこれを要求へ写し、以後は共有の状態を読まない。
    struct CaptureSource {
        let target: Int
        /// 検証でストリームを開かないときはnil。
        let filter: SCContentFilter?
    }

    // lockで守る
    private var accepting = true
    private var invalidated = false
    private var capturing = false
    private var epoch = 0
    /// 撮る対象。nilは撮らない。
    private var target: ScreenDisplay?
    /// 対象の世代。`retarget` で `ScreenTarget` の世代を受け取る。判定器・フィルタ・知らせに添えて運ぶ。
    private var targetGeneration = 0
    /// 撮影に要るもの。取得不能の片付けは、この世代のストリームだけを閉じる。
    private var source: CaptureSource?
    private var pending = 0
    /// 受け付けた保存の数。自動と「いま撮る」を合わせ、次に振る受付の番号でもある。
    private var accepted = 0
    /// 受け付けて、結果がまだMainActorへ届いていない自動の保存の数。
    private var automaticPending = 0
    private var reportedUnavailable = false

    init(markdownURL: URL, acceptedAudioTime: @escaping @Sendable () -> Double,
         publish: @escaping @MainActor (ScreenRecorder, ScreenShot, URL) -> PublishResult,
         discardUnpublished: @escaping @MainActor (URL) -> Void,
         failed: @escaping @MainActor (ScreenRecorder, String) -> Void,
         becameUnavailable: @escaping @MainActor (ScreenRecorder, String, Int) -> Void,
         started: @escaping @MainActor (ScreenRecorder, Int) -> Void,
         isCurrentTarget: @escaping @MainActor (Int) -> Bool) {
        capturesDirectory = ScreenCaptureFiles.directory(for: markdownURL)
        self.acceptedAudioTime = acceptedAudioTime
        self.publish = publish; self.discardUnpublished = discardUnpublished
        self.failed = failed; self.becameUnavailable = becameUnavailable
        self.started = started; self.isCurrentTarget = isCurrentTarget
    }

    private static func detector(for display: ScreenDisplay?) -> ScreenChangeDetector {
        var parameters = ScreenChangeParameters()
        parameters.excludedTopFraction = display?.menuBarFraction ?? 0
        return ScreenChangeDetector(parameters: parameters)
    }

    var isInvalidated: Bool { lock.withLock { invalidated } }
    /// 受け付けたが、結果がまだMainActorへ届いていない自動の保存があるか。
    var hasAutomaticSavesInFlight: Bool { lock.withLock { automaticPending > 0 } }
    /// これまでに受け付けた保存の数。自動と「いま撮る」を合わせる。境界はこの数で引き、受付の番号がこれより小さい保存を境界より前とする。
    /// 一時停止・停止・取得不能の後に読めば、境界より前の受付は全部数え終えている。撮影を止めた時点で新しい受付は無い。
    var savesAccepted: Int { lock.withLock { accepted } }
    /// 受け付けて、まだ公開か失敗まで終えていない保存があるか。自動と「いま撮る」を合わせる。
    var hasSavesInFlight: Bool { lock.withLock { pending > 0 } }
    /// 取得不能を知らせた後は、再開でもストリームを開き直さない。再接続しても追わない。
    var isUnavailable: Bool { lock.withLock { reportedUnavailable } }

    // MARK: - 撮影の切替(MainActorから同期で呼ぶ)

    /// 撮影を始める。開始の直後の1枚は最初の1枚として撮る。再開の直後の1枚は、一時停止の前の比較の基準と違えば待たずに撮る。
    /// 返した世代を `start` へ渡す。
    func resumeCapturing() -> Int {
        lock.withLock {
            epoch += 1
            capturing = accepting && !invalidated && !reportedUnavailable && target != nil
            return epoch
        }
    }

    /// 撮る対象を替える。録音中の切り替えの入口で、いまの撮影をその場で止め、新しい対象で始め直す。
    /// - display: nilなら撮らない
    /// - generation: `ScreenTarget` が振った対象の世代
    /// - capture: すぐ撮り始めるか。一時停止中はfalseにし、再開の `resumeCapturing` で始める
    /// - 返す値: 撮り始めるなら、`start` へ渡す撮影の世代
    ///
    /// 替える前に受け付けた保存は無効にしない。公開まで続け、受付の番号の順に並ぶ。
    /// 撮れなくなった後でも、選び直せば撮り直す。判定器は次の観測で作り直し、比較の基準を引き継がない。
    func retarget(_ display: ScreenDisplay?, generation: Int, capture: Bool) -> Int? {
        lock.withLock {
            epoch += 1
            target = display
            targetGeneration = generation
            reportedUnavailable = false
            capturing = capture && display != nil && accepting && !invalidated
            return capturing ? epoch : nil
        }
    }

    /// 一時停止。この時点から撮らない。ストリームの片付けは `closeStream` で後から行う。
    func pauseCapturing() {
        lock.withLock { epoch += 1; capturing = false }
    }

    /// 新しい保存の決定を止める。受付済みの処理は続ける。
    func stopAccepting() {
        lock.withLock { epoch += 1; capturing = false; accepting = false }
    }

    /// 以後に公開を依頼された処理は弾かれ、書いた画像は消える。受付済みの「いま撮る」も撮影を始めない。
    /// 無効の確定はMainActorで行う。「いま撮る」の確認から撮影APIの呼び出しまでの区間へ割り込ませないため。
    @MainActor func invalidate() {
        lock.withLock { epoch += 1; capturing = false; accepting = false; invalidated = true }
    }

    /// 受付済みの処理が公開まで終わるのを待つ。上限を超えたら残りを無効にする。期限は単調時計で測る。
    /// 期限内は無効にしないので、受付済みの「いま撮る」は撮影できるまま保つ。
    @MainActor func drain(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while lock.withLock({ pending > 0 }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        invalidate()
    }

    private func isCurrent(_ value: Int) -> Bool { lock.withLock { capturing && epoch == value } }

    /// 今の世代の撮る対象と、その対象の世代。撮影中でなければnil。
    private func current(_ value: Int) -> (display: ScreenDisplay, generation: Int)? {
        lock.withLock {
            guard capturing, epoch == value, let target else { return nil }
            return (target, targetGeneration)
        }
    }

    /// 今の撮影の世代なら、MainActorで撮影を始められたと知らせる。世代の確認と知らせを同じMainActorの番で行う。
    private func announceStarted(epoch value: Int, target generation: Int) async -> Bool {
        await MainActor.run {
            guard isCurrent(value) else { return false }
            started(self, generation)
            return true
        }
    }

    // MARK: - ストリーム

    /// 撮れる状態か確かめてストリームを開く。撮れなければ取得不能として知らせる。
    /// 待っている間に一時停止・停止・取得不能・切り替えで世代が変わったら、開かずに戻る。
    /// 許可は `CGPreflightScreenCaptureAccess` で決めない。許可した直後の同じプロセスでは古い値を返す。
    /// 許可とディスプレイを確かめ、ストリームとフィルタを準備し終えたら、ストリームを動かす前に `started` で知らせる。
    /// - 理由: 知らせた時点で「いま撮る」に要るものが揃っている。動かした直後に届く最初の1枚より前に、`記録を再開` の行とフッターの表示を置く
    /// - 一時停止からの再開も同じ順で知らせる。閉じたストリームを準備し直している間は「いま撮る」を出さない
    func start(epoch value: Int) async {
        guard let (display, generation) = current(value) else { return }
#if DEBUG
        if let fake = startForTesting {
            if let reason = fake(display) { reportUnavailable(reason, epoch: value); return }
            // ストリームの代わりに、撮影に要るものだけを準備する。閉じ方と「いま撮る」の確かめ方を本番と同じにする。
            queue.sync { streamEpoch = value; streamDisplay = display; lock.withLock { source = CaptureSource(target: generation, filter: nil) } }
            if !(await announceStarted(epoch: value, target: generation)) { queue.sync { clearStream(target: generation) } }
            return
        }
#endif
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            // 一覧に出して許可しやすくするため、未許可なら一度だけ確認を求める。
            if isCurrent(value), !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            reportUnavailable("「画面収録」の許可がありません", epoch: value)
            return
        }
        guard isCurrent(value) else { return }
        guard let target = content.displays.first(where: { $0.displayID == display.id }) else {
            reportUnavailable("ディスプレイ「\(display.name)」が見つかりません", epoch: value)
            return
        }
        // KIKIGAKI自身は撮影と変化の検知から外す。書き起こしの更新を「変化」にしないため。
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: target, excludingApplications: own, exceptingWindows: [])
        let config = Self.configuration(display)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        // 最初のフレームは開始の直後に届き、静止した画面ではその後idleしか来ない。受け取る準備を開始より先に済ませる。
        queue.sync {
            self.stream = stream
            streamEpoch = value
            streamDisplay = display
            lock.withLock { source = CaptureSource(target: generation, filter: filter) }
            startTimer()
        }
        // 撮影に要るものが揃ってから知らせる。待つ間に一時停止・停止・切り替えたら、動かさずに外す。
        guard await announceStarted(epoch: value, target: generation) else {
            _ = queue.sync { detach(stream) }
            return
        }
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            _ = queue.sync { detach(stream) }
            // 開始を待つ間に世代が変わっていれば、古い開始の失敗として片付けるだけにする。
            reportUnavailable("画面の取得を始められません", epoch: value)
            return
        }
        // 開いている間に一時停止・停止したら、開いたストリームをすぐ閉じる。
        if !isCurrent(value), queue.sync(execute: { detach(stream) }) { try? await stream.stopCapture() }
    }

    /// ストリームとタイマーを片付ける。撮影はその前に `pauseCapturing` などで止まっている。
    /// - target: その対象の世代で開いたストリームだけを閉じる。取得不能の片付けで使う。
    ///   撮れなくなった知らせが届く前に別の対象を選ぶと、その間に開いた新しいストリームを閉じないため。nilなら今のものを閉じる
    func closeStream(target: Int? = nil) async {
        let stream: SCStream? = queue.sync {
            let stream = self.stream
            return clearStream(target: target) ? stream : nil
        }
        try? await stream?.stopCapture()
    }

    /// queue上で、今のストリームなら外す。外したらtrue。
    private func detach(_ stream: SCStream) -> Bool {
        guard self.stream === stream else { return false }
        return clearStream(target: nil)
    }

    /// queue上で、ストリーム・タイマー・撮影に要るものを一緒に外す。外したらtrue。
    /// - target: その対象の世代で開いたものだけを外す。nilなら今のものを外す
    /// 受付済みの「いま撮る」は、受け付けた時点で要るものを写しているので、外しても撮れる。
    @discardableResult
    private func clearStream(target: Int?) -> Bool {
        let cleared: Bool = lock.withLock {
            // ストリームと撮影に要るものは同じqueue.syncの中で一緒に置くので、`source` を見れば開いた世代が分かる。
            guard let opened = source?.target, target.map({ $0 == opened }) ?? true else { return false }
            source = nil
            return true
        }
        guard cleared else { return false }
        timer?.cancel(); timer = nil
        stream = nil
        return true
    }

    private static func configuration(_ display: ScreenDisplay) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        // 1x寸法。Retinaでは半分に縮めて受け取る。文字が読める解像度で、画像トークンとディスクを抑える。
        config.width = Int(display.points.width)
        config.height = Int(display.points.height)
        config.captureResolution = .nominal
        config.scalesToFit = true
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }

    // MARK: - いま撮る

    /// 「いま撮る」の受付。押した処理の中で同期に呼び、時刻・音声位置・題と受付をその時点で確定する。
    struct CaptureRequest {
        let pressedAt: Date
        let audioTime: Double
        let display: ScreenDisplay
        let label: String
        /// 受付の番号。自動の保存と同じロックの中で取る。
        let order: Int
        /// 押したときの対象の世代。
        let target: Int
        /// 押したときの対象のフィルタ。受け付けた時点で写し、撮影はこれで行う。一時停止でストリームを閉じても撮れる。
        let filter: SCContentFilter?

        func shot(_ image: CGImage) -> ScreenShot {
            ScreenShot(image: image, audioTime: audioTime, observedAt: pressedAt, label: label, frame: nil, order: order, target: target)
        }
    }

    /// 撮影中で、いまの対象の撮影に要るものが揃っているか。「いま撮る」を出せるのはこの間だけ。
    var canCaptureNow: Bool {
        lock.withLock { capturing && !reportedUnavailable && target != nil && source?.target == targetGeneration }
    }

    /// 押した時点で処理を受け付け、停止のときに公開まで待つ対象にする。撮影中でないか、撮影に要るものが揃っていなければnil。
    /// 押した時点の対象の世代とフィルタを要求へ写す。以後は共有の状態を読まない。
    /// 時刻の例外: 音声位置と実時刻は押した時点に置く。`captureImage` は観測した時刻を返さないため。
    /// 新旧の順序は受付の番号で決める。完了した時点では決めない。
    func beginCapture() -> CaptureRequest? {
        let pressedAt = Date()
        let audioTime = acceptedAudioTime()
        let (value, display, generation, source) = lock.withLock { (epoch, target, targetGeneration, self.source) }
        guard let display, let source, source.target == generation,
              let order = begin(epoch: value, automatic: false) else { return nil }
        return CaptureRequest(pressedAt: pressedAt, audioTime: audioTime, display: display, label: Self.label(display: display),
                              order: order, target: generation, filter: source.filter)
    }

    /// 受け付けた「いま撮る」の1枚を撮り、しきい値によらず保存する。結果は `complete` が必ず1回返す。
    /// MainActorの中断の無い1区間で、押した対象がいまの対象かを `ScreenTarget` で確かめてから撮影APIを呼ぶ。
    /// 対象の切り替えはMainActorで行うので、確かめた後・撮影を始める前に切り替えが挟まらない。
    /// - 押した後に替えた・切った、記録を無効にした(停止の待ちの期限切れ・会議の切替)なら、撮らずに失敗として終える
    /// - 一時停止だけなら対象の世代は変わらないので、要求が持つフィルタで撮る。閉じたストリームの共有の状態は読まない
    /// - 撮影を始めた後・保存を待っている画像は、この後に替えても公開する。利用者が押した時点に映していた画面のため
    @MainActor func capture(_ request: CaptureRequest) async {
        let fail = { self.complete(frame: nil, result: .failure("いま撮るの撮影に失敗しました")) }
        // ここから撮影APIの呼び出しまで中断しない。無効の確定と対象の切り替えはどちらもMainActorなので割り込まない。
        // 無効を先に見る。会議を替えると `ScreenTarget` の世代は振り直すので、古い記録の要求が同じ番号で世代の確認を通りうる。
        guard !isInvalidated, isCurrentTarget(request.target) else { fail(); return }
#if DEBUG
        if let shoot = screenshotForTesting {
            if let image = shoot(request.display) { save(request.shot(image)) } else { fail() }
            return
        }
#endif
        guard let filter = request.filter else { fail(); return }
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: Self.configuration(request.display))
            save(request.shot(image))
        } catch {
            fail()
        }
    }

    // MARK: - フレーム

    /// queue上で世代を読む。変わっていたら判定器の観測を数え直す。撮影中ならtrue。
    /// - source: 通知元のストリームを開いた世代。今の世代と違えば、古いストリームの通知として捨てる
    /// - 世代が変わるのは一時停止と再開、停止、取得不能、対象の切り替え
    ///   - 一時停止と再開: 撮り直す対象は同じなので、比較の基準は引き継ぐ
    ///   - 対象の切り替え: 判定器を作り直し、比較の基準を引き継がない。替えた先の最初の1枚は、録音の開始と同じく待たずに撮る
    ///     - 理由: 替える前の画面と比べると、替えた先がたまたま似ていたときに撮らない。メニューバーの高さも対象ごとに違う
    ///     - 替える前に決めた保存の結果は、新しい判定器では見つからず無視される
    private func syncEpoch(source: Int? = nil) -> Bool {
        refreshTarget()
        let (current, value) = lock.withLock { (capturing, epoch) }
        if value != seenEpoch {
            seenEpoch = value
            detector.restart()
            latest = nil
        }
        return current && (source.map { $0 == value } ?? true)
    }

    /// queue上で、対象が替わっていたら判定器を作り直す。
    private func refreshTarget() {
        let (display, generation) = lock.withLock { (target, targetGeneration) }
        guard generation != seenTarget else { return }
        seenTarget = generation
        detector = Self.detector(for: display)
        latest = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, stream === self.stream, syncEpoch(source: streamEpoch), let display = streamDisplay,
              let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = attachments[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        let now = Date()
        switch status {
        case .complete:
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
            guard let image else { return }
            // 題の候補は画像と同じフレームを受け取った時点で取る。保存を決めた時点で取ると、別の資料の題が付きうる。
            observe(image, observedAt: Self.date(of: attachments[.displayTime] as? UInt64, now: now), now: now,
                    label: Self.label(display: display))
        case .idle:
            if let decision = detector.tick(at: Self.monotonic(now)) { decide(decision) }
        case .blank, .suspended, .stopped:
            reportUnavailable("画面を取得できなくなりました", epoch: streamEpoch)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [self] in
            let opened = streamEpoch, name = streamDisplay?.name ?? ""
            guard detach(stream) else { return }
            reportUnavailable("ディスプレイ「\(name)」を取得できなくなりました", epoch: opened)
        }
    }

    /// queue上で、観測した1枚を判定へ渡す。
    private func observe(_ image: CGImage, observedAt: Date, now: Date, label: String) {
        guard let thumbnail = Self.thumbnail(image, width: detector.parameters.thumbnailWidth) else { return }
        let audioTime = ScreenCaptureClock.audioTime(acceptedAudioTime: acceptedAudioTime(), now: now, observedAt: observedAt)
        let shot = ScreenShot(image: image, audioTime: audioTime, observedAt: observedAt, label: label, frame: frameIndex, target: seenTarget)
        latest = shot
        // 観測の前後を「いま撮る」と比べるため、ここまでに受け付けた保存の数を受付と同じロックで読む。
        // 読むのはフレームを受け取って処理する時点。その間に押した「いま撮る」より後の観測とみなされ、使い終えずに残る側へ倒れる。
        let acceptedBefore = lock.withLock { accepted }
        let decision = detector.observe(frame: frameIndex, at: Self.monotonic(observedAt), thumbnail: thumbnail, acceptedBefore: acceptedBefore)
        frameIndex += 1
        if let decision { decide(decision) }
    }

#if DEBUG
    /// ストリームを開かずに、観測した1枚を同じ経路で判定へ渡す。
    func observeForTesting(_ image: CGImage, observedAt: Date = Date(), label: String) {
        queue.sync { if syncEpoch() { observe(image, observedAt: observedAt, now: Date(), label: label) } }
    }
    /// 新しい観測なしに時間だけ進める。`idle` の通知とタイマーと同じ経路で判定する。
    func tickForTesting(at date: Date) {
        queue.sync { if syncEpoch(), let decision = detector.tick(at: Self.monotonic(date)) { decide(decision) } }
    }
    func reportUnavailableForTesting(_ reason: String, epoch value: Int? = nil) {
        reportUnavailable(reason, epoch: value ?? lock.withLock { epoch })
    }
    var pendingForTesting: Int { lock.withLock { pending } }
    /// 受け付けた「いま撮る」を、撮影を終えた画像として保存の経路へ渡す。撮影を始める時点の確認は通らない。
    /// 撮影済みで保存を待つ画像の扱いと、完了を遅らせる検証で使う。撮影を始める時点の確認は `capture(_:)` と `screenshotForTesting` で確かめる。
    func deliverCapturedForTesting(_ request: CaptureRequest, image: CGImage) {
        save(request.shot(image))
    }
    /// 設定すると、`start` はScreenCaptureKitに触れずにこれを呼ぶ。nilを返せば撮影を始められた、文字列なら取得不能の理由。
    /// 画面収録の許可の確認を検証から起こさないため。
    var startForTesting: ((ScreenDisplay) -> String?)?
    /// 設定すると、`capture(_:)` は撮影を始める時点の確認を通った後、ScreenCaptureKitの代わりにこれで撮る。nilなら撮影の失敗。
    var screenshotForTesting: ((ScreenDisplay) -> CGImage?)?
    /// 開いているストリームの対象の世代。閉じていればnil。
    var openStreamTargetForTesting: Int? { lock.withLock { source?.target } }
    /// ストリームを開かずに、いまの対象の撮影に要るものを揃える。開始を経ない検証で「いま撮る」を受け付けるため。
    func openForTesting() {
        queue.sync { lock.withLock { source = CaptureSource(target: targetGeneration, filter: nil) } }
    }
    /// 判定器へ渡す今の時刻を差し替える。観測の時刻と、保存の結果・失敗の時刻を同じ時計にそろえる検証で使う。
    func setClockForTesting(_ clock: @escaping @Sendable () -> Date) {
        queue.sync { self.clock = clock }
    }
    /// 判定器の今の状態。queue上で写す。
    var detectorForTesting: ScreenChangeDetector { queue.sync { detector } }
    /// trueの間、受け付けた自動の保存を符号化へ渡さずに持つ。後に受け付けた「いま撮る」を先に届ける検証で使う。
    private var deferAutomaticSaves = false
    private var deferredSaves: [ScreenShot] = []
    func deferAutomaticSavesForTesting() { queue.sync { deferAutomaticSaves = true } }
    /// 持っていた自動の保存を、受け付けた順に符号化へ渡す。
    func releaseAutomaticSavesForTesting() {
        queue.sync {
            deferAutomaticSaves = false
            let shots = deferredSaves
            deferredSaves = []
            shots.forEach(save)
        }
    }
#endif

    private func startTimer() {
        // idleが続く間も待ちを進める。通知が来ない間を数える専用のタイマー。
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        let opened = streamEpoch
        timer.setEventHandler { [weak self] in
            guard let self, self.syncEpoch(source: opened), let decision = self.detector.tick(at: Self.monotonic(self.clock())) else { return }
            self.decide(decision)
        }
        timer.resume()
        self.timer = timer
    }

    private func decide(_ decision: ScreenChangeDetector.Decision) {
        guard var shot = latest, shot.frame == decision.frame, let order = begin(epoch: seenEpoch, automatic: true) else {
            detector.saveFailed(frame: decision.frame, at: Self.monotonic(clock()))
            return
        }
        // 判定器にも同じ受付の番号を渡す。比較の基準の新旧はこの番号で比べる。
        detector.accepted(frame: decision.frame, order: order)
        shot.order = order
        save(shot)
    }

    /// 保存の処理を受け付ける。撮影中で、世代が変わっておらず、停止・無効の前なら受け付ける。
    /// 確認と数え上げを同じロックの中で行い、確認の後に一時停止・取得不能が挟まっても受け付けない。
    /// 受け付けたら `complete` が必ず1回終える。
    /// - 返す値: 受付の番号。自動も「いま撮る」も、このクリティカルセクションの中で単調に増える番号を1つ取る
    private func begin(epoch expected: Int, automatic: Bool) -> Int? {
        lock.withLock {
            guard capturing, epoch == expected, accepting, !invalidated else { return nil }
            pending += 1
            let order = accepted
            accepted += 1
            if automatic { automaticPending += 1 }
            return order
        }
    }

    // MARK: - 保存と公開

    private enum Outcome { case success(URL), failure(String) }

    private func save(_ shot: ScreenShot) {
#if DEBUG
        // 自動の保存を止めておく検証では、符号化へ渡さずに持つ。queue上でだけ触る。
        // 自動の保存はqueue上の判定から呼ばれる。「いま撮る」はMainActorから呼ばれるので、先に自動かを見て持ち物に触れない。
        if shot.frame != nil, deferAutomaticSaves { deferredSaves.append(shot); return }
#endif
        encodeQueue.async { [self] in
            do {
                let data = try WebPEncoder.encode(shot.image)
                try PrivateFileIO.createDirectory(at: capturesDirectory)
                let url = try Self.write(data, in: capturesDirectory, observedAt: shot.observedAt)
                complete(shot: shot, result: .success(url))
            } catch {
                complete(frame: shot.frame, result: .failure(error.localizedDescription))
            }
        }
    }

    private func complete(shot: ScreenShot? = nil, frame: Int? = nil, result: Outcome) {
        // 成功も失敗も同じ順序付きの1本でMainActorへ返す。保存の順と、ヘッダーの失敗の数え方の順を揃える。
        DispatchQueue.main.async { [self] in
            let published: PublishResult = MainActor.assumeIsolated {
                // 自動の保存は、MainActorが結果を扱う前に「届いていない」数から外す。保留はこの数で、まだ届く保存があるかを知る。
                if (shot?.frame ?? frame) != nil { lock.withLock { automaticPending -= 1 } }
                switch result {
                case let .success(url):
                    guard let shot, !isInvalidated else {
                        discardUnpublished(url)
                        return .rejected
                    }
                    let outcome = publish(self, shot, url)
                    if outcome == .rejected { discardUnpublished(url) }
                    return outcome
                case let .failure(reason):
                    failed(self, reason)
                    return .rejected
                }
            }
            queue.async { [self] in
                refreshTarget()
                let now = Self.monotonic(clock())
                // 公開できなかった1枚は、判定器へ失敗として返し、比較の基準に残さない。
                // そのほかは保存の成功として、その場で決まった行き先を添えて1回で返す。直近に公開した画面として比べるのは、公開してから。
                if let frame = shot?.frame ?? frame {
                    switch published {
                    case .rejected: detector.saveFailed(frame: frame, at: now)
                    // 直近の画面と外すマスの起点は、保存を決めた時刻のまま。書けた時刻にすると、試作の決定から外れる。
                    case .published: detector.saveSucceeded(frame: frame, outcome: .published)
                    case .held: detector.saveSucceeded(frame: frame, outcome: .held)
                    case .discarded: detector.saveSucceeded(frame: frame, outcome: .discarded)
                    }
                } else if published != .rejected, let shot, let order = shot.order, shot.target == seenTarget,
                          let thumbnail = Self.thumbnail(shot.image, width: detector.parameters.thumbnailWidth) {
                    // 「いま撮る」の1枚を、受付の番号の順で比較の基準にする。捨てた自動の保留を基準に残さず、
                    // 同じ画面を自動でもう1枚撮らない。後に受け付けた画像が基準なら替えない。
                    // 対象を替えた後に届いた1枚は、替えた先の基準にしない。行としては公開する。
                    detector.adopt(order: order, thumbnail: thumbnail, at: now)
                }
                lock.withLock { pending -= 1 }
            }
        }
    }

    /// 保留へ入れた自動の1枚を、後から公開した・捨てた。MainActorから受付の番号で知らせる。
    /// 判定器は、公開した画面だけを直近の画面として比べる。捨てた画面へ戻ったら撮れるようにする。
    /// 知らせるのは、保存の結果を `held` で返した画像だけ。届いた時点で行き先が決まった画像は、結果に添えて返すので知らせない。
    /// 結果はこの知らせより先に判定器へ届く。どちらもMainActorから同じ順序付きのqueueへ流し、結果は保留へ入れた番で、知らせはその後の番で流すため。
    func heldScreen(order: Int, published: Bool) {
        queue.async { [self] in
            refreshTarget()
            if published { detector.published(order: order) } else { detector.discarded(order: order) }
        }
    }

    /// 同じ秒の名前は `_2` を足して排他的に公開する。他のプロセスと取り合っても上書きしない。
    private static func write(_ data: Data, in directory: URL, observedAt: Date) throws -> URL {
        var tried: Set<String> = []
        while true {
            let name = ScreenCaptureFiles.fileName(observedAt: observedAt) { tried.contains($0) || FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
            let url = directory.appendingPathComponent(name)
            do {
                try PrivateFileIO.write(data, to: url, replacing: false)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                tried.insert(name)
            }
        }
    }

    /// 撮れなくなった。その時点で撮影を止め、MainActorへ一度だけ知らせる。どのスレッドから呼んでもよい。
    /// - epoch: 失敗が起きた開始・ストリームの撮影の世代。今の世代と違えば古い処理の失敗として無視する
    /// 知らせには、撮れなくなった対象の世代を添える。届くまでに別の対象を選んでいたら、受け取った側が `ScreenTarget` で捨てる。
    private func reportUnavailable(_ reason: String, epoch source: Int) {
        let generation: Int? = lock.withLock {
            guard !reportedUnavailable, !invalidated, epoch == source else { return nil }
            reportedUnavailable = true
            epoch += 1; capturing = false
            return targetGeneration
        }
        guard let generation else { return }
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { becameUnavailable(self, reason, generation) } }
    }

    // MARK: - 補助

    /// 等倍の4倍の幅へ描いてから、マスごとの平均で縮める。等倍の全画素を描くより軽い。
    static func thumbnail(_ image: CGImage, width: Int) -> ScreenThumbnail? {
        let w = min(image.width, width * 4)
        let h = ScreenThumbnail.height(forWidth: w, imageWidth: image.width, imageHeight: image.height)
        var gray = [UInt8](repeating: 0, count: w * h)
        let drawn: Bool = gray.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        return gray.withUnsafeBufferPointer { pixels in ScreenThumbnail.average(width: w, height: h, to: width) { pixels[$1 * w + $0] } }
    }

    /// 対象ディスプレイに重なる、通常レイヤーの最前面のウィンドウの題。KIKIGAKI自身は除く。
    /// 一覧は前から後ろの順と文書にある。`SCShareableContent.windows` の順は保証されないので使わない。
    static func label(display: ScreenDisplay) -> String {
        let bounds = CGDisplayBounds(display.id)
        let own = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let front = list.first { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0, (info[kCGWindowOwnerPID as String] as? pid_t) != own,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0, let raw = info[kCGWindowBounds as String],
                  let frame = CGRect(dictionaryRepresentation: raw as! CFDictionary) else { return false }
            let overlap = frame.intersection(bounds)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0
        }
        return ScreenCaptureLabel.make(display: display.name, application: front?[kCGWindowOwnerName as String] as? String,
                                       title: front?[kCGWindowName as String] as? String)
    }

    private static let timebase: mach_timebase_info_data_t = { var info = mach_timebase_info_data_t(); mach_timebase_info(&info); return info }()

    /// フレームの `displayTime`(mach時刻)を実時刻へ写す。無ければ受け取った時刻。
    private static func date(of displayTime: UInt64?, now: Date) -> Date {
        guard let displayTime else { return now }
        let current = mach_absolute_time()
        guard displayTime <= current else { return now }
        let seconds = Double(current - displayTime) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        return now.addingTimeInterval(-seconds)
    }

    /// 判定器へ渡す単調な秒。実時刻の補正で待ちが伸び縮みしないよう、起動からの経過へ写す。
    private static func monotonic(_ date: Date) -> Double {
        ProcessInfo.processInfo.systemUptime - Date().timeIntervalSince(date)
    }
}
