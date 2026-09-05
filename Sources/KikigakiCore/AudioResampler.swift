// 変換の入力ブロックは @Sendable だが、`convert` の中から同じスレッドで同期に呼ばれる。
// Swift 6 モードの Sendable 検査を通すため、AVFoundation は @preconcurrency で取り込む
@preconcurrency import AVFoundation

/// 音源のバッファを、Sortformer と Apple Speech が受け取る 16kHz mono Float32 へ変換する。
///
/// バッファごとに `AVAudioConverter` を作り直す無状態の変換は、リサンプリングのフィルタ状態が
/// 毎回初期化されるため、48kHz・4096フレームなら 85ms ごとに立ち上がりと立ち下がりが入る。
/// 440Hz+2200Hz の合成信号で、正弦波以外に残る実効値がブロック内だけでも 0.0415(常設は
/// 0.00063)。ブロックをまたぐと位相が繋がらず、波形として連続しない(実測)。
/// 変換器を持ち越し、`noDataNow` で1バッファずつ流して状態を継続させる。
/// 時間のずれは、無状態でも排出まで行えば1時間で 0.02 秒ほどで、精度への影響はこちらではない。
///
/// 変換は音声スレッドからだけ呼ぶ前提で、内部状態にロックを持たない。
public final class AudioResampler {
    /// 変換先。KIKIGAKI のパイプラインが受け取る唯一の形式
    public static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    private var sourceFormat: AVAudioFormat
    /// 変換先と同じ形式で入ってくる場合は nil(変換しない)
    private var converter: AVAudioConverter?

    /// 入力形式が変換先と同じなら変換器を作らない。作れない組み合わせなら nil を返す
    public init?(from source: AVAudioFormat) {
        sourceFormat = source
        converter = nil
        guard !Self.isTarget(source) else { return }
        guard let converter = Self.makeConverter(from: source) else { return nil }
        self.converter = converter
    }

    /// 1バッファぶんの 16kHz mono Float32 サンプル。変換器の遅延ぶん、返る数は入力比とずれる
    public func resample(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        // デバイス切り替えで入力形式が変わったら変換器を作り直す。音声そのものが不連続になる
        // 場面なので、フィルタ状態を捨てて構わない。作り直せない形式は音を落として次に備える
        if !buffer.format.isEqual(sourceFormat) {
            sourceFormat = buffer.format
            converter = Self.isTarget(buffer.format) ? nil : Self.makeConverter(from: buffer.format)
            if !Self.isTarget(buffer.format) && converter == nil { return [] }
        }
        guard let converter else { return Self.samples(of: buffer) }
        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        // 変換器が前のバッファぶんを吐き出すことがあるので、比から求めた数に余裕を足す
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return [] }
        var error: NSError?
        let gate = InputGate(buffer)
        converter.convert(to: output, error: &error) { _, status in
            // 1回だけ入力を渡し、あとは noDataNow。endOfStream にすると変換器が終端まで
            // 吐き出して状態を捨ててしまい、無状態の変換と同じになる
            guard let next = gate.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return next
        }
        if let error { throw error }
        return Self.samples(of: output)
    }

    /// 入力ブロックへ「1回だけ渡す」ための箱。`convert` から同じスレッドで同期に呼ばれるだけで
    /// スレッドをまたがないため @unchecked Sendable でよい
    private final class InputGate: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }

    private static func isTarget(_ format: AVAudioFormat) -> Bool {
        format.sampleRate == targetFormat.sampleRate && format.channelCount == 1
            && format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved
    }

    private static func makeConverter(from source: AVAudioFormat) -> AVAudioConverter? {
        guard let converter = AVAudioConverter(from: source, to: targetFormat) else { return nil }
        // 無状態の変換(FluidAudio の AudioConverter)と同じ品質設定。差を状態の有無だけにする
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        return converter
    }

    private static func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
