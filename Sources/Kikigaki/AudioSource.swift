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
final class MicSource: AudioSource {
    private let engine = AVAudioEngine()

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(onSamples: @escaping ([Float]) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let resampler = AudioResampler(from: format) else {
            throw NSError(domain: "kikigaki", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "マイクの形式を 16kHz mono へ変換できない: \(format)"])
        }
        // 変換器はタップの閉包が持つ。録音のたびに作り直すので、前の会議の状態は残らない
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let samples = try? resampler.resample(buffer), !samples.isEmpty else { return }
            onSamples(samples)
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// 音声ファイルをマイクの代わりに流す(開発用の `--replay <file>`)。実時間を待たずに流し、
/// 流し終えたら `onEnd` を呼ぶ。マイク無しでパイプラインの端から端まで検証するための口
final class FileSource: AudioSource {
    private let samples: [Float]
    private var task: Task<Void, Never>?
    var onEnd: (() -> Void)?

    init(url: URL, systemAudioURL: URL? = nil) throws {
        let microphone = try AudioConverter().resampleAudioFile(url)
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
    }

    func start(onSamples: @escaping ([Float]) -> Void) throws {
        let samples = self.samples
        let onEnd = self.onEnd
        #if DEBUG
        let realtime = ProcessInfo.processInfo.environment["KIKIGAKI_DEBUG_REPLAY_REALTIME"] == "1"
        #else
        let realtime = false
        #endif
        task = Task.detached {
            let step = 8000  // 0.5秒
            var i = 0
            while i < samples.count, !Task.isCancelled {
                onSamples(Array(samples[i..<min(i + step, samples.count)]))
                i += step
                // 消費側(話者判別 + SpeechTranscriber)に追いつかれないよう軽く間を置く。
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
