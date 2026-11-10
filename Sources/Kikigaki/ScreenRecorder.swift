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
}

/// 1つの会議の画面の記録。SCStreamを1x寸法・1秒間隔で開き、判定・WebP保存・公開の依頼までを持つ。
/// 仕様は [画面の記録](docs/screen-capture.md) の「撮影と保存」
///
/// 撮るかどうかは、MainActorの操作が `lock` の下で即座に切り替える(撮影中かと世代)。
/// - 一時停止・停止・取得不能は、ストリームの片付けを待たずに撮影を止める。片付けは後から順に流す
/// - 判定とフレームは `queue` で扱い、世代が変わっていたら判定器の観測を数え直してから読む。比較の基準は引き継ぐ
/// - 符号化と書き込みは `encodeQueue`。結果は成功も失敗も `DispatchQueue.main` の1本で順に返し、公開の可否はMainActorの `publish` が決める
///   - 無音の間の画面は、書き込みまで済ませてからMainActorが保留する。公開の契機で同期に出せるようにするため。
///     この型は保留を知らず、保留を受け付けたことも `published` として受け取る
/// - 停止は `stopAccepting` で新しい保存を止め、`drain` で受付済みの処理を待ち、`invalidate` で残りを無効にする
///
/// 順序の物差しは受付の番号1本にそろえる。
/// - 受付の番号: 自動の保存も「いま撮る」も、`begin` の同じロックの中で単調に増える番号を1つ取る。受付の確認と番号の取得の間に、別の受付は挟まらない
/// - 使う所: 保留の破棄と公開の境界(`ScreenSilenceHold`)、判定器の比較の基準の新旧(`ScreenChangeDetector`)、行の挿入位置(`MeetingSession`)。どれもこの番号で比べる
/// - フレームの番号は、判定器の中で観測を見分けるためだけに使う。新旧の比較には使わない
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum PublishResult { case published, rejected }

    let display: ScreenDisplay
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
    private let becameUnavailable: @MainActor (ScreenRecorder, String) -> Void

    // queue上だけで触る
    private var detector: ScreenChangeDetector
    private var seenEpoch = 0
    private var frameIndex = 0
    private var latest: ScreenShot?
    private var stream: SCStream?
    /// ストリームとタイマーを開いた世代。今の世代と一致する通知だけを判定へ渡す。
    private var streamEpoch = 0
    private var filter: SCContentFilter?
    private var timer: DispatchSourceTimer?

    // lockで守る
    private var accepting = true
    private var invalidated = false
    private var capturing = false
    private var epoch = 0
    private var pending = 0
    /// 受け付けた保存の数。自動と「いま撮る」を合わせ、次に振る受付の番号でもある。
    private var accepted = 0
    /// 受け付けて、結果がまだMainActorへ届いていない自動の保存の数。
    private var automaticPending = 0
    private var reportedUnavailable = false

    init(display: ScreenDisplay, markdownURL: URL, acceptedAudioTime: @escaping @Sendable () -> Double,
         publish: @escaping @MainActor (ScreenRecorder, ScreenShot, URL) -> PublishResult,
         discardUnpublished: @escaping @MainActor (URL) -> Void,
         failed: @escaping @MainActor (ScreenRecorder, String) -> Void,
         becameUnavailable: @escaping @MainActor (ScreenRecorder, String) -> Void) {
        self.display = display
        capturesDirectory = ScreenCaptureFiles.directory(for: markdownURL)
        self.acceptedAudioTime = acceptedAudioTime
        self.publish = publish; self.discardUnpublished = discardUnpublished
        self.failed = failed; self.becameUnavailable = becameUnavailable
        var parameters = ScreenChangeParameters()
        parameters.excludedTopFraction = display.menuBarFraction
        detector = ScreenChangeDetector(parameters: parameters)
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
            capturing = accepting && !invalidated && !reportedUnavailable
            return epoch
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

    /// 以後に公開を依頼された処理は弾かれ、書いた画像は消える。
    func invalidate() {
        lock.withLock { epoch += 1; capturing = false; accepting = false; invalidated = true }
    }

    /// 受付済みの処理が公開まで終わるのを待つ。上限を超えたら残りを無効にする。期限は単調時計で測る。
    func drain(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while lock.withLock({ pending > 0 }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        invalidate()
    }

    private func isCurrent(_ value: Int) -> Bool { lock.withLock { capturing && epoch == value } }

    // MARK: - ストリーム

    /// 撮れる状態か確かめてストリームを開く。撮れなければ取得不能として知らせる。
    /// 待っている間に一時停止・停止・取得不能で世代が変わったら、開かずに戻る。
    /// 許可は `CGPreflightScreenCaptureAccess` で決めない。許可した直後の同じプロセスでは古い値を返す。
    func start(epoch value: Int) async {
        guard isCurrent(value) else { return }
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
            self.filter = filter
            startTimer()
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
    func closeStream() async {
        let stream: SCStream? = queue.sync {
            guard let stream = self.stream else { return nil }
            return detach(stream) ? stream : nil
        }
        try? await stream?.stopCapture()
    }

    /// queue上で、今のストリームなら外す。外したらtrue。
    private func detach(_ stream: SCStream) -> Bool {
        guard self.stream === stream else { return false }
        timer?.cancel(); timer = nil
        self.stream = nil
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
        let label: String
        /// 受付の番号。自動の保存と同じロックの中で取る。
        let order: Int

        func shot(_ image: CGImage) -> ScreenShot {
            ScreenShot(image: image, audioTime: audioTime, observedAt: pressedAt, label: label, frame: nil, order: order)
        }
    }

    /// 押した時点で処理を受け付け、停止のときに公開まで待つ対象にする。撮影中でなければnil。
    /// 時刻の例外: 音声位置と実時刻は押した時点に置く。`captureImage` は観測した時刻を返さないため。
    /// 新旧の順序は受付の番号で決める。完了した時点では決めない。
    func beginCapture() -> CaptureRequest? {
        let pressedAt = Date()
        let audioTime = acceptedAudioTime()
        guard let order = begin(epoch: lock.withLock { epoch }, automatic: false) else { return nil }
        return CaptureRequest(pressedAt: pressedAt, audioTime: audioTime, label: Self.label(display: display), order: order)
    }

    /// 受け付けた「いま撮る」の1枚を撮り、しきい値によらず保存する。結果は `complete` が必ず1回返す。
    func capture(_ request: CaptureRequest) async {
        guard let filter = queue.sync(execute: { self.filter }) else {
            complete(frame: nil, result: .failure("いま撮るの撮影に失敗しました"))
            return
        }
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: Self.configuration(display))
            save(request.shot(image))
        } catch {
            complete(frame: nil, result: .failure("いま撮るの撮影に失敗しました"))
        }
    }

    // MARK: - フレーム

    /// queue上で世代を読む。変わっていたら判定器の観測を数え直す。撮影中ならtrue。
    /// - source: 通知元のストリームを開いた世代。今の世代と違えば、古いストリームの通知として捨てる
    /// - 世代が変わるのは一時停止と再開、停止、取得不能。撮り直すのは再開だけなので、比較の基準は引き継いでよい
    private func syncEpoch(source: Int? = nil) -> Bool {
        let (current, value) = lock.withLock { (capturing, epoch) }
        if value != seenEpoch {
            seenEpoch = value
            detector.restart()
            latest = nil
        }
        return current && (source.map { $0 == value } ?? true)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, stream === self.stream, syncEpoch(source: streamEpoch),
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
            let opened = streamEpoch
            guard detach(stream) else { return }
            reportUnavailable("ディスプレイ「\(display.name)」を取得できなくなりました", epoch: opened)
        }
    }

    /// queue上で、観測した1枚を判定へ渡す。
    private func observe(_ image: CGImage, observedAt: Date, now: Date, label: String) {
        guard let thumbnail = Self.thumbnail(image, width: detector.parameters.thumbnailWidth) else { return }
        let audioTime = ScreenCaptureClock.audioTime(acceptedAudioTime: acceptedAudioTime(), now: now, observedAt: observedAt)
        let shot = ScreenShot(image: image, audioTime: audioTime, observedAt: observedAt, label: label, frame: frameIndex)
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
    /// 受け付けた「いま撮る」を、撮った画像で同じ保存の経路へ渡す。完了を遅らせる検証で、渡す時点を決める。
    func captureForTesting(_ request: CaptureRequest, image: CGImage) {
        save(request.shot(image))
    }
#endif

    private func startTimer() {
        // idleが続く間も待ちを進める。通知が来ない間を数える専用のタイマー。
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        let opened = streamEpoch
        timer.setEventHandler { [weak self] in
            guard let self, self.syncEpoch(source: opened), let decision = self.detector.tick(at: Self.monotonic(Date())) else { return }
            self.decide(decision)
        }
        timer.resume()
        self.timer = timer
    }

    private func decide(_ decision: ScreenChangeDetector.Decision) {
        guard var shot = latest, shot.frame == decision.frame, let order = begin(epoch: seenEpoch, automatic: true) else {
            detector.saveFailed(frame: decision.frame, at: Self.monotonic(Date()))
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
            let published: Bool = MainActor.assumeIsolated {
                // 自動の保存は、MainActorが結果を扱う前に「届いていない」数から外す。保留はこの数で、まだ届く保存があるかを知る。
                if (shot?.frame ?? frame) != nil { lock.withLock { automaticPending -= 1 } }
                switch result {
                case let .success(url):
                    guard let shot, !isInvalidated, publish(self, shot, url) == .published else {
                        discardUnpublished(url)
                        return false
                    }
                    return true
                case let .failure(reason):
                    failed(self, reason)
                    return false
                }
            }
            queue.async { [self] in
                // 公開できなかった1枚は、判定器へ失敗として返し、比較の基準に残さない。
                if let frame = shot?.frame ?? frame {
                    if published { detector.saveSucceeded(frame: frame) }
                    else { detector.saveFailed(frame: frame, at: Self.monotonic(Date())) }
                } else if published, let shot, let order = shot.order,
                          let thumbnail = Self.thumbnail(shot.image, width: detector.parameters.thumbnailWidth) {
                    // 「いま撮る」の1枚を、受付の番号の順で比較の基準にする。捨てた自動の保留を基準に残さず、
                    // 同じ画面を自動でもう1枚撮らない。後に受け付けた画像が基準なら替えない。
                    detector.adopt(order: order, thumbnail: thumbnail)
                }
                lock.withLock { pending -= 1 }
            }
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
    /// - epoch: 失敗が起きた開始・ストリームの世代。今の世代と違えば古い処理の失敗として無視する
    private func reportUnavailable(_ reason: String, epoch source: Int) {
        let first = lock.withLock {
            guard !reportedUnavailable, !invalidated, epoch == source else { return false }
            reportedUnavailable = true
            epoch += 1; capturing = false
            return true
        }
        guard first else { return }
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { becameUnavailable(self, reason) } }
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
