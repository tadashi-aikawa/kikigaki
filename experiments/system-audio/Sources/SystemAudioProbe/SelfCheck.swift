import AVFoundation
import CoreAudio
import Foundation
// Offline checks: no HAL device, TCC request, or audio playback is used.
func runSelfChecks() throws {
    interleavedMicAndStereoTapUseCommonFrames()
    splitMicAndTapBuffersPreserveChannelOrder()
    unequalBufferFrameCountsAreRejected()
    discontinuityIsDetectedInsteadOfSilentlyCompressingTime()
    try resampleAndWavRoundTripRetainDurationAndFloatFormat()
    microphonePermissionDecisions()
    playbackPaddingPreservesEverySourceFrame()
    knownPositiveAndNegativeLags()
    weakAndAmbiguousCorrelationIsRejected()
    headAndTailDetectChangingDelay()
    print("成功: オフライン検証10件。channel分離、異なるフレーム数の拒否、時刻欠落、変換、許可判断、無音前置き、相互相関を確認しました。")
}

private func microphonePermissionDecisions() {
    precondition(MicrophoneDecision.decide(.notDetermined, elapsed: 59.9) == .wait)
    precondition(MicrophoneDecision.decide(.notDetermined, elapsed: 60) == .timeout)
    precondition(MicrophoneDecision.decide(.authorized, elapsed: 61) == .record)
    precondition(MicrophoneDecision.decide(.denied, elapsed: 1) == .denied)
    precondition(MicrophoneDecision.decide(.restricted, elapsed: 1) == .restricted)
}

private func playbackPaddingPreservesEverySourceFrame() {
    let source: [Float] = [0.1, 0.3, -0.2, 0.7]
    let playback = Wave.paddedPlayback(source, paddingSeconds: 5)
    precondition(playback.count == 80000 + source.count)
    precondition(playback.prefix(80000).allSatisfy { $0 == 0 })
    precondition(Array(playback.suffix(source.count)) == source)
}

private func randomEnvelope(_ count: Int, seed: UInt64) -> [Float] {
    var state = seed
    return (0..<count).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return 0.05 + Float((state >> 32) & 65535) / 65535 * 0.25
    }
}

private func shifted(_ values: [Float], by delay: Int) -> [Float] {
    values.indices.map { index in
        let source = index - delay
        return values.indices.contains(source) ? values[source] : 0
    }
}

private func knownPositiveAndNegativeLags() {
    let values = randomEnvelope(12000, seed: 1)
    let late = Lag.peak(values, shifted(values, by: 43))
    let early = Lag.peak(values, shifted(values, by: -27))
    precondition(late.milliseconds == 43)
    precondition(early.milliseconds == -27)
}

private func weakAndAmbiguousCorrelationIsRejected() {
    let values = randomEnvelope(12000, seed: 2)
    precondition(Lag.peak(values, randomEnvelope(12000, seed: 3)).milliseconds == nil)
    precondition(Lag.peak([Float](repeating: 0, count: 12000), values).milliseconds == nil)
    let periodic = (0..<12000).map { Float($0 % 100) / 100 }
    precondition(Lag.peak(periodic, periodic).milliseconds == nil)
    precondition(Lag.peak([1, 2], [1, 2]).milliseconds == nil)
}

private func headAndTailDetectChangingDelay() {
    let envelope = randomEnvelope(70000, seed: 4)
    let system: [Float] = (0..<(70000 * 16)).map { index -> Float in
        let sign: Float = index % 2 == 0 ? 1 : -1
        return envelope[index / 16] * sign
    }
    let mic: [Float] = system.indices.map { index in
        let delay = (index < 35000 * 16 ? 8 : 20) * 16
        return index >= delay ? system[index - delay] : 0
    }
    let result = Lag.measure(system: system, mic: mic)
    precondition(result.head.milliseconds == 8)
    precondition(result.tail.milliseconds == 20)
    precondition(result.driftMilliseconds == 12)
    precondition(result.independentWindows)
}

