import AVFoundation
import CoreMedia
import Foundation
import KikigakiCore
import Speech

/// Apple の Speech フレームワーク(macOS 26 の SpeechAnalyzer + SpeechTranscriber、端末内処理)による
/// 文字起こし。会議1本につき1インスタンス。
///
/// 速報を使うときは、同じ音声を速報用と高精度用の2つのエンジンへ流す。Apple Speech は約11.6秒ぶんの
/// 音声をためてから結果を返すため、単独では発話から6〜13秒遅れる(実測)。`.fastResults` を足した
/// エンジンは1〜3秒で返す代わりに認識が粗く、確定した文字は訂正されないので、粗いまま保存はできない。
/// 2本立てにして、高精度が追いついた範囲だけ差し替える
final class AppleTranscriber {
    /// 1つの SpeechAnalyzer + SpeechTranscriber。速報用と高精度用で同じものを使う
    private final class Engine {
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let inputIn: AsyncStream<AnalyzerInput>.Continuation
        let format: AVAudioFormat
        let converter: AVAudioConverter?
        var resultsTask: Task<Void, Never>?
        private let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

        init(locale: Locale, fast: Bool, log: (String) -> Void) async throws {
            transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: fast ? [.volatileResults, .fastResults] : [.volatileResults],
                attributeOptions: [.audioTimeRange])
            // prepareより先にアセットを揃える。未取得の端末でも初回起動を成立させる。
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                log("Apple Speech の言語アセット(\(locale.identifier))をダウンロード中...")
                try await request.downloadAndInstall()
            }
            analyzer = SpeechAnalyzer(modules: [transcriber])
            guard let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw NSError(domain: "kikigaki", code: 2, userInfo: [NSLocalizedDescriptionKey: "SpeechTranscriber の入力フォーマットが取れない"])
            }
            format = best
            converter = (best.sampleRate == 16000 && best.channelCount == 1 && best.commonFormat == .pcmFormatFloat32)
                ? nil : AVAudioConverter(from: sourceFormat, to: best)
            let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            inputIn = continuation
            try await analyzer.prepareToAnalyze(in: best)
            try await analyzer.start(inputSequence: input)
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
    }

    /// 確定結果と、まだ揺れる暫定結果を分けて持つ。暫定は最新1件だけ残す
    private struct ResultStore {
        var finalTokens: [TimedToken] = []
        var volatileTokens: [TimedToken] = []
        var phraseCounter = 0
        /// 1つの確定結果(フレーズ)に同じ phrase id を振って保存する。暫定結果は毎回 id を進めて置き換える
        mutating func apply(_ tokens: [TimedToken], isFinal: Bool) {
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
        /// 確定・暫定を合わせたトークン列と、先頭から確定結果に属する個数
        func snapshot() -> (tokens: [TimedToken], finalCount: Int) { (finalTokens + volatileTokens, finalTokens.count) }
    }

    /// 2本の更新と合成を同じactorで扱う。別々に読んだ古い高精度が後着して表示を戻さない。
    private actor CombinedStore {
        var accurate = ResultStore()
        var fast = ResultStore()
        let usesFastResults: Bool

        init(usesFastResults: Bool) { self.usesFastResults = usesFastResults }

        func apply(_ tokens: [TimedToken], isFinal: Bool, isFast: Bool,
                   receivedAt: Double, trace: Bool, log: (String) -> Void,
                   onResult: (([TimedToken], Int) async -> Void)?) async {
            if isFast { fast.apply(tokens, isFinal: isFinal) }
            else { accurate.apply(tokens, isFinal: isFinal) }
            let value = snapshot()
            if trace && isFinal {
                log(String(format: "[asr-final engine=%@ count=%d received=%.6f]",
                           isFast ? "fast" : "accurate", value.finalCount, receivedAt))
            }
            await onResult?(value.tokens, value.finalCount)
        }

        func snapshot() -> TranscriptMerge.Snapshot {
            let base = accurate.snapshot()
            guard usesFastResults else {
                return .init(tokens: base.tokens, finalCount: base.finalCount, accurateFinalCount: base.finalCount)
            }
            let ahead = fast.snapshot()
            return TranscriptMerge.combine(accurate: base.tokens, accurateFinalCount: base.finalCount,
                                           fast: ahead.tokens, fastFinalCount: ahead.finalCount)
        }

        func tokens() -> [TimedToken] { accurate.all() }
    }

    private let accurate: Engine
    private let store: CombinedStore
    /// 速報用。保存には使わず、高精度が追いつくまでの先頭を埋める
    private let fast: Engine?
    /// 速報の生成に成功した会議だけ、AI送信で文字の確定待ちを省く
    var hasFastResults: Bool { fast != nil }

    init(locale: Locale = Locale(identifier: "ja-JP"), log: @escaping (String) -> Void,
         usesFastResults: Bool = false,
         onResult: (([TimedToken], Int) async -> Void)? = nil) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw NSError(domain: "kikigaki", code: 1, userInfo: [NSLocalizedDescriptionKey: "SpeechTranscriber は \(locale.identifier) に未対応"])
        }
        accurate = try await Engine(locale: supported, fast: false, log: log)
        // 速報は表示を早めるだけの付加機能。用意できなくても会議は高精度側だけで成立させる
        var speculative: Engine?
        if usesFastResults {
            do { speculative = try await Engine(locale: supported, fast: true, log: log) }
            catch { log("速報用の文字起こしを用意できません。確定を待って表示します: \(error)") }
        }
        fast = speculative
        store = CombinedStore(usesFastResults: speculative != nil)

        let trace = Diagnostics().showsLiveTrace
        let store = self.store
        for (engine, isFast) in [(accurate, false), (fast, true)] {
            guard let engine else { continue }
            let results = engine.transcriber.results
            engine.resultsTask = Task {
                do {
                    for try await result in results {
                        let receivedAt = ProcessInfo.processInfo.systemUptime
                        var toks: [TimedToken] = []
                        for run in result.text.runs {
                            let piece = String(result.text[run.range].characters)
                            guard let tr = run.audioTimeRange else { continue }
                            toks.append(TimedToken(text: piece, phraseId: 0, start: tr.start.seconds, end: tr.end.seconds))
                        }
                        await store.apply(toks, isFinal: result.isFinal, isFast: isFast,
                                          receivedAt: receivedAt, trace: trace, log: log, onResult: onResult)
                    }
                } catch {
                    log("Apple Speech results error(\(isFast ? "fast" : "accurate")): \(error)")
                }
            }
        }
    }

    func feed(_ samples: [Float]) throws {
        try accurate.feed(samples)
        try fast?.feed(samples)
    }

    /// 保存に使うのは高精度側だけ。速報の粗い文字を残さない
    func tokens() async -> [TimedToken] { await store.tokens() }

    /// 表示・AIへ渡す合成結果。話者の凍結は高精度側の確定数だけを使う
    func snapshot() async -> TranscriptMerge.Snapshot {
        await store.snapshot()
    }

    /// 入力を閉じて最後の確定結果まで待つ。速報側は結果を捨てて止める
    func finish() async throws -> [TimedToken] {
        if let fast {
            fast.inputIn.finish()
            await fast.analyzer.cancelAndFinishNow()
            fast.resultsTask?.cancel()
        }
        accurate.inputIn.finish()
        try await accurate.analyzer.finalizeAndFinishThroughEndOfInput()
        await accurate.resultsTask?.value
        return await store.tokens()
    }
}
