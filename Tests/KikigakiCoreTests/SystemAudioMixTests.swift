import Testing
@testable import KikigakiCore

struct SystemAudioMixTests {
    @Test func 自動はイヤホンだけでunknownとスピーカーでは取り込まない() {
        #expect(SystemAudioMode.automatic.includes(.headphones))
        #expect(!SystemAudioMode.automatic.includes(.builtInSpeaker))
        #expect(!SystemAudioMode.automatic.includes(.unknown))
        #expect(SystemAudioMode.include.includes(.unknown))
        #expect(!SystemAudioMode.exclude.includes(.headphones))
    }
    @Test func 両系統をゲイン1で足して短い入力も即座に返す() {
        #expect(SystemAudioMixer.process(microphone: [0.125], systemAudio: [0.25]) == [0.375])
        #expect(SystemAudioMixer.process(microphone: [0.25, -0.25], systemAudio: [-0.125, 0.125]) == [0.125, -0.125])
        #expect(SystemAudioMixer.process(microphone: [], systemAudio: []).isEmpty)
    }
    @Test func システム無音なら大小のマイクも同じ値で通す() {
        let microphone: [Float] = [0, 0.0001, -0.004, 0.125, -0.5, 1, -1]
        #expect(SystemAudioMixer.process(microphone: microphone, systemAudio: .init(repeating: 0, count: microphone.count)) == microphone)
        #expect(SystemAudioMixer.process(microphone: .init(repeating: 0, count: microphone.count), systemAudio: microphone) == microphone)
    }
    @Test func 大入力と加算のoverflowも上限内に収める() {
        let output = SystemAudioMixer.process(
            microphone: [1.64, -1.64, 0.75, -0.75, .greatestFiniteMagnitude, -.greatestFiniteMagnitude],
            systemAudio: [0, 0, 0.5, -0.5, .greatestFiniteMagnitude, -.greatestFiniteMagnitude])
        #expect(output == [1, -1, 1, -1, 1, -1])
    }
    @Test func 非有限値は系統ごとにゼロとして扱う() {
        let output = SystemAudioMixer.process(microphone: [.nan, .infinity, -.infinity, 0.25, .nan],
                                             systemAudio: [0.25, -0.5, 0, .nan, .infinity])
        #expect(output == [0.25, -0.5, 0, 0.25, 0])
    }
    @Test func chunkの分け方と前の音声に依存しない() {
        let mic: [Float] = (0..<32111).map { $0 % 400 < 200 ? 0.02 : 0.0002 }
        let system: [Float] = (0..<32111).map { $0 % 700 < 400 ? 0.06 : 0 }
        let expected = SystemAudioMixer.process(microphone: mic, systemAudio: system)
        var actual: [Float] = []
        for start in stride(from: 0, to: mic.count, by: 137) {
            let end = min(start + 137, mic.count)
            actual += SystemAudioMixer.process(microphone: Array(mic[start..<end]), systemAudio: Array(system[start..<end]))
        }
        #expect(actual == expected)
        _ = SystemAudioMixer.process(microphone: [1], systemAudio: [1])
        #expect(SystemAudioMixer.process(microphone: [0.0001], systemAudio: [0]) == [0.0001])
    }
}
