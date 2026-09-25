import AVFoundation
import CoreML
import FluidAudio
import Foundation
import Speech

let usage = """
    usage: bench0174 <command> --wav <path> [--start s] [--duration s] [--out json]
      sortformer   [--variant high-context|balanced|fast] [--models dir]
      nemotron3    [--variant fast32|fast128|fast|low|offline] [--models dir] [--min-duration s]
                   [--check-complete [--complete-tolerance 1e-3]] [--probs-out file]
      asr-nemotron [--chunk-ms 2240] [--language ja-JP] [--models dir]
      asr-apple    [--realtime] [--with-fast]
    usage: bench0174 compare <diar|asr|attrib> <json>...
      diar   A.json B.json [--ref-rttm file [--ref-id id] [--ref-offset s(既定: 結果のstart)]]
      asr    A.json B.json
      attrib ASR.json DIAR_A.json DIAR_B.json
    """

let args = CommandLine.arguments
guard args.count >= 2 else { fail(usage) }
let options = Options(args.dropFirst(2))
switch args[1] {
case "sortformer": try await runSortformer(options, fluidAudio: "0.17.4")
case "nemotron3": try await runNemotron3(options)
case "asr-nemotron": try await runNemotronASR(options)
case "asr-apple": try await runAppleASR(options)
case "compare":
    let rest = Array(options.positional.dropFirst())
    switch options.positional.first {
    case "diar": compareDiar(rest, options)
    case "asr": compareAsr(rest)
    case "attrib": compareAttrib(rest)
    default: fail(usage)
    }
default: fail(usage)
}

// MARK: - Nemotron 3 Diarization

