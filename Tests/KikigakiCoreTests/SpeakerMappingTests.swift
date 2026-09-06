import Testing
@testable import KikigakiCore

@Suite struct SpeakerMappingTests {
    @Test func 未指定は元の判定を残し手動統合は解除できる() {
        let raw: [Int?] = [0, 2, nil, 1]
        var mapping = SpeakerMapping()
        #expect(mapping.apply(raw) == raw)
        mapping.overrides[2] = 0
        #expect(mapping.apply(raw) == [0, 0, nil, 1])
        mapping.overrides[2] = nil
        #expect(mapping.apply(raw) == raw)
    }

    @Test func 直接指定なので循環せず解除すると元の話者に戻る() {
        var mapping = SpeakerMapping(overrides: [0: 1, 1: 0, 2: 2])
        #expect(mapping.apply([0, 1, 2, 3, nil]) == [1, 0, 2, 3, nil])
        mapping.overrides[2] = nil
        #expect(mapping.destination(for: 2) == 2)
    }

    @Test func 廃止した人数上限が設定に残っていても読み込める() throws {
        let config = try ConfigLoader.parse(toml: "maxSpeakers = 2\nsaveRecording = true")
        #expect(ResolvedConfig(config: config).saveRecording)
    }
}
