import AVFoundation
import Foundation

/// 実機の代わりに停止通知・新形式での開始・入力時刻を注入できる境界。
protocol MicrophoneCapturing: AnyObject {
    var onConfigurationChange: (() -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    var isRunning: Bool { get }
    func start(onSamples: @escaping ([Float], Double) -> Void) throws
    func stop()
}

/// マイク単独の録音。入力装置とengine通知を併用し、同じ形式の装置へも追従する。
/// engineの破棄・開始・サンプルの供給は専用queueへ直列化する。
final class MicSource: AudioSource {
    private let queue = DispatchQueue(label: "kikigaki.microphone")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let makeCapture: () -> MicrophoneCapturing
    private let device: () throws -> MicrophoneDevice
    private let observeInput: (@escaping () -> Void) throws -> (() -> Void)
    private let now: () -> Double
    private let date: () -> Date
    private let retryDelay: Double
    private var cancelInput: (() -> Void)?
    private var capture: MicrophoneCapturing?
    private var handler: (([Float]) -> Void)?
    private var generation = UUID()
    private var captureGeneration = UUID()
    private var retry: DispatchWorkItem?
    private var selected: MicrophoneDevice?
    private var announced: MicrophoneDevice?
    private var lastEnd: Double?
    private var recovering = false
    private var warned = false
    var onSwitch: ((String, Date) -> Void)?
    var onWarning: ((String?) -> Void)?
    /// セッションは欠落期間から一時停止分を除き、同じPCMの口へ無音を供給する。
    var onGap: ((Int, Date, Date) -> Void)?

    init(makeCapture: @escaping () -> MicrophoneCapturing = { EngineMicrophoneCapture() },
         device: @escaping () throws -> MicrophoneDevice = { try MicrophoneDevice.current() },
         observeInput: @escaping (@escaping () -> Void) throws -> (() -> Void) = { try MicrophoneDevice.observe($0) },
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         date: @escaping () -> Date = Date.init, retryDelay: Double = 1) {
        self.makeCapture = makeCapture; self.device = device; self.observeInput = observeInput
        self.now = now; self.date = date; self.retryDelay = retryDelay
        queue.setSpecific(key: queueKey, value: true)
    }
    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try body() }
        return try queue.sync(execute: body)
    }
    func start(onSamples: @escaping ([Float]) -> Void) throws {
        try sync {
            stop()
            handler = onSamples; generation = UUID()
            lastEnd = now(); recovering = false; warned = false
            let token = generation
            do {
                cancelInput = try observeInput { [weak self] in
                    self?.queue.async { [weak self] in
                        guard let self, self.generation == token, self.handler != nil else { return }
                        // 先着したengine通知で既に同じ既定入力へ復帰していたら再起動しない。
                        if let current = try? self.device(), current.id == self.selected?.id,
                           self.capture?.isRunning == true { return }
                        self.reconnect()
                    }
                }
                try connect()
                announced = selected
            } catch { stop(); throw error }
        }
    }
    private func connect() throws {
        let current = try device()
        let next = makeCapture(), token = UUID()
        captureGeneration = token
        next.onConfigurationChange = { [weak self] in
            self?.queue.async { [weak self] in
                guard let self, self.captureGeneration == token, self.handler != nil else { return }
                self.reconnect()
            }
        }
        next.onFailure = { [weak self] reason in
            self?.queue.async { [weak self] in
                guard let self, self.captureGeneration == token, self.handler != nil else { return }
                self.fail(reason)
            }
        }
        capture = next
        do {
            try next.start { [weak self] samples, end in
                self?.queue.async { [weak self] in
                    guard let self, self.captureGeneration == token, let handler = self.handler else { return }
                    if self.recovering {
                        // 新buffer自体の長さは無音へ含めない。停止していた間だけ16kHzへ戻す。
                        let missing = max(0, end - Double(samples.count) / 16000 - (self.lastEnd ?? end))
                        let count = Int((missing * 16000).rounded())
                        if let onGap = self.onGap {
                            let wallEnd = self.date().addingTimeInterval(end - Double(samples.count) / 16000 - self.now())
                            onGap(count, wallEnd.addingTimeInterval(-missing), wallEnd)
                        } else {
                            var remaining = count
                            while remaining > 0 {
                                let count = min(8000, remaining)
                                handler(Array(repeating: 0, count: count)); remaining -= count
                            }
                        }
                        if self.announced?.id != current.id {
                            self.onSwitch?(current.name, self.date())
                            self.announced = current
                        }
                        self.recovering = false
                        if self.warned { self.onWarning?(nil); self.warned = false }
                    }
                    self.lastEnd = end
                    handler(samples)
                }
            }
            selected = current
        } catch {
            discardCapture()
            throw error
        }
    }
    private func discardCapture() {
        captureGeneration = UUID()
        capture?.stop(); capture = nil
    }
    private func reconnect() {
        retry?.cancel(); retry = nil
        recovering = true
        discardCapture()
        do { try connect() }
        catch { fail(error.localizedDescription) }
    }
    private func fail(_ reason: String) {
        recovering = true; warned = true
        discardCapture()
        onWarning?("マイクを再接続できません。再試行します: \(reason)")
        retry?.cancel()
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.handler != nil, self.generation == token else { return }
            self.reconnect()
        }
        retry = work
        queue.asyncAfter(deadline: .now() + retryDelay, execute: work)
    }
    func stop() {
        sync {
            generation = UUID(); handler = nil
            retry?.cancel(); retry = nil
            cancelInput?(); cancelInput = nil
            discardCapture()
            selected = nil; announced = nil; lastEnd = nil
        }
    }
    deinit { stop() }
    /// テストで通知と音声のキューが完了するまで待つ。実装の順序を変える口にはしない。
    func drain() { sync {} }
}

/// 表示だけの注記。会話のUtteranceにはしない。
/// 既存の会話保存型に機器注記の型が無いので、Markdown・AI文脈へ紛れ込ませない。
struct MicrophoneSwitch: Equatable {
    let id: UUID
    let audioTime: Double
    let date: Date
    let name: String
    init(audioTime: Double, date: Date, name: String) {
        id = UUID(); self.audioTime = audioTime; self.date = date; self.name = name
    }
    var text: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: date)) マイクを \(name) へ切替"
    }
}