func runNemotron3(_ options: Options) async throws {
    let variant = options.string("variant") ?? "fast32"
    guard let config = Nemotron3Config.preset(named: variant) else { fail("未知のプリセット: \(variant)") }
    let slice = try loadSlice(options)
    var timing = Timing()
    timing.audioSeconds = slice.seconds
    let cache = options.string("models").map { URL(fileURLWithPath: $0, isDirectory: true) }
    let root = cache ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FluidAudio/Models")
    timing.modelCachedBeforeRun = FileManager.default.fileExists(
        atPath: root.appendingPathComponent("nemotron-3-diarization/\(config.hubSubdirectory)/\(config.modelFileName)/coremldata.bin").path)

    var t = now()
    let models = try await Nemotron3Models.loadFromHuggingFace(config: config, cacheDirectory: cache)
    timing.loadSeconds = now() - t
    let diarizer = Nemotron3Diarizer(config: config, models: models)

    // アプリと同じ0.5秒刻みで appendAudio → processBufferedAudio。10ms×8枠の確率を連結する
    var probabilities: [Float] = []
    var lag = LagStats()
    var wait = LagStats()
    var fed = 0
    t = now()
    var i = 0
    while i < slice.samples.count {
        let chunk = Array(slice.samples[i..<min(i + feedStep, slice.samples.count)])
        diarizer.appendAudio(chunk)
        fed += chunk.count
        i += feedStep
        let before = Double(diarizer.streamedFrameCount) * 0.01
        let results = try diarizer.processBufferedAudio()
        for r in results { probabilities.append(contentsOf: r.probabilities) }
        if !results.isEmpty {
            let finalized = Double(diarizer.streamedFrameCount) * 0.01
            lag.samples.append(Double(fed) / Double(sampleRate) - finalized)
            wait.appendFrames(from: before, to: finalized, fedSeconds: Double(fed) / Double(sampleRate))
        }
    }
    timing.processSeconds = now() - t
    t = now()
    let tail = try diarizer.finishStream()
    for r in tail { probabilities.append(contentsOf: r.probabilities) }
    timing.finishSeconds = now() - t

    let frames = probabilities.count / config.numSpeakers
    var notes = [
        "compilationDuration=\(String(format: "%.3f", models.compilationDuration))s",
        "streamedFrames=\(frames) audioFrames(ceil 10ms)=\(Int((slice.seconds * 100).rounded(.up)))",
        "tailChunks=\(tail.count) tailFrames=\(tail.reduce(0) { $0 + $1.frameCount })",
    ]
    if options.flags.contains("check-complete") {
        // 同じ音声の一括処理と照合し、流し方と末尾flushの正しさを確かめる。食い違いは失敗として止める
        let tolerance = Float(options.double("complete-tolerance", 1e-3))
        let c0 = now()
        let complete = try diarizer.processComplete(slice.samples)
        let elapsed = now() - c0
        guard complete.probabilities.count == probabilities.count, complete.frameCount == frames else {
            fail("check-complete: フレーム数が一致しない streaming=\(frames) complete=\(complete.frameCount)")
        }
        var maxDiff: Float = 0
        for k in 0..<probabilities.count { maxDiff = max(maxDiff, abs(complete.probabilities[k] - probabilities[k])) }
        guard maxDiff <= tolerance else { fail("check-complete: 確率の最大差 \(maxDiff) が許容差 \(tolerance) を超える") }
        notes.append("check-complete OK: frames=\(frames) maxAbsDiff=\(maxDiff) tolerance=\(tolerance) completeSeconds=\(String(format: "%.3f", elapsed))")
    }

    let minDuration = Float(options.double("min-duration", 0))
    let duration = slice.seconds
    // 末尾のフレームは10ms単位で切り上がる。区間は実音声の終端で切り、空になったものは捨てる
    let segments = Nemotron3Diarizer.segments(
        probabilities: probabilities, frameCount: frames, numSpeakers: config.numSpeakers,
        threshold: 0.5, frameSeconds: 0.01, minDurationSeconds: minDuration
    ).compactMap { s -> Segment? in
        let start = Double(s.startSeconds), end = min(duration, Double(s.endSeconds))
        return start < end ? Segment(speaker: s.speakerIndex, start: start, end: end) : nil
    }

    if let raw = options.string("probs-out") {
        // 後処理の比較用に生の確率も残す(Float32リトルエンディアン、frames×8)
        let data = probabilities.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: URL(fileURLWithPath: raw))
    }

    try write(DiarizationResult(
        engine: "nemotron3", variant: variant, fluidAudio: "0.17.4",
        wav: slice.path, start: slice.start, audioSeconds: slice.seconds,
        slots: config.numSpeakers, speakersDetected: Set(segments.map(\.speaker)).count,
        configuredBufferSeconds: config.latencySeconds, finalizedLag: lag, frameWait: wait,
        timing: timing, peakRSSMB: peakRSSMB(),
        postprocess: "Nemotron3Diarizer.segments(しきい値0.5、最短長\(minDuration)秒、10msフレーム)",
        notes: notes, segments: segments), to: options)
}

// MARK: - Nemotron 3.5 ASR(多言語・ストリーミング)

func runNemotronASR(_ options: Options) async throws {
    let chunkMs = Int(options.string("chunk-ms") ?? "2240") ?? 2240
    let language = options.string("language") ?? "ja-JP"
    let slice = try loadSlice(options)
    var timing = Timing()
    timing.audioSeconds = slice.seconds
    let cache = options.string("models").map { URL(fileURLWithPath: $0, isDirectory: true) }
    let root = cache ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FluidAudio/Models")
    let dir = StreamingNemotronMultilingualAsrManager.languageDirectory(for: language)
    timing.modelCachedBeforeRun = FileManager.default.fileExists(
        atPath: root.appendingPathComponent("nemotron-multilingual/\(dir)/\(chunkMs)ms/metadata.json").path)

    var t = now()
    let shared = try await StreamingNemotronMultilingualAsrManager.downloadAndPreloadShared(
        languageCode: language, chunkMs: chunkMs, to: cache)
    let manager = StreamingNemotronMultilingualAsrManager()
    try await manager.loadFromShared(shared)
    await manager.setLanguage(language)
    timing.loadSeconds = now() - t

    var lag = LagStats()
    var seen = 0
    var fed = 0
    t = now()
    var i = 0
    while i < slice.samples.count {
        let chunk = Array(slice.samples[i..<min(i + feedStep, slice.samples.count)])
        _ = try await manager.process(samples: chunk)
        fed += chunk.count
        i += feedStep
        let timings = await manager.getTokenTimings()
        if timings.count > seen {
            let at = Double(fed) / Double(sampleRate)
            for tok in timings[seen...] { lag.samples.append(at - tok.endTime) }
            seen = timings.count
        }
    }
    timing.processSeconds = now() - t
    t = now()
    let (text, timings) = try await manager.finishWithTokenTimings()
    timing.finishSeconds = now() - t
    let detected = await manager.detectedLanguage()

    // rawToken は SentencePiece の「▁」を残す。語境界として空白へ戻す
    let tokens = timings.map {
        TimedToken(text: $0.token.replacingOccurrences(of: "▁", with: " "), start: $0.startTime, end: $0.endTime)
    }
    try write(TranscriptionResult(
        engine: "nemotron-asr", variant: "\(dir)/\(chunkMs)ms \(language)",
        wav: slice.path, start: slice.start, audioSeconds: slice.seconds,
        emissionLag: lag, timing: timing, peakRSSMB: peakRSSMB(), text: text,
        notes: [
            "detectedLanguage=\(detected ?? "nil")",
            "トークン時刻はRNN-Tの出力フレーム。end=start+80ms固定で、実発話の境界ではない",
            "process() は同期で chunk を処理するため、emissionLag は計算速度に依らない入力バッファ由来の差",
        ],
        tokens: tokens), to: options)
}

