import AVFoundation
import CoreAudio
import Foundation

/// Short feasibility captures only: preallocate native-rate mono lanes, convert/write after stop.
/// IOProc does no disk I/O, logging, or per-buffer allocation. Serial IO queue owns this object
/// during recording; the main thread only reads it after stop + queue.sync.
final class CaptureMemory {
    let system: UnsafeMutablePointer<Float>
    let mic: UnsafeMutablePointer<Float>?
    let capacity: Int
    let micChannels: Int
    let tapChannels: Int
    var frames = 0
    var callbacks = 0
    var gaps = 0
    var badLayout = false
    var previousEnd: Double?
    var firstHost: UInt64?
    var lastHost: UInt64?
    var firstSample: Double?
    var lastSample: Double?
    var minimumCallbackFrames = Int.max
    var maximumCallbackFrames = 0
    // Fixed storage for first IOProc layout; inspected only after stopping.
    let firstLayout = UnsafeMutablePointer<UInt32>.allocate(capacity: 32)
    var firstBufferCount = 0

    init(capacity: Int, micChannels: Int, tapChannels: Int) {
        self.capacity = capacity; self.micChannels = micChannels; self.tapChannels = tapChannels
        system = .allocate(capacity: capacity)
        system.initialize(repeating: 0, count: capacity)
        if micChannels > 0 {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            pointer.initialize(repeating: 0, count: capacity)
            mic = pointer
        } else { mic = nil }
    }
    deinit { system.deallocate(); mic?.deallocate(); firstLayout.deallocate() }

    func receive(_ input: UnsafePointer<AudioBufferList>, time: AudioTimeStamp) {
        callbacks += 1
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        if callbacks == 1 {
            firstBufferCount = min(buffers.count, 16)
            for i in 0..<firstBufferCount {
                firstLayout[2 * i] = buffers[i].mNumberChannels
                firstLayout[2 * i + 1] = buffers[i].mDataByteSize
            }
        }
        guard let first = buffers.first, first.mNumberChannels > 0 else { badLayout = true; return }
        let count = Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels))
        minimumCallbackFrames = min(minimumCallbackFrames, count)
        maximumCallbackFrames = max(maximumCallbackFrames, count)
        var totalChannels = 0
        for buffer in buffers {
            guard buffer.mNumberChannels > 0,
                  Int(buffer.mDataByteSize) == count * 4 * Int(buffer.mNumberChannels) else {
                badLayout = true; return
            }
            totalChannels += Int(buffer.mNumberChannels)
        }
        guard totalChannels == micChannels + tapChannels else { badLayout = true; return }
        if time.mFlags.contains(.sampleTimeValid) {
            if firstSample == nil { firstSample = time.mSampleTime }
            lastSample = time.mSampleTime
            if let previousEnd, abs(time.mSampleTime - previousEnd) > 1 { gaps += 1 }
            previousEnd = time.mSampleTime + Double(count)
        }
        if time.mFlags.contains(.hostTimeValid) {
            if firstHost == nil { firstHost = time.mHostTime }
            lastHost = time.mHostTime
        }
        let accepted = min(count, capacity - frames)
        guard accepted > 0 else { return }
        var base = 0
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                for channel in 0..<channels {
                    let globalChannel = base + channel
                    let destination: UnsafeMutablePointer<Float>
                    let divisor: Float
                    if globalChannel < micChannels {
                        destination = mic!; divisor = Float(micChannels)
                    } else {
                        destination = system; divisor = Float(tapChannels)
                    }
                    for frame in 0..<accepted {
                        destination[frames + frame] += data[frame * channels + channel] / divisor
                    }
                }
            }
            base += channels
        }
        frames += accepted
    }
}

final class Recorder {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var io: AudioDeviceIOProcID?
    private var started = false
    private let queue = DispatchQueue(label: "system-audio-probe.io")
    private(set) var memory: CaptureMemory?
    private(set) var sampleRate: Double = 0

