import FluidAudio
import Foundation
import KikigakiCore

/// Sortformer(FluidAudio)のモデル。初回は HuggingFace から
/// ~/Library/Application Support/FluidAudio/Models へ落ちるため、起動時に一度だけ読み込んで使い回す
enum SortformerModelStore {
    /// プリセットは fast(遅延 ≈1.0秒)。プロトの読み比べで使った構成をそのまま採る。
    /// 環境変数 `KIKIGAKI_SORTFORMER=balanced` で balanced(同じ遅延、FIFO 40→188)へ切り替える。
    /// 左右比較のための開発用の口で、既定は変えない。balanced のモデルは初回に HuggingFace から落ちる
    static let config: SortformerConfig =
        ProcessInfo.processInfo.environment["KIKIGAKI_SORTFORMER"] == "balanced" ? .balancedV2_1 : .fastV2_1

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

    init(models: SortformerModelStore.Loaded) {
        diarizer = SortformerDiarizer(config: SortformerModelStore.config)
        diarizer.initialize(models: models.models)
    }

    func process(_ samples: [Float]) throws {
        _ = try diarizer.process(samples: samples)
    }

    /// 残りの暫定区間を確定させる。停止時に一度だけ呼ぶ
    func finish() throws {
        _ = try diarizer.finalizeSession()
    }

    /// 確定区間+暫定区間。暫定区間は連続発話の長さぶん過去へ届くので、表示側で凍結して扱う
    func segments() -> [SpeakerSegment] {
        diarizer.timeline.speakers.values.flatMap { speaker in
            (speaker.finalizedSegments + speaker.tentativeSegments).map {
                SpeakerSegment(speaker: $0.speakerIndex, start: Double($0.startTime), end: Double($0.endTime))
            }
        }
    }

    func cleanup() {
        diarizer.cleanup()
    }
}
