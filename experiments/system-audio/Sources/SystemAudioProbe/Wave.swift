import AVFoundation
import Foundation

enum Wave {
    static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    static func readMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard file.length > 0, Double(file.length) / format.sampleRate <= 3600 else {
            throw ProbeError("音声は0秒より長く1時間以下で指定してください")
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        var mono: [Float] = []
        mono.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { throw ProbeError("音声の途中で読み取りが止まりました") }
            for i in 0..<Int(buffer.frameLength) {
                var sum: Float = 0
                for channel in 0..<Int(format.channelCount) { sum += buffer.floatChannelData![channel][i] }
                mono.append(sum / Float(format.channelCount))
            }
        }
        return format.sampleRate == 16000 ? mono : try convert(mono, rate: format.sampleRate)
    }

    static func paddedPlayback(_ source: [Float], paddingSeconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int((paddingSeconds * 16000).rounded())) + source
    }

    static func convert(_ samples: [Float], rate: Double) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        guard let converter = AVAudioConverter(from: format, to: target) else { throw ProbeError("resampler作成失敗") }
        var supplied = false
        var result: [Float] = []
        while true {
            let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192)!
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .endOfStream; return nil }
                supplied = true
                state.pointee = .haveData
                return input
            }
            if let error { throw error }
            result.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            if status == .endOfStream { break }
            if status == .error || output.frameLength == 0 { throw ProbeError("resamplerが進行しません: \(status.rawValue)") }
        }
        return result
    }

    static func write(_ samples: [Float], to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ProbeError("既存ファイルは上書きしません: \(url.path)") }
        let file = try AVAudioFile(forWriting: url, settings: target.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { file.close() }
        let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192)!
        for start in stride(from: 0, to: samples.count, by: 8192) {
            let count = min(8192, samples.count - start)
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress! + start, count: count) }
            try file.write(from: buffer)
        }
    }

    static func stats(_ samples: [Float]) -> String {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let energy = samples.reduce(Double(0)) { $0 + Double($1) * Double($1) }
        let rms = samples.isEmpty ? 0 : sqrt(energy / Double(samples.count))
        return "frames=\(samples.count) seconds=\(Double(samples.count) / 16000) peak=\(peak) rms=\(rms) nonzero=\(samples.filter { $0 != 0 }.count)"
    }

    static func inspect(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        var frames = 0
        var peak: Float = 0
        var energy = 0.0
        var nonzero = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            for channel in 0..<Int(format.channelCount) {
                for i in 0..<Int(buffer.frameLength) {
                    let value = buffer.floatChannelData![channel][i]
                    peak = max(peak, abs(value)); energy += Double(value) * Double(value)
                    if value != 0 { nonzero += 1 }
                }
            }
            frames += Int(buffer.frameLength)
        }
        let count = frames * Int(format.channelCount)
        print("file=\(url.path) format=\(file.fileFormat) frames=\(frames) seconds=\(Double(frames) / format.sampleRate) peak=\(peak) rms=\(count > 0 ? sqrt(energy / Double(count)) : 0) nonzero=\(nonzero)")
    }
}