private func interleavedMicAndStereoTapUseCommonFrames() {
    let memory = CaptureMemory(capacity: 4, micChannels: 1, tapChannels: 2)
    var samples: [Float] = [0.2, 0.6, 0.8, -0.2, -0.6, -0.8]
    samples.withUnsafeMutableBytes { raw in
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 3, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
        var time = AudioTimeStamp()
        time.mFlags = .sampleTimeValid
        withUnsafePointer(to: &list) { memory.receive($0, time: time) }
        time.mSampleTime = 2
        withUnsafePointer(to: &list) { memory.receive($0, time: time) }
    }
    precondition(memory.frames == 4)
    precondition(memory.gaps == 0)
    precondition(!memory.badLayout)
    precondition(abs(memory.system[0] - 0.7) < 0.00001)
    precondition(abs(memory.system[1] + 0.7) < 0.00001)
    precondition(abs(memory.mic![0] - 0.2) < 0.00001)
    precondition(abs(memory.mic![3] + 0.2) < 0.00001)
}

private func splitMicAndTapBuffersPreserveChannelOrder() {
    let memory = CaptureMemory(capacity: 2, micChannels: 1, tapChannels: 2)
    var mic: [Float] = [0.1, 0.2]
    var tap: [Float] = [0.4, 0.6, 0.6, 0.8]
    let list = AudioBufferList.allocate(maximumBuffers: 2)
    defer { list.unsafeMutablePointer.deallocate() }
    mic.withUnsafeMutableBytes { micBytes in
        tap.withUnsafeMutableBytes { tapBytes in
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(micBytes.count), mData: micBytes.baseAddress)
            list[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(tapBytes.count), mData: tapBytes.baseAddress)
            memory.receive(list.unsafePointer, time: AudioTimeStamp())
        }
    }
    precondition(!memory.badLayout)
    precondition(memory.frames == 2)
    precondition(abs(memory.system[0] - 0.5) < 0.00001)
    precondition(abs(memory.system[1] - 0.7) < 0.00001)
    precondition(abs(memory.mic![1] - 0.2) < 0.00001)
}

private func unequalBufferFrameCountsAreRejected() {
    let memory = CaptureMemory(capacity: 10, micChannels: 1, tapChannels: 2)
    var mic: [Float] = [0.1, 0.2]
    var tap: [Float] = [0.4, 0.6, 0.6, 0.8, 0.2, 0.3]
    let list = AudioBufferList.allocate(maximumBuffers: 2)
    defer { list.unsafeMutablePointer.deallocate() }
    mic.withUnsafeMutableBytes { micBytes in
        tap.withUnsafeMutableBytes { tapBytes in
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(micBytes.count), mData: micBytes.baseAddress)
            list[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(tapBytes.count), mData: tapBytes.baseAddress)
            memory.receive(list.unsafePointer, time: AudioTimeStamp())
        }
    }
    precondition(memory.badLayout)
    precondition(memory.frames == 0)
    precondition(memory.firstBufferCount == 2)
    precondition(memory.firstLayout[1] == 8 && memory.firstLayout[3] == 24)
}

private func discontinuityIsDetectedInsteadOfSilentlyCompressingTime() {
    let memory = CaptureMemory(capacity: 10, micChannels: 0, tapChannels: 1)
    var samples: [Float] = [0.5, 0.5]
    samples.withUnsafeMutableBytes { raw in
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
        var time = AudioTimeStamp()
        time.mFlags = .sampleTimeValid
        withUnsafePointer(to: &list) { memory.receive($0, time: time) }
        time.mSampleTime = 1024
        withUnsafePointer(to: &list) { memory.receive($0, time: time) }
    }
    precondition(memory.gaps == 1)
}

private func resampleAndWavRoundTripRetainDurationAndFloatFormat() throws {
    let angularStep: Double = 2.0 * Double.pi * 440.0 / 48000.0
    let native: [Float] = (0..<48000).map { index in Float(sin(Double(index) * angularStep) * 0.2) }
    let samples = try Wave.convert(native, rate: 48000)
    precondition(abs(samples.count - 16000) <= 1)
    precondition(samples.map { abs($0) }.max()! > 0.19)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("test.wav")
    try Wave.write(samples, to: url)
    let file = try AVAudioFile(forReading: url)
    precondition(file.fileFormat.sampleRate == 16000)
    precondition(file.fileFormat.channelCount == 1)
    precondition(file.fileFormat.commonFormat == .pcmFormatFloat32)
    precondition(file.length == samples.count)
    do {
        try Wave.write(samples, to: url)
        throw ProbeError("既存WAVの上書きを拒否しませんでした")
    } catch let error as ProbeError {
        precondition(error.description.contains("上書きしません"))
    }
}
