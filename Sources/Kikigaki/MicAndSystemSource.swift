import Foundation
import Synchronization

/// 開始待ち中の取消後に、遅れて始まった音源から前の会議へサンプルを流さない。
private final class SystemAudioStartupSamples {
    let active = Atomic<Bool>(true)
    let handler: ([Float]) -> Void
    init(_ handler: @escaping ([Float]) -> Void) { self.handler = handler }
    func emit(_ samples: [Float]) {
        if active.load(ordering: .acquiring) { handler(samples) }
    }
}

/// 会議自体は止めない。失敗したaggregateを破棄して既存MicSourceへ切り替える。
/// 音源の選択・切替はmain queue。会議のHAL開始はprepareの専用queueで待つ。
/// HALからの失敗通知もmainへ渡され、旧世代の通知は停止後に適用しない。
final class MicAndSystemSource: AudioSource {
    private let makeCapture: () -> SystemAudioCapturing
    private let makeMicrophone: () throws -> AudioSource
    private var live: AudioSource?
    private var samples: (([Float]) -> Void)?
    private var generation = UUID()
    private var running = false
    private var retry: DispatchWorkItem?
    private var lastReason: String?
    private let startupQueue = DispatchQueue(label: "kikigaki.system-audio.start", qos: .userInitiated)
    private var preparing = false
    private var preparationFailure: String?
    private var startupSamples: SystemAudioStartupSamples?
    private(set) var warning: String?
    var onWarning: ((String) -> Void)?

    init(makeCapture: @escaping () -> SystemAudioCapturing = { SystemAudioCapture() },
         makeMicrophone: @escaping () throws -> AudioSource = {
             // Bluetooth切断直後はOSの既定入力がまだ消えたデバイスを指すことがある。
             // 不正なformatでAVAudioEngineのtapを設置する前に、再試行できる失敗へ戻す。
             try SystemAudioHAL.requireMicrophone()
             return MicSource()
         }) {
        self.makeCapture = makeCapture; self.makeMicrophone = makeMicrophone
    }
    func start(onSamples: @escaping ([Float]) -> Void) throws {
        let (capture, token, input) = begin(onSamples: onSamples)
        let result = Result { try capture.start(onSamples: input.emit) }
        if case .failure = result { capture.stop() }
        guard running, generation == token else { capture.stop(); return }
        complete(capture, result: result)
    }

    /// 会議の開始はこの口をawaitする。同期のHAL開始は許可待ちでMainActorを止め得る。
    /// 待っている間は「準備中」のまま。独立したMicSourceを並走させて声を埋めることはしない。
    @MainActor
    func prepare(onSamples: @escaping ([Float]) -> Void) async throws {
        let (capture, token, input) = begin(onSamples: onSamples)
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            startupQueue.async {
                let result = Result { try capture.start(onSamples: input.emit) }
                if case .failure = result { capture.stop() }
                continuation.resume(returning: result)
            }
        }
        guard running, generation == token, !Task.isCancelled else {
            input.active.store(false, ordering: .releasing)
            await withCheckedContinuation { continuation in
                startupQueue.async { capture.stop(); continuation.resume() }
            }
            if generation == token { stop() }
            throw CancellationError()
        }
        complete(capture, result: result)
    }

    private func begin(onSamples: @escaping ([Float]) -> Void) -> (SystemAudioCapturing, UUID, SystemAudioStartupSamples) {
        warning = nil; lastReason = nil
        generation = UUID(); running = true; samples = onSamples
        preparing = true; preparationFailure = nil
        let input = SystemAudioStartupSamples(onSamples)
        startupSamples = input
        let capture = makeCapture(), token = generation
        capture.onFailure = { [weak self] reason in
            guard let self, self.running, self.generation == token else { return }
            // 開始直後のworker失敗がawaitの復帰より先にMainActorへ届く場合もある。
            // liveへ載せてから切り替え、開始中のcaptureを取り残さない。
            if self.preparing { self.preparationFailure = reason; return }
            self.fallBack(reason: reason)
        }
        return (capture, token, input)
    }
    private func complete(_ capture: SystemAudioCapturing, result: Result<Void, Error>) {
        preparing = false
        switch result {
        case .success:
            live = capture
            if let reason = preparationFailure { fallBack(reason: reason) }
        case .failure(let error):
            fallBack(reason: error.localizedDescription)
        }
        preparationFailure = nil
    }
    private func notify(_ text: String) {
        warning = text
        if lastReason != text { lastReason = text; onWarning?(text) }
    }
    private func fallBack(reason: String) {
        live?.stop(); live = nil
        notify("システム音声を取り込めないためマイクのみで続けます: \(reason)")
        startMicrophone(reason: reason)
    }
    private func startMicrophone(reason: String) {
        guard running, let samples else { return }
        var microphone: AudioSource?
        do {
            let source = try makeMicrophone()
            microphone = source
            try source.start(onSamples: samples); live = source
            // 再接続できたら「再試行します」を残さず、マイクのみで続ける理由へ戻す。
            notify("システム音声を取り込めないためマイクのみで続けます: \(reason)")
        }
        catch {
            microphone?.stop()
            notify("マイクを再接続できません。再試行します: \(error.localizedDescription)")
            // 主時計のBluetoothマイクが消え、OSの既定入力更新がまだ終わらない場合もある。
            // 一時停止の状態はsessionのPauseFlagが引き続き管理する。
            let token = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.running, self.generation == token else { return }
                self.startMicrophone(reason: reason)
            }
            retry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }
    }
    func stop() {
        // 開始API自体は公開APIで取消できない。返った後のprepareがcaptureを破棄する。
        if preparing { startupSamples?.active.store(false, ordering: .releasing) }
        running = false; generation = UUID()
        preparing = false; preparationFailure = nil
        retry?.cancel(); retry = nil
        live?.stop(); live = nil; samples = nil; startupSamples = nil
    }
    deinit { stop() }
}
