import FluidAudio
import Foundation
import KikigakiCore

/// Sortformer(FluidAudio)のモデル。初回は HuggingFace から
/// ~/Library/Application Support/FluidAudio/Models へ落ちるため、起動時に一度だけ読み込んで使い回す
enum SortformerModelStore {
    /// 品質を優先し、既定は High Context(出力遅延 ≈30.4秒)。
    /// 環境変数で比較用モデルを選ぶ。各モデルは初回に HuggingFace から取得する。
    static let config: SortformerConfig = {
        switch ProcessInfo.processInfo.environment["KIKIGAKI_SORTFORMER"] {
        case "balanced": return .balancedV2_1
        case "fast": return .fastV2_1
        default: return .highContextV2_1
        }
    }()

    /// 読み込んだモデル。SortformerModels は Sendable でないが読み込み後は不変なので、Task の
    /// 境界をまたいで渡すための箱
    struct Loaded: @unchecked Sendable {
        let models: SortformerModels
    }

    static func load() async throws -> Loaded {
        Loaded(models: try await SortformerModels.loadFromHuggingFace(config: config))
    }
}

/// 話者判別。会議1本につき1インスタンス(スロット A〜D は会議ごとに振り直される)
final class SpeakerDiarizer {
    private let diarizer: SortformerDiarizer
    private var receivedSamples = 0
    private var finished = false

    /// モデルが確定予測を返した範囲。アプリの固定猶予とは独立して扱う。
    var finalizedDuration: Double { Double(diarizer.timeline.finalizedDuration) }

    init(models: SortformerModelStore.Loaded) {
        diarizer = SortformerDiarizer(config: SortformerModelStore.config)
        diarizer.initialize(models: models.models)
    }

    func process(_ samples: [Float]) throws {
        guard !finished else { return }
        receivedSamples += samples.count
        _ = try diarizer.process(samples: samples)
    }

    /// 残りの暫定区間を確定させる。停止時に一度だけ呼ぶ
    func finish() throws {
        guard !finished else { return }
        // FluidAudio 0.15.6は末尾の不完全なチャンクを推論せず最終化する。
        // High Contextでは数十秒が未判定になり得るため、話者エンジンだけへ無音を足す。
        // WAV・ASR・録音時間には加えず、返す区間も実音声の終端で切る。
        let config = SortformerModelStore.config
        if config.chunkLen == SortformerConfig.highContextV2_1.chunkLen, receivedSamples > 0 {
            let padding = (config.chunkLen + config.chunkRightContext + 1) * config.subsamplingFactor * config.melStride + config.melWindow
            _ = try diarizer.process(samples: [Float](repeating: 0, count: padding))
        }
        _ = try diarizer.finalizeSession()
        finished = true
    }

    /// 確定区間+暫定区間。暫定区間は連続発話の長さぶん過去へ届くので、表示側で凍結して扱う
    func segments() -> [SpeakerSegment] {
        let duration = Double(receivedSamples) / 16000
        return diarizer.timeline.speakers.values.flatMap { speaker in
            (speaker.finalizedSegments + speaker.tentativeSegments).compactMap { segment -> SpeakerSegment? in
                let start = Double(segment.startTime), end = min(duration, Double(segment.endTime))
                guard start < end else { return nil }
                return SpeakerSegment(speaker: segment.speakerIndex, start: start, end: end)
            }
        }
    }

    func cleanup() {
        diarizer.cleanup()
    }
}
