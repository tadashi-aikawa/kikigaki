import AVFoundation
import CoreMedia
import Foundation
import KikigakiCore
import Speech

/// Apple の Speech フレームワーク(macOS 26 の SpeechAnalyzer + SpeechTranscriber、端末内処理)による
/// 文字起こし。プロトの AppleTranscriber の移植。会議1本につき1インスタンス
final class AppleTranscriber {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>
    private let inputIn: AsyncStream<AnalyzerInput>.Continuation
    private let format: AVAudioFormat
    private let converter: AVAudioConverter?
    private let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let store = ResultStore()
    private var resultsTask: Task<Void, Never>?

    /// 確定結果と、まだ揺れる暫定結果を分けて持つ。暫定は最新1件だけ残す
    private actor ResultStore {
        var finalTokens: [TimedToken] = []
        var volatileTokens: [TimedToken] = []
        var phraseCounter = 0
        /// 1つの確定結果(フレーズ)に同じ phrase id を振って保存する。暫定結果は毎回 id を進めて置き換える
        func apply(_ tokens: [TimedToken], isFinal: Bool) {
            phraseCounter += 1
            let stamped = tokens.map { TimedToken(text: $0.text, phraseId: phraseCounter, start: $0.start, end: $0.end) }
            if isFinal {
                finalTokens.append(contentsOf: stamped)
                volatileTokens = []
            } else {
                volatileTokens = stamped
            }
        }
        func all() -> [TimedToken] { finalTokens + volatileTokens }
    }

    init(locale: Locale = Locale(identifier: "ja-JP"), log: @escaping (String) -> Void) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw NSError(domain: "kikigaki", code: 1, userInfo: [NSLocalizedDescriptionKey: "SpeechTranscriber は \(locale.identifier) に未対応"])
        }
        transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            log("Apple Speech の言語アセット(\(supported.identifier))をダウンロード中...")
            try await request.downloadAndInstall()
        }
        analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "kikigaki", code: 2, userInfo: [NSLocalizedDescriptionKey: "SpeechTranscriber の入力フォーマットが取れない"])
        }
        format = best
        converter = (best.sampleRate == 16000 && best.channelCount == 1 && best.commonFormat == .pcmFormatFloat32)
            ? nil : AVAudioConverter(from: sourceFormat, to: best)
        (input, inputIn) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.prepareToAnalyze(in: best)
        try await analyzer.start(inputSequence: input)

        let store = self.store
        let results = transcriber.results
        resultsTask = Task {
            do {
                for try await result in results {
                    var toks: [TimedToken] = []
                    for run in result.text.runs {
                        let piece = String(result.text[run.range].characters)
                        guard let tr = run.audioTimeRange else { continue }
                        toks.append(TimedToken(text: piece, phraseId: 0, start: tr.start.seconds, end: tr.end.seconds))
                    }
                    await store.apply(toks, isFinal: result.isFinal)
                }
            } catch {
                log("Apple Speech results error: \(error)")
            }
        }
    }

    func feed(_ samples: [Float]) throws {
        guard let src = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        src.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { p in src.floatChannelData![0].update(from: p.baseAddress!, count: samples.count) }
        let buffer: AVAudioPCMBuffer
        if let converter {
            let ratio = format.sampleRate / 16000
            guard let dst = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(samples.count) * ratio) + 16) else { return }
            var err: NSError?
            var consumed = false
            converter.convert(to: dst, error: &err) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return src
            }
            if let err { throw err }
            buffer = dst
        } else {
            buffer = src
        }
        // AnalyzerInput に bufferStartTime を明示すると "Audio input timestamp overlaps or precedes prior
        // audio input" で結果ストリームが落ちた(プロトで実測)。連続したバッファなので analyzer 側の
        // 積算に任せる。一時停止中はサンプルを流さないので、積算時刻=会議の実音声時刻のまま
        inputIn.yield(AnalyzerInput(buffer: buffer))
    }

    func tokens() async -> [TimedToken] { await store.all() }

    /// 入力を閉じて最後の確定結果まで待つ
    func finish() async throws -> [TimedToken] {
        inputIn.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        return await store.all()
    }
}
