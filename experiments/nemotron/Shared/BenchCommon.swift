import FluidAudio
import Foundation

// 2つのパッケージ(FluidAudio 0.15.6 / 0.17.4)が同じファイルをシンボリックリンクで共有する。
// 入力の読み込み・区間の切り出し・送り幅・計測の書式を揃え、差をモデルとライブラリだけに絞るため。

let sampleRate = 16000
/// アプリの FileSource と同じ0.5秒刻みで流す
let feedStep = 8000

struct Options {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var positional: [String] = []

    init(_ args: ArraySlice<String>) {
        var i = args.startIndex
        while i < args.endIndex {
            let a = args[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < args.endIndex, !args[i + 1].hasPrefix("--") {
                    values[key] = args[i + 1]
                    i += 2
                    continue
                }
                flags.insert(key)
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func string(_ key: String) -> String? { values[key] }
    func double(_ key: String, _ fallback: Double) -> Double { values[key].flatMap(Double.init) ?? fallback }
    func require(_ key: String) -> String {
        guard let v = values[key] else { fail("--\(key) が必要") }
        return v
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

struct AudioSlice {
    let path: String
    let start: Double
    let samples: [Float]
    var seconds: Double { Double(samples.count) / Double(sampleRate) }
}

/// アプリの `FileSource` と同じ `AudioConverter().resampleAudioFile` で16kHz monoへ変換し、区間を切り出す
func loadSlice(_ options: Options) throws -> AudioSlice {
    let path = options.require("wav")
    let all = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
    let total = Double(all.count) / Double(sampleRate)
    // 区間は黙って丸めない。比較のたびに別の区間を流していたことに気付けなくなる
    func seconds(_ key: String) -> Double? {
        guard let raw = options.string(key) else { return nil }
        guard let v = Double(raw), v.isFinite, v >= 0 else { fail("--\(key) は0以上の有限の秒数: \(raw)") }
        guard v <= total else { fail("--\(key)=\(v) が音声長 \(total)秒 を超える") }
        return v
    }
    let start = seconds("start") ?? 0
    let from = Int(start * Double(sampleRate))
    let to: Int
    if let d = seconds("duration") {
        guard d > 0, start + d <= total else { fail("--duration=\(d) が不正、または start+duration が音声長 \(total)秒 を超える") }
        to = from + Int(d * Double(sampleRate))
    } else {
        to = all.count
    }
    guard from < to, to <= all.count else { fail("区間が空: start=\(start)") }
    return AudioSlice(path: path, start: start, samples: Array(all[from..<to]))
}

func now() -> Double { ProcessInfo.processInfo.systemUptime }

func peakRSSMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576  // macOS は bytes
}

struct Segment: Codable {
    let speaker: Int
    let start: Double
    let end: Double
}

/// 音声時刻での差の分布。各計測点で「その時点までに入力し終えた位置 − 結果が届いている末尾」を記録する。
/// 発話からの遅延そのものではなく、どれだけ後ろまで判定・出力が追いついているかの差
struct LagStats: Encodable {
    var samples: [Double] = []
    var max: Double { samples.max() ?? 0 }
    var median: Double {
        guard !samples.isEmpty else { return 0 }
        let s = samples.sorted()
        return s[s.count / 2]
    }

    /// 判定済み末尾が `from` から `to` へ進んだとき、その間の10msフレームごとの待ちを足す
    mutating func appendFrames(from: Double, to: Double, fedSeconds: Double) {
        var frame = (from * 100).rounded() / 100
        while frame < to {
            samples.append(fedSeconds - frame)
            frame += 0.01
        }
    }

    enum CodingKeys: String, CodingKey { case max, median, count }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(max, forKey: .max)
        try c.encode(median, forKey: .median)
        try c.encode(samples.count, forKey: .count)
    }
}

struct Timing: Encodable {
    /// モデルの取得・読み込み・コンパイル。初回はダウンロードを含む
    var loadSeconds: Double = 0
    /// 入力を流している間の壁時計。入力ペースの待ちは含めない
    var processSeconds: Double = 0
    /// 末尾のflush・最終化の壁時計
    var finishSeconds: Double = 0
    /// 等倍入力のために寝ていた時間。処理時間ではない
    var paceWaitSeconds: Double = 0
    var audioSeconds: Double = 0
    var modelCachedBeforeRun = false
    /// 等倍で入力した計測は、処理能力(RTFx)として扱わない。非同期のエンジンは待ちの間にも処理が進むため
    var realtimeInput = false
    var computeSeconds: Double { processSeconds + finishSeconds }
    var wallSeconds: Double { computeSeconds + paceWaitSeconds }
    /// 1秒の計算で処理した音声秒数(RTFx)。RTF はその逆数。等倍入力では出さない
    var rtfx: Double? { !realtimeInput && computeSeconds > 0 ? audioSeconds / computeSeconds : nil }
    var rtf: Double? { rtfx.map { 1 / $0 } }

    enum CodingKeys: String, CodingKey {
        case loadSeconds, processSeconds, finishSeconds, paceWaitSeconds, computeSeconds, wallSeconds
        case audioSeconds, rtfx, rtf, modelCachedBeforeRun, realtimeInput
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(loadSeconds, forKey: .loadSeconds)
        try c.encode(processSeconds, forKey: .processSeconds)
        try c.encode(finishSeconds, forKey: .finishSeconds)
        try c.encode(paceWaitSeconds, forKey: .paceWaitSeconds)
        try c.encode(computeSeconds, forKey: .computeSeconds)
        try c.encode(wallSeconds, forKey: .wallSeconds)
        try c.encode(audioSeconds, forKey: .audioSeconds)
        try c.encode(rtfx, forKey: .rtfx)
        try c.encode(rtf, forKey: .rtf)
        try c.encode(modelCachedBeforeRun, forKey: .modelCachedBeforeRun)
        try c.encode(realtimeInput, forKey: .realtimeInput)
    }
}

struct DiarizationResult: Encodable {
    var kind = "diarization"
    let engine: String
    let variant: String
    let fluidAudio: String
    let wav: String
    let start: Double
    let audioSeconds: Double
    /// モデルの出力枠数(4 / 8)。実際に判別できた人数とは別
    let slots: Int
    let speakersDetected: Int
    /// 設定上の入力バッファ量 (chunk + 右文脈)。これだけ先の音声が来るまで、その区間の判定は出ない
    let configuredBufferSeconds: Double
    /// 0.5秒ごとの入力の後で「入力済み位置 − 判定済み末尾」を記録した差。
    /// 入力の刻みと chunk の刻みがずれるぶん、設定値より大きく出ることがある
    let finalizedLag: LagStats
    /// 各10msフレームについて「判定が出た時点の入力済み位置 − そのフレームの時刻」。
    /// chunk の先頭ほど長く待つ。最大は設定の入力バッファ量+入力の刻みに近づく
    let frameWait: LagStats
    let timing: Timing
    let peakRSSMB: Double
    let postprocess: String
    let notes: [String]
    let segments: [Segment]
}

struct TimedToken: Codable {
    let text: String
    let start: Double
    let end: Double
}

struct TranscriptionResult: Encodable {
    var kind = "transcription"
    let engine: String
    let variant: String
    let wav: String
    let start: Double
    let audioSeconds: Double
    /// トークンを最初に受け取った時点の入力済み位置 − そのトークンの終了時刻。
    /// 話者判別の finalizedLag とは測っているものが違う(こちらはトークン単位の出力の遅れ)
    let emissionLag: LagStats
    let timing: Timing
    let peakRSSMB: Double
    let text: String
    let notes: [String]
    let tokens: [TimedToken]
}

func write<T: Encodable>(_ value: T, to options: Options) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    if let out = options.string("out") {
        let url = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        log("wrote \(out)")
    } else {
        FileHandle.standardOutput.write(data)
    }
}

// MARK: - Sortformer(両バージョン共通。アプリの SpeakerDiarizer と同じ流し方・末尾処理)

func sortformerConfig(_ name: String) -> SortformerConfig {
    switch name {
    case "high-context", "high": return .highContextV2_1
    case "balanced": return .balancedV2_1
    case "fast": return .fastV2_1
    default: fail("sortformer --variant は high-context|balanced|fast")
    }
}

func runSortformer(_ options: Options, fluidAudio: String) async throws {
    let variant = options.string("variant") ?? "high-context"
    let config = sortformerConfig(variant)
    let slice = try loadSlice(options)
    var timing = Timing()
    timing.audioSeconds = slice.seconds
    let cache = options.string("models").map { URL(fileURLWithPath: $0, isDirectory: true) }
    let root = cache ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FluidAudio/Models")
    timing.modelCachedBeforeRun = FileManager.default.fileExists(atPath: root.appendingPathComponent("sortformer").path)

    var t = now()
    let models = try await SortformerModels.loadFromHuggingFace(config: config, cacheDirectory: cache)
    timing.loadSeconds = now() - t

    let diarizer = SortformerDiarizer(config: config)
    diarizer.initialize(models: models)
    var lag = LagStats()
    var wait = LagStats()
    var fed = 0
    var lastFinalized: Double = 0
    t = now()
    var i = 0
    while i < slice.samples.count {
        let chunk = Array(slice.samples[i..<min(i + feedStep, slice.samples.count)])
        _ = try diarizer.process(samples: chunk)
        fed += chunk.count
        i += feedStep
        let finalized = Double(diarizer.timeline.finalizedDuration)
        if finalized > lastFinalized {
            lag.samples.append(Double(fed) / Double(sampleRate) - finalized)
            wait.appendFrames(from: lastFinalized, to: finalized, fedSeconds: Double(fed) / Double(sampleRate))
            lastFinalized = finalized
        }
    }
    timing.processSeconds = now() - t

    t = now()
    // アプリの SpeakerDiarizer.finish() と同じ。High Context だけ話者エンジンへ無音を足して末尾を判定させる
    if config.chunkLen == SortformerConfig.highContextV2_1.chunkLen, fed > 0 {
        let padding = (config.chunkLen + config.chunkRightContext + 1) * config.subsamplingFactor * config.melStride + config.melWindow
        _ = try diarizer.process(samples: [Float](repeating: 0, count: padding))
    }
    _ = try diarizer.finalizeSession()
    timing.finishSeconds = now() - t

    let duration = slice.seconds
    let segments = diarizer.timeline.speakers.values.flatMap { speaker in
        (speaker.finalizedSegments + speaker.tentativeSegments).compactMap { s -> Segment? in
            let start = Double(s.startTime), end = min(duration, Double(s.endTime))
            return start < end ? Segment(speaker: s.speakerIndex, start: start, end: end) : nil
        }
    }.sorted { ($0.start, $0.speaker) < ($1.start, $1.speaker) }
    diarizer.cleanup()

    let configured = Double((config.chunkLen + config.chunkRightContext) * config.subsamplingFactor * config.melStride) / Double(sampleRate)
    try write(DiarizationResult(
        engine: "sortformer", variant: variant, fluidAudio: fluidAudio,
        wav: slice.path, start: slice.start, audioSeconds: slice.seconds,
        slots: 4, speakersDetected: Set(segments.map(\.speaker)).count,
        configuredBufferSeconds: configured, finalizedLag: lag, frameWait: wait,
        timing: timing, peakRSSMB: peakRSSMB(),
        postprocess: "DiarizerTimeline既定(しきい値0.5、最短長なし、80msフレーム)",
        notes: ["流し方と末尾処理はアプリの SpeakerDiarizer と同じ"],
        segments: segments), to: options)
}