// MARK: - Apple SpeechTranscriber(アプリの AppleTranscriber と同じ設定)

final class FedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add(_ n: Int) { lock.withLock { value += n } }
    var seconds: Double { lock.withLock { Double(value) / Double(sampleRate) } }
}

struct AppleEngine {
    let transcriber: SpeechTranscriber
    let analyzer: SpeechAnalyzer
    let input: AsyncStream<AnalyzerInput>.Continuation
    let format: AVAudioFormat
    let converter: AVAudioConverter?
    /// (確定トークン, 確定トークンごとの待ち, 暫定結果の末尾の遅れ)。
    /// 確定結果は文単位でまとめて届くため、トークンごとに「到着時点の入力済み位置 − トークン終了時刻」を測る。
    /// 暫定結果は語ごとの時刻を持たず区間全体で1つの範囲しか返さない(実測)。末尾の遅れしか測れない
    let collector: Task<([TimedToken], LagStats, LagStats), Error>

    static let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    /// fast はアプリの速報側 (`.fastResults`)。確定結果だけを集める
    static func make(locale: Locale, fast: Bool, fed: FedCounter) async throws -> (AppleEngine, cached: Bool) {
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [],
            reportingOptions: fast ? [.volatileResults, .fastResults] : [.volatileResults],
            attributeOptions: [.audioTimeRange])
        var cached = true
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            cached = false
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { fail("入力形式が取れない") }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)
        let converter = (format.sampleRate == 16000 && format.channelCount == 1 && format.commonFormat == .pcmFormatFloat32)
            ? nil : AVAudioConverter(from: source, to: format)
        let results = transcriber.results
        let collector = Task { () -> ([TimedToken], LagStats, LagStats) in
            var tokens: [TimedToken] = []
            var lag = LagStats()
            var volatileTail = LagStats()
            let trace = ProcessInfo.processInfo.environment["BENCH_TRACE"] == "1"
            for try await result in results {
                let at = fed.seconds
                if trace {
                    let ranges = result.text.runs.compactMap(\.audioTimeRange)
                    log(String(format: "[%@ %@] at=%.2f runs=%d timed=%d first=%.2f last=%.2f range=%.2f-%.2f",
                               fast ? "fast" : "acc", result.isFinal ? "final" : "vol", at, result.text.runs.count, ranges.count,
                               ranges.first?.start.seconds ?? -1, ranges.last?.end.seconds ?? -1,
                               result.range.start.seconds, result.range.end.seconds))
                }
                guard result.isFinal else {
                    if !result.text.characters.isEmpty { volatileTail.samples.append(at - result.range.end.seconds) }
                    continue
                }
                for run in result.text.runs {
                    guard let r = run.audioTimeRange else { continue }
                    tokens.append(TimedToken(text: String(result.text[run.range].characters), start: r.start.seconds, end: r.end.seconds))
                    lag.samples.append(at - r.end.seconds)
                }
            }
            return (tokens, lag, volatileTail)
        }
        return (AppleEngine(transcriber: transcriber, analyzer: analyzer, input: continuation, format: format,
                            converter: converter, collector: collector), cached)
    }

    func feed(_ samples: [Float]) {
        let src = AVAudioPCMBuffer(pcmFormat: Self.source, frameCapacity: AVAudioFrameCount(samples.count))!
        src.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        var buffer = src
        if let converter {
            let dst = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(samples.count) * format.sampleRate / 16000) + 16)!
            var consumed = false
            converter.convert(to: dst, error: nil) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return src
            }
            buffer = dst
        }
        input.yield(AnalyzerInput(buffer: buffer))
    }
}

