import Foundation
import Testing
@testable import KikigakiCore

@Suite struct SpeakerIdentityTests {
    @Test func 分裂した三番目の声を元の話者へ統合する() {
        var identity = SpeakerIdentity(limit: 2)
        identity.observe(slot: 0, embedding: [1, 0, 0])
        identity.observe(slot: 1, embedding: [0, 1, 0])
        identity.observe(slot: 2, embedding: [0.98, 0.02, 0])
        #expect(identity.mapping == [0: 0, 1: 1, 2: 0])
        #expect(identity.anchors == [0, 1])
    }

    @Test func 分裂枠が先に現れても人数を使い切らない() {
        var identity = SpeakerIdentity(limit: 2)
        identity.observe(slot: 0, embedding: [1, 0])
        identity.observe(slot: 2, embedding: [0.99, 0.01])
        identity.observe(slot: 1, embedding: [0, 1])
        #expect(identity.mapping == [0: 0, 2: 0, 1: 1])
    }

    @Test func 同点や似ていない余剰話者は不明のままにする() {
        var identity = SpeakerIdentity(limit: 2)
        identity.observe(slot: 0, embedding: [1, 0, 0])
        identity.observe(slot: 1, embedding: [0, 1, 0])
        identity.observe(slot: 2, embedding: [1, 1, 0])
        identity.observe(slot: 3, embedding: [0, 0, 1])
        #expect(identity.mapping[2] == nil)
        #expect(identity.mapping[3] == nil)
        #expect(identity.mapping.values.count == 2)
    }

    @Test func 不正特徴は基準を汚さず後で再試行できる() {
        var identity = SpeakerIdentity(limit: 2)
        for bad: [Float] in [[], [0, 0], [.nan, 1], [.infinity, 1]] {
            let accepted = identity.observe(slot: 0, embedding: bad)
            #expect(!accepted)
        }
        #expect(identity.profiles.isEmpty)
        let valid = identity.observe(slot: 0, embedding: [1, 0])
        let wrongSize = identity.observe(slot: 1, embedding: [1])
        let wrongSlot = identity.observe(slot: 4, embedding: [1, 0])
        #expect(valid)
        #expect(!wrongSize)
        #expect(!wrongSlot)
        #expect(SpeakerIdentity.cosine([1], [1, 2]) == nil)
    }

    @Test func 特徴数の上限と会議間の初期化() {
        var identity = SpeakerIdentity(limit: 1)
        for _ in 0..<10 { identity.observe(slot: 0, embedding: [1, 0]) }
        #expect(identity.profiles[0]?.count == 3)
        #expect(SpeakerIdentity(limit: 1).mapping.isEmpty)
    }

    @Test func 自動無しは完全に元の判定を残し手動は解除できる() {
        let raw: [Int?] = [0, 2, nil, 1]
        var mapping = SpeakerMapping()
        #expect(mapping.apply(raw) == raw)
        mapping.overrides[2] = 0
        #expect(mapping.apply(raw) == [0, 0, nil, 1])
        mapping.overrides[2] = nil
        #expect(mapping.apply(raw) == raw)
    }

    @Test func 手動訂正が優先し直接指定なので循環せず自分へ戻せる() {
        var mapping = SpeakerMapping(limited: true, automatic: [0: 0, 1: 1, 2: 0])
        mapping.overrides = [0: 1, 1: 0, 2: 2]
        #expect(mapping.apply([0, 1, 2, 3, nil]) == [1, 0, 2, nil, nil])
        mapping.overrides[2] = nil
        #expect(mapping.destination(for: 2) == 0)
    }

    @Test func 音声採取では重複と短い声を除きバッファ範囲を守る() {
        let segments = [SpeakerSegment(speaker: 0, start: 0, end: 12),
                        SpeakerSegment(speaker: 1, start: 4, end: 7),
                        SpeakerSegment(speaker: 2, start: 13, end: 13.5)]
        let ranges = SpeakerVoiceSamples.ranges(segments: segments, after: [:], bufferStart: 1, until: 14)
        #expect(ranges.count == 1)
        #expect(ranges[0].speaker == 0)
        #expect(ranges[0].start > 7 && ranges[0].end < 12)
        #expect(SpeakerVoiceSamples.ranges(segments: segments, after: [0: 11], bufferStart: 10, until: 12).isEmpty)
    }

    @Test func 人数設定は省略互換と値域を検証する() throws {
        #expect(ResolvedConfig(config: try ConfigLoader.parse(toml: "")).maxSpeakers == nil)
        for maximum in 1...4 {
            #expect(ResolvedConfig(config: try ConfigLoader.parse(toml: "maxSpeakers = \(maximum)")).maxSpeakers == maximum)
        }
        for maximum in [0, 5, -1] {
            #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: "maxSpeakers = \(maximum)") }
        }
    }
}
