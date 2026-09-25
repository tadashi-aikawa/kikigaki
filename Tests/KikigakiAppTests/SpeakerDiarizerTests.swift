import Foundation
import Testing
import KikigakiCore
@testable import Kikigaki

/// 実モデルを使う結合検証。初回はモデルを取得するため、`KIKIGAKI_TEST_DIARIZATION=1` のときだけ走らせる
@Suite struct SpeakerDiarizerTests {
    /// 引数ごとに並列で取得すると同じ置き場へ同時に書いて壊れる。アプリと同じく読込を1回に共有する
    static let models = Task { try await DiarizationModels.load() }

    @Test(arguments: [0, 1_600, 48_000, 168_960, 170_000])
    func 短い入力とchunk境界の前後でも末尾処理で落ちず実音声を超えない(samples: Int) async throws {
        guard ProcessInfo.processInfo.environment["KIKIGAKI_TEST_DIARIZATION"] == "1" else { return }
        let diarizer = SpeakerDiarizer(models: try await Self.models.value)
        // 決定的な小さい雑音。発話の有無は問わず、末尾処理と長さの扱いだけを見る
        var state: UInt32 = 1
        let audio = (0..<samples).map { _ -> Float in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.2
        }
        var offset = 0
        while offset < audio.count {
            try diarizer.process(Array(audio[offset..<min(offset + 8_000, audio.count)]))
            offset += 8_000
        }
        try diarizer.finish()
        let duration = Double(samples) / 16_000
        #expect(diarizer.finalizedDuration <= duration)
        #expect(samples == 0 || diarizer.finalizedDuration > duration - SpeakerRuns.frameSeconds)
        #expect(diarizer.segments().allSatisfy { $0.start < $0.end && $0.end <= duration && (0..<8).contains($0.speaker) })
    }
}
