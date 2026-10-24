import AVFoundation
import FluidAudio
import Foundation
import KikigakiCore

/// 音源の口。16kHz mono Float32 のサンプル列を渡す。
/// マイク単独と、システム音声を混ぜる会議で差し替える。
protocol AudioSource: AnyObject {
    /// サンプルを渡し始める。`onSamples` は音声スレッドから呼ばれる
    func start(onSamples: @escaping ([Float]) -> Void) throws
    func stop()
}

/// マイク入力を 16kHz mono Float32 に変換して流す(プロトの MicCapture の移植)
final class EngineMicrophoneCapture: MicrophoneCapturing {
    private let engine = AVAudioEngine()
    private let notifications: NotificationCenter
    private var observer: NSObjectProtocol?
    private var tapped = false
    var onConfigurationChange: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var isRunning: Bool { engine.isRunning }
    init(notifications: NotificationCenter = .default) { self.notifications = notifications }
    // マイクを開かず、実際の通知登録から再起動経路までを試験する口。
    var notificationObject: AnyObject { engine }
    func observeConfigurationChanges() {
        observer = notifications.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            // Appleの内部queueではengineを破棄しない。MicSourceが専用queueへ渡す。
            self?.onConfigurationChange?()
        }
    }
    func start(onSamples: @escaping ([Float], Double) -> Void) throws {
        try SystemAudioHAL.requireMicrophone()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let resampler = AudioResampler(from: format) else {
            throw NSError(domain: "kikigaki", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "マイクの形式を 16kHz mono へ変換できない: \(format)"])
        }
        // 変換器はタップの閉包が持つ。録音のたびに作り直すので、前の会議の状態は残らない
        observeConfigurationChanges()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            do {
                let samples = try resampler.resample(buffer)
                guard !samples.isEmpty else { return }
                let end = time.isHostTimeValid
                    ? AVAudioTime.seconds(forHostTime: time.hostTime) + Double(buffer.frameLength) / format.sampleRate
                    : ProcessInfo.processInfo.systemUptime
                onSamples(samples, end)
            } catch { self?.onFailure?(error.localizedDescription) }
        }
        tapped = true
        try engine.start()
    }

    func stop() {
        if let observer { notifications.removeObserver(observer) }
        observer = nil
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        engine.stop()
    }
    deinit { stop() }
}

/// 音声ファイルを流す。流し終えたら `onEnd` を呼ぶ。
///
/// 音声ファイルの書き起こし(`paced: false`)は間を置かず、消費に追いつかれるまで流す。
/// 開発用の `--replay <file>` は録音の模擬なので間を置く(`paced: true`)。
final class FileSource: AudioSource {
    private let samples: [Float]
    private var task: Task<Void, Never>?
    var onEnd: (() -> Void)?
    /// 間を置かずに流すときだけ持つ。消費側が読んだ分を数える
    let feedGate: FileFeedGate?
    var duration: Double { Double(samples.count) / 16000 }

    /// 長いファイルの変換は数秒かかるので、MainActorの外で行う。
    static func load(url: URL, systemAudioURL: URL? = nil, paced: Bool) async throws -> FileSource {
        let samples = try await Task.detached(priority: .userInitiated) {
            try decode(url: url, systemAudioURL: systemAudioURL)
        }.value
        return FileSource(samples: samples, paced: paced)
    }

    init(samples: [Float], paced: Bool) {
        self.samples = samples
        feedGate = paced ? nil : FileFeedGate()
    }

    private static func decode(url: URL, systemAudioURL: URL?) throws -> [Float] {
        let microphone = try AudioConverter().resampleAudioFile(url)
        let samples: [Float]
        if let systemAudioURL {
            let system = try AudioConverter().resampleAudioFile(systemAudioURL)
            // 実録の同時刻WAVを使う検証口。短い方の末尾は無音で延長し、時間を詰めない。
            let count = max(microphone.count, system.count)
            let micLane = microphone + [Float](repeating: 0, count: count - microphone.count)
            let systemLane = system + [Float](repeating: 0, count: count - system.count)
            samples = SystemAudioMixer.process(microphone: micLane, systemAudio: systemLane)
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            FileHandle.standardError.write(Data("system-audio replay: frames=\(samples.count) peak=\(peak)\n".utf8))
        } else { samples = microphone }
        guard !samples.isEmpty else {
            throw NSError(domain: "kikigaki", code: 1, userInfo: [NSLocalizedDescriptionKey: "音声を読めない: \(url.path)"])
        }
        return samples
    }

    func start(onSamples: @escaping ([Float]) -> Void) throws {
        let samples = self.samples
        let onEnd = self.onEnd
        let gate = feedGate
        #if DEBUG
        let realtime = ProcessInfo.processInfo.environment["KIKIGAKI_DEBUG_REPLAY_REALTIME"] == "1"
        #else
        let realtime = false
        #endif
        task = Task.detached {
            let step = 8000  // 0.5秒
            var i = 0
            while i < samples.count, !Task.isCancelled {
                if let gate { await gate.waitUntilCaughtUp(fed: i) }
                guard !Task.isCancelled else { break }
                onSamples(Array(samples[i..<min(i + step, samples.count)]))
                i += step
                guard gate == nil else { continue }
                // replayは消費側(話者判別 + SpeechTranscriber)に追いつかれないよう軽く間を置く。
                // 実時間の 1/10 程度で、10分の音声なら1分で流し終える
                try? await Task.sleep(for: .milliseconds(realtime ? 500 : 50))
            }
            if !Task.isCancelled { onEnd?() }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// 音声ファイルの書き起こしで、供給が消費より先へ行きすぎないよう止める。
/// 先行を抑えないと、ファイル全体が未処理のまま待ち行列へ二重に載る。仕様は docs/audio-file.md
final class FileFeedGate: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = 0
    /// 先行を許す音声の長さ(16kHzのサンプル数)
    let limit: Int

    init(limit: Int = 16000 * 30) { self.limit = limit }

    /// 消費側が処理し終えたサンプル数を足す
    func consume(_ count: Int) { lock.withLock { consumed += count } }

    func waitUntilCaughtUp(fed: Int) async {
        while !Task.isCancelled, fed - lock.withLock({ consumed }) > limit {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// 16kHz mono Float32 の WAV 書き出し(プロトの WavWriter の移植)
final class WavWriter {
    private let file: AVAudioFile
    private let format: AVAudioFormat

    init(url: URL) throws {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        // AVAudioFileに新規作成させるとumask依存になる。先に0600で排他予約する。
        try PrivateFileIO.write(Data(), to: url, replacing: false)
        do {
            file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func write(_ samples: [Float]) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    /// ヘッダのデータ長を書き戻す。閉じずにプロセスを抜けるとデータ長 0 のWAVになり、
    /// AVAudioFile で読むと 0 サンプルに見える(プロトで実測)。停止時に必ず呼ぶ
    func close() {
        file.close()
    }
}