    func prepare(seconds: Double, withMic: Bool, includedProcess: AudioObjectID? = nil) throws {
        let ownProcess = try HAL.selfProcess()
        let description: CATapDescription
        if let includedProcess {
            guard includedProcess != kAudioObjectUnknown, includedProcess != ownProcess else {
                throw ProbeError("再生プロセスのHAL IDが不正です")
            }
            description = CATapDescription(stereoMixdownOfProcesses: [includedProcess])
            log("tap scope=play-only included HAL process=\(includedProcess)")
        } else {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
            log("tap scope=global excluded HAL process=\(ownProcess)")
        }
        description.name = "KIKIGAKI feasibility tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        log("self pid=\(getpid()) HAL process=\(ownProcess); muteBehavior=unmuted")
        try check(AudioHardwareCreateProcessTap(description, &tap), "create process tap")
        let tapUID = try HAL.string(tap, kAudioTapPropertyUID)
        let tapFormat = try HAL.read(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        log("tap=\(tap) channels=\(tapFormat.mChannelsPerFrame) rate=\(tapFormat.mSampleRate)")

        var micChannels = 0
        var composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "KIKIGAKI System Audio Probe",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: withMic,
                kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationHighQuality,
            ]],
        ]
        if withMic {
            let micID = try HAL.read(HAL.system, kAudioHardwarePropertyDefaultInputDevice, UInt32(0))
            let micUID = try HAL.string(micID, kAudioDevicePropertyDeviceUID)
            let micStreams = try HAL.streams(micID, scope: kAudioObjectPropertyScopeInput)
            micChannels = micStreams.map(\.end).max() ?? 0
            guard micChannels > 0 else { throw ProbeError("既定マイクに入力がありません") }
            composition[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: micUID]]
            composition[kAudioAggregateDeviceMainSubDeviceKey] = micUID
            log("mic=\(try HAL.string(micID, kAudioObjectPropertyName)) channels=\(micChannels); main clock=mic, tap drift=on")
        }
        try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "create private aggregate")
        // Use the aggregate's clock rate, not a sub-stream's advertised rate. On OWS 2,
        // the tap stream advertises 48 kHz while BOTH IOProc buffers have 320 frames
        // every 20 ms on the 16 kHz microphone clock. Subsequent 10-second and
        // 60-second captures with Tadashi confirmed nonzero mic and tap audio
        // on this shared clock while Chrome played YouTube audio.
        // All callbacks still validate equal frame counts; never reinterpret unequal buffers.
        // No nominal/virtual format writes: avoid changing the user's physical device.
        let streams = try HAL.streams(aggregate, scope: kAudioObjectPropertyScopeInput)
        guard !streams.isEmpty else { throw ProbeError("aggregateに入力streamがありません") }
        sampleRate = try HAL.read(aggregate, kAudioDevicePropertyNominalSampleRate, Double(0))
        log("aggregate nominalRate=\(sampleRate)")
        guard sampleRate >= 8000 && sampleRate <= 192000 else { throw ProbeError("未対応sample rate: \(sampleRate)") }
        var expectedStart = 0
        for stream in streams {
            let f = stream.format
            log("input stream=\(stream.id) channel=\(stream.start)..<\(stream.end) rate=\(f.mSampleRate) bits=\(f.mBitsPerChannel) flags=\(f.mFormatFlags)")
            guard stream.start == expectedStart, f.mSampleRate >= 8000, f.mSampleRate <= 192000,
                  f.mFormatID == kAudioFormatLinearPCM, f.mBitsPerChannel == 32,
                  f.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  f.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else {
                throw ProbeError("aggregate入力が対応レートの連続したFloat32ではありません")
            }
            expectedStart = stream.end
        }
        guard expectedStart == micChannels + Int(tapFormat.mChannelsPerFrame) else {
            throw ProbeError("マイクとタップのchannel構成が想定と一致しません")
        }
        let storage = CaptureMemory(capacity: Int(ceil(seconds * sampleRate)), micChannels: micChannels,
                                    tapChannels: Int(tapFormat.mChannelsPerFrame))
        memory = storage
        try check(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, queue) { _, input, time, _, _ in
            storage.receive(input, time: time.pointee)
        }, "create IOProc")
    }

    func start() throws {
        log("START requested. 許可ダイアログが出た場合は人の操作が必要です。")
        try check(AudioDeviceStart(aggregate, io), "start aggregate")
        started = true
        log("START returned")
    }

    func stop() {
        if started { log("stop OSStatus=\(AudioDeviceStop(aggregate, io))"); started = false }
        if let io { log("destroy IOProc OSStatus=\(AudioDeviceDestroyIOProcID(aggregate, io))"); self.io = nil }
        queue.sync {}
        if aggregate != kAudioObjectUnknown {
            log("destroy aggregate OSStatus=\(AudioHardwareDestroyAggregateDevice(aggregate))")
            aggregate = AudioObjectID(kAudioObjectUnknown)
        }
        if tap != kAudioObjectUnknown {
            log("destroy tap OSStatus=\(AudioHardwareDestroyProcessTap(tap))")
            tap = AudioObjectID(kAudioObjectUnknown)
        }
    }
    deinit { stop() }

    func save(to directory: URL, withMic: Bool, seconds: Double) throws -> Bool {
        guard let memory else { throw ProbeError("録音bufferがありません") }
        log("IOProc callbackFrames min=\(memory.minimumCallbackFrames) max=\(memory.maximumCallbackFrames)")
        for i in 0..<memory.firstBufferCount {
            let channels = memory.firstLayout[2 * i]
            let bytes = memory.firstLayout[2 * i + 1]
            log("first IOProc buffer=\(i) channels=\(channels) bytes=\(bytes) frames=\(channels > 0 ? bytes / (4 * channels) : 0)")
        }
        log("callbacks=\(memory.callbacks) nativeFrames=\(memory.frames) nativeSeconds=\(Double(memory.frames) / sampleRate) timestampGaps=\(memory.gaps) badLayout=\(memory.badLayout)")
        if let first = memory.firstHost, let last = memory.lastHost, last >= first {
            log("firstInputHost=\(first) lastInputHost=\(last) hostSpan=\(AVAudioTime.seconds(forHostTime: last - first))")
            if last > first, let firstSample = memory.firstSample, let lastSample = memory.lastSample {
                let observedRate = (lastSample - firstSample) / AVAudioTime.seconds(forHostTime: last - first)
                log("IOProc sampleDelta=\(lastSample - firstSample) observedHostRate=\(observedRate)")
                guard abs(observedRate / sampleRate - 1) < 0.01 else {
                    throw ProbeError("IOProcの時計とaggregate公称レートが一致しません。保存を止めます")
                }
            }
        }
        guard !memory.badLayout, memory.gaps == 0 else {
            throw ProbeError("入力構成の変化またはタイムスタンプの欠落を検出。時刻を詰めたWAVは保存しません")
        }
        let targetFrames = Int((seconds * 16000).rounded())
        func lane(_ pointer: UnsafeMutablePointer<Float>) throws -> [Float] {
            var result = try Wave.convert(Array(UnsafeBufferPointer(start: pointer, count: memory.frames)), rate: sampleRate)
            if result.count > targetFrames { result.removeLast(result.count - targetFrames) }
            if result.count < targetFrames { result.append(contentsOf: repeatElement(0, count: targetFrames - result.count)) }
            return result
        }
        let system = try lane(memory.system)
        try Wave.write(system, to: directory.appendingPathComponent("system.wav"))
        log("system: \(Wave.stats(system))")
        if withMic, let pointer = memory.mic {
            let mic = try lane(pointer)
            try Wave.write(mic, to: directory.appendingPathComponent("mic.wav"))
            // Equal gain with 6 dB headroom. Preserve the raw lanes for separate assessment.
            let mixed = zip(system, mic).map { max(-1, min(1, ($0 + $1) * 0.5)) }
            try Wave.write(mixed, to: directory.appendingPathComponent("mixed.wav"))
            log("mic: \(Wave.stats(mic))")
            log("mixed: \(Wave.stats(mixed))")
        }
        return system.contains { $0 != 0 }
    }
}
