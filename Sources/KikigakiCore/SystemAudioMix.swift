/// 選択と3値判定はHALから独立させる。unknownで取り込まないのは対面会議を優先するため。
public enum SystemAudioMode: String, CaseIterable, Sendable {
    case automatic, include, exclude
    public func includes(_ output: AudioOutputKind) -> Bool {
        self == .include || (self == .automatic && output == .headphones)
    }
}
public enum AudioOutputKind: Sendable { case headphones, builtInSpeaker, unknown }

/// 16kHzの2系統をゲイン1で足す。HALとreplayで同じ処理を使う。
/// 交互発話の実測では音量を揃えなくても文字になったため、先読みやゲイン調整を持たない。
/// 有限で±1以内のマイク入力は、システムが無音ならそのまま出る。和のピークだけ保護する。
public enum SystemAudioMixer {
    public static func process(microphone: [Float], systemAudio: [Float]) -> [Float] {
        precondition(microphone.count == systemAudio.count)
        return zip(microphone, systemAudio).map { microphone, systemAudio in
            let mic = microphone.isFinite ? microphone : 0
            let system = systemAudio.isFinite ? systemAudio : 0
            return max(-1, min(1, mic + system))
        }
    }
}
