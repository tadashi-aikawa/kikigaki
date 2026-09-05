import AVFoundation
import Foundation
import Testing

@testable import KikigakiCore

@Suite struct AudioResamplerTests {
    private static let chunk = 4096

    private static func format(rate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    }

    /// 440Hz と 2200Hz を重ねた合成信号。どちらも 16kHz のナイキストより十分低い
    private static func tone(rate: Double, frames: Int) -> [Float] {
        (0..<frames).map { n in
            let t = Double(n) / rate
            return Float(0.4 * sin(2 * .pi * 440 * t) + 0.4 * sin(2 * .pi * 2200 * t))
        }
    }

    private static func buffer(_ samples: ArraySlice<Float>, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<Int(format.channelCount) {
            for (i, value) in samples.enumerated() { buffer.floatChannelData![channel][i] = value }
        }
        return buffer
    }

    /// 4096 フレームずつ流したときの 16kHz 出力
    private static func resampleInChunks(_ samples: [Float], format: AVAudioFormat) throws -> [Float] {
        let resampler = AudioResampler(from: format)
        #expect(resampler != nil)
        var output: [Float] = []
        var i = 0
        while i < samples.count {
            let end = min(i + chunk, samples.count)
            output += try resampler!.resample(buffer(samples[i..<end], format: format))
            i = end
        }
        return output
    }

    /// 指定した周波数の正弦波成分だけを取り出し、それ以外(折り返し・境界の過渡)の実効値を返す。
    /// 変換器の遅延で位相がずれても値が変わらないよう、成分の当てはめで比較する
    private static func residualRMS(_ signal: [Float], rate: Double, frequencies: [Double]) -> Double {
        let values = signal.map(Double.init)
        var fitted = [Double](repeating: 0, count: values.count)
        for frequency in frequencies {
            var sine = 0.0, cosine = 0.0
            for (n, value) in values.enumerated() {
                let phase = 2 * .pi * frequency * Double(n) / rate
                sine += value * sin(phase)
                cosine += value * cos(phase)
            }
            let a = 2 * sine / Double(values.count), b = 2 * cosine / Double(values.count)
            for n in fitted.indices {
                let phase = 2 * .pi * frequency * Double(n) / rate
                fitted[n] += a * sin(phase) + b * cos(phase)
            }
        }
        let squared = zip(values, fitted).reduce(0.0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
        return (squared / Double(values.count)).squareRoot()
    }

    @Test func バッファ境界の過渡なく48kHzを16kHzへ変換する() throws {
        let source = Self.format(rate: 48000, channels: 1)
        let input = Self.tone(rate: 48000, frames: Self.chunk * 100)
        let output = try Self.resampleInChunks(input, format: source)
        // 変換器の遅延ぶんの立ち上がりと終端を外し、定常部分だけを見る
        let steady = Array(output[2000..<(output.count - 200)])
        let residual = Self.residualRMS(steady, rate: 16000, frequencies: [440, 2200])
        // 無状態の変換では 85ms ごとにクリック状の過渡が入り、この値が桁で大きくなる
        #expect(residual < 0.001, "残差 \(residual)")
    }

    @Test func 出力サンプル数が入力の3分の1から累積してずれない() throws {
        let source = Self.format(rate: 48000, channels: 1)
        func shortfall(chunks: Int) throws -> Double {
            let input = Self.tone(rate: 48000, frames: Self.chunk * chunks)
            let output = try Self.resampleInChunks(input, format: source)
            return Double(input.count) / 3 - Double(output.count)
        }
        let short = try shortfall(chunks: 50)
        let long = try shortfall(chunks: 200)
        // 差は変換器の一定の遅延だけ。バッファごとに変換器を作り直すと1回 0.33 サンプル失い、
        // 150 バッファぶん(約50サンプル)の差になる
        #expect(abs(long - short) < 2, "50バッファ \(short) / 200バッファ \(long)")
    }

    @Test func 既に16kHzモノラルなら変換しない() throws {
        let source = Self.format(rate: 16000, channels: 1)
        let input = Self.tone(rate: 16000, frames: Self.chunk * 3)
        let output = try Self.resampleInChunks(input, format: source)
        #expect(output == input)
    }

    @Test(arguments: [(44100.0, AVAudioChannelCount(1)), (48000.0, AVAudioChannelCount(2))])
    func 別のサンプリングレートやステレオでも16kHzモノラルになる(_ rate: Double, _ channels: AVAudioChannelCount) throws {
        let source = Self.format(rate: rate, channels: channels)
        let input = Self.tone(rate: rate, frames: Self.chunk * 60)
        let output = try Self.resampleInChunks(input, format: source)
        // ずれは変換器の一定の遅延ぶん(48kHz mono で約576サンプル=36ms)だけ
        #expect(abs(Double(input.count) * 16000 / rate - Double(output.count)) < 1000)
        let steady = Array(output[2000..<(output.count - 200)])
        #expect(Self.residualRMS(steady, rate: 16000, frequencies: [440, 2200]) < 0.001)
    }

    @Test func 途中で入力形式が変わったら変換器を作り直す() throws {
        let resampler = AudioResampler(from: Self.format(rate: 48000, channels: 1))
        let first = Self.tone(rate: 48000, frames: Self.chunk)
        #expect(try !resampler!.resample(Self.buffer(first[...], format: Self.format(rate: 48000, channels: 1))).isEmpty)
        // デバイス切り替え。前の形式のフィルタ状態は捨ててよい
        let second = Self.tone(rate: 44100, frames: Self.chunk)
        let output = try resampler!.resample(Self.buffer(second[...], format: Self.format(rate: 44100, channels: 1)))
        #expect(!output.isEmpty)
    }
}