func runAppleASR(_ options: Options) async throws {
    let slice = try loadSlice(options)
    let realtime = options.flags.contains("realtime")
    let withFast = options.flags.contains("with-fast")
    var timing = Timing()
    timing.audioSeconds = slice.seconds
    timing.realtimeInput = realtime

    var t = now()
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja-JP")) else {
        fail("SpeechTranscriber が ja-JP 非対応")
    }
    let fed = FedCounter()
    let (accurate, cached) = try await AppleEngine.make(locale: locale, fast: false, fed: fed)
    let fast = withFast ? try await AppleEngine.make(locale: locale, fast: true, fed: fed).0 : nil
    timing.modelCachedBeforeRun = cached
    timing.loadSeconds = now() - t

    var i = 0
    while i < slice.samples.count {
        let samples = Array(slice.samples[i..<min(i + feedStep, slice.samples.count)])
        let f0 = now()
        accurate.feed(samples)
        fast?.feed(samples)
        fed.add(samples.count)
        timing.processSeconds += now() - f0
        i += feedStep
        if realtime {
            let w0 = now()
            try await Task.sleep(for: .milliseconds(500))
            timing.paceWaitSeconds += now() - w0
        }
    }
    t = now()
    if let fast {
        fast.input.finish()
        try await fast.analyzer.finalizeAndFinishThroughEndOfInput()
    }
    accurate.input.finish()
    try await accurate.analyzer.finalizeAndFinishThroughEndOfInput()
    let (tokens, lag, accurateVolatile) = try await accurate.collector.value
    let fastResult = try await fast?.collector.value
    timing.finishSeconds = now() - t

    var notes = [
        withFast ? "現行アプリと同じ速報+高精度の2本を同時に流した。tokens/text/emissionLag は高精度側" : "高精度側だけ。現行アプリの速報+高精度の並走ではない",
        realtime
            ? "等倍入力。RTFx は出さない(待ちの間にも非同期に処理が進むため)。emissionLag は確定トークンごとの、到着時点の入力済み位置 − トークン終了時刻"
            : "等倍より速く入力。processSeconds は投入だけで、実処理の大半は finishSeconds に入る。emissionLag は処理待ちを含むので遅延として読まない",
    ]
    func describe(_ s: LagStats) -> String {
        "max=\(String(format: "%.2f", s.max)) median=\(String(format: "%.2f", s.median)) count=\(s.samples.count)"
    }
    notes.append("accurate volatileTail(暫定結果の到着時点の入力済み位置 − 暫定区間の末尾): \(describe(accurateVolatile))")
    if let (fastTokens, fastLag, fastVolatile) = fastResult {
        notes.append("fast finalWait(確定トークンごと): \(describe(fastLag)) chars=\(fastTokens.map(\.text).joined().count)")
        notes.append("fast volatileTail(暫定結果の到着時点の入力済み位置 − 暫定区間の末尾): \(describe(fastVolatile))")
        notes.append("fastText=\(fastTokens.map(\.text).joined())")
    }
    try write(TranscriptionResult(
        engine: "apple-speech", variant: withFast ? "SpeechTranscriber ja-JP 速報+高精度" : "SpeechTranscriber ja-JP 高精度のみ",
        wav: slice.path, start: slice.start, audioSeconds: slice.seconds,
        emissionLag: lag, timing: timing, peakRSSMB: peakRSSMB(),
        text: tokens.map(\.text).joined(), notes: notes, tokens: tokens), to: options)
}
