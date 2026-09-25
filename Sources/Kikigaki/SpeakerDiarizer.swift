import FluidAudio
import Foundation
import KikigakiCore

/// Nemotron 3 Diarization(FluidAudio)の fast128。初回は HuggingFace から
/// ~/Library/Application Support/FluidAudio/Models へ約193MB落ちる。有効なときだけ先読みして使い回す
enum DiarizationModels {
    /// 10.24秒の chunk と0.32秒の右文脈。chunk の先頭から10.56秒ぶんの入力が溜まると、その chunk の判定が出る。
    /// 出た判定は後から変わらない。アプリの話者固定猶予とは別の値
    static let config = Nemotron3Config.fast128

    /// 読み込んだモデル。Nemotron3Models は Sendable でないが読み込み後は不変なので、Task の
    /// 境界をまたいで渡すための箱
    struct Loaded: @unchecked Sendable {
        let models: Nemotron3Models
    }

    static func load() async throws -> Loaded {
        Loaded(models: try await Nemotron3Models.loadFromHuggingFace(config: config))
    }
}

/// 話者判別。会議1本につき1インスタンス(スロット A〜H は会議ごとに振り直される)
final class SpeakerDiarizer {
    private let diarizer: Nemotron3Diarizer
    private var runs: SpeakerRuns
    private var receivedSamples = 0
    private var finished = false
    /// 最初の失敗。FluidAudio は入力位置を進めてから推論するので、失敗した chunk を飛ばして続けると
    /// 以後の判定が chunk 単位で前へずれる。失敗後はエンジンを呼ばず、判定済みの区間だけを使う
    private var failure: Error?

    private var receivedDuration: Double { Double(receivedSamples) / 16000 }
    /// 判定済みの範囲。受け取った音声の長さを超えない
    var finalizedDuration: Double { min(runs.judgedSeconds, receivedDuration) }

    init(models: DiarizationModels.Loaded) {
        diarizer = Nemotron3Diarizer(config: DiarizationModels.config, models: models.models)
        runs = SpeakerRuns(speakerCount: DiarizationModels.config.numSpeakers)
    }

    /// 失敗したときだけ投げる。投げるのは最初の1回で、以後は何もしない
    func process(_ samples: [Float]) throws {
        guard !finished, failure == nil else { return }
        receivedSamples += samples.count
        diarizer.appendAudio(samples)
        try run { try diarizer.processBufferedAudio() }
    }

    /// 末尾の chunk を詰めて判定する。停止時に一度だけ呼ぶ。録音中に失敗していたらその失敗を投げる
    func finish() throws {
        guard !finished else { return }
        finished = true
        if let failure { throw failure }
        // 空の入力の末尾処理を FluidAudio の契約に頼らない
        guard receivedSamples > 0 else { return }
        try run { try diarizer.finishStream() }
    }

    private func run(_ produce: () throws -> [Nemotron3ChunkResult]) throws {
        do {
            let chunks = try produce().map { ($0.probabilities, $0.frameCount, $0.numSpeakers) }
            try runs.append(chunks: chunks, totalFrames: diarizer.streamedFrameCount)
        } catch {
            failure = error
            throw error
        }
    }

    /// 閉じた区間と、判定済みの末尾で切った発話中の区間
    func segments() -> [SpeakerSegment] {
        runs.segments(until: receivedDuration)
    }
}
