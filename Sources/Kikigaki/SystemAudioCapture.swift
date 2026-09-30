import AVFoundation
import CoreAudio
import Foundation
import KikigakiCore
import Synchronization

/// 単一IOProc→単一workerのリング。producerとconsumerの位置だけをatomicで公開する。
/// RT側は確保済み領域へのコピーだけを行い、ロック・確保・ログ・ディスクI/Oをしない。
/// 溢れや形式変更を黙って詰めず、workerから従来のマイクへ切り替える。
final class SystemAudioRing {
    let capacity: Int
    let micChannels: Int
    let tapChannels: Int
    private let mic: UnsafeMutablePointer<Float>
    private let system: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    let failure = Atomic<Int>(0)
    let lastHost = Atomic<UInt64>(0)
    private var previousEnd: Double?

    init(capacity: Int, micChannels: Int, tapChannels: Int) {
        self.capacity = capacity; self.micChannels = micChannels; self.tapChannels = tapChannels
        mic = .allocate(capacity: capacity); system = .allocate(capacity: capacity)
        mic.initialize(repeating: 0, count: capacity); system.initialize(repeating: 0, count: capacity)
    }
    deinit { mic.deallocate(); system.deallocate() }
    func receive(_ input: UnsafePointer<AudioBufferList>, time: AudioTimeStamp) {
        guard failure.load(ordering: .relaxed) == 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mNumberChannels > 0 else { fail(1); return }
        let frames = Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels))
        guard frames > 0 else { fail(1); return }
        var channels = 0
        for buffer in buffers {
            guard buffer.mNumberChannels > 0, buffer.mData != nil,
                  Int(buffer.mDataByteSize) == frames * 4 * Int(buffer.mNumberChannels) else { fail(1); return }
            channels += Int(buffer.mNumberChannels)
        }
        guard channels == micChannels + tapChannels else { fail(1); return }
        if time.mFlags.contains(.sampleTimeValid) {
            if let previousEnd, abs(time.mSampleTime - previousEnd) > 1 { fail(2); return }
            previousEnd = time.mSampleTime + Double(frames)
        }
        lastHost.store(mach_absolute_time(), ordering: .releasing)
        let start = written.load(ordering: .relaxed)
        guard frames <= capacity - (start - read.load(ordering: .acquiring)) else { fail(3); return }
        for frame in 0..<frames {
            let index = (start + frame) % capacity
            mic[index] = 0; system[index] = 0
        }
        var base = 0
        for buffer in buffers {
            let count = Int(buffer.mNumberChannels)
            let data = buffer.mData!.assumingMemoryBound(to: Float.self)
            for channel in 0..<count {
                let isMic = base + channel < micChannels
                let destination = isMic ? mic : system
                let divisor = Float(isMic ? micChannels : tapChannels)
                for frame in 0..<frames {
                    let value = data[frame * count + channel]
                    guard value.isFinite else { fail(1); return }
                    destination[(start + frame) % capacity] += value / divisor
                }
            }
            base += count
        }
        written.store(start + frames, ordering: .releasing)
    }
    private func fail(_ code: Int) { failure.store(code, ordering: .releasing) }
    /// workerだけが呼ぶ。bufferの両channelへ同じnative frame位置をコピーする。
    func take(into buffer: AVAudioPCMBuffer) -> Int {
        let start = read.load(ordering: .relaxed)
        let frames = min(Int(buffer.frameCapacity), written.load(ordering: .acquiring) - start)
        guard frames > 0 else { return 0 }
        let channels = buffer.floatChannelData!
        for frame in 0..<frames {
            channels[0][frame] = mic[(start + frame) % capacity]
            channels[1][frame] = system[(start + frame) % capacity]
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        read.store(start + frames, ordering: .releasing)
        return frames
    }
}

/// 変換器を会議中保持する。noDataNowは次の入力を待つ意味で、チャンクごとにendOfStreamにしない。
final class SystemAudioConversion {
    let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private let converter: AVAudioConverter?
    init(rate: Double) throws {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 2, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 2048),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192) else {
            throw SystemAudioError(reason: "音声変換のバッファを作成できません")
        }
        self.input = input; self.output = output
        converter = rate == 16000 ? nil : AVAudioConverter(from: source, to: target)
        guard rate == 16000 || converter != nil else { throw SystemAudioError(reason: "音声を16kHzへ変換できません") }
    }
    private func mix(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let count = Int(buffer.frameLength), channels = buffer.floatChannelData!
        return SystemAudioMixer.process(microphone: Array(UnsafeBufferPointer(start: channels[0], count: count)),
                                        systemAudio: Array(UnsafeBufferPointer(start: channels[1], count: count)))
    }
    func consume(ending: Bool = false, emit: ([Float]) -> Void) throws {
        guard let converter else {
            if !ending { let samples = mix(input); if !samples.isEmpty { emit(samples) } }
            return
        }
        var supplied = false
        while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if ending { state.pointee = .endOfStream; return nil }
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return self.input
            }
            if let error { throw error }
            guard status != .error else { throw SystemAudioError(reason: "録音中の音声変換に失敗しました") }
            if output.frameLength > 0 { let samples = mix(output); if !samples.isEmpty { emit(samples) } }
            if status == .inputRanDry || status == .endOfStream || output.frameLength == 0 { break }
        }
    }
}

/// timerのpollが最後の参照を解放し、worker上でdeinitが走る場合も同じqueueへsyncしない。
/// 外部からの停止では従来どおり先行処理を排出し、worker自身ならその場で後片付けする。
final class SystemAudioWorker {
    let queue = DispatchQueue(label: "kikigaki.system-audio.worker", qos: .userInitiated)
    private let key = DispatchSpecificKey<UInt8>()
    init() { queue.setSpecific(key: key, value: 1) }
    func drain(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: key) != nil { body() }
        else { queue.sync(execute: body) }
    }
}

/// 許可ダイアログでAudioDeviceStartが長く待っても、その時間を入力停止に数えない。
/// 開始成功後と実際の最終入力の遅い方から2秒を数える。lastHostは実入力だけで更新する。
struct SystemAudioInputWatchdog {
    let startCompletedAt: UInt64
    var secondsForHostTime: (UInt64) -> Double = { AVAudioTime.seconds(forHostTime: $0) }

    func inputStopped(at now: UInt64, lastInputAt: UInt64) -> Bool {
        let baseline = max(startCompletedAt, lastInputAt)
        return now >= baseline && secondsForHostTime(now - baseline) >= 2
    }
}

/// 制御はstart/stop呼出元、変換と監視はworker、producerはHALのserial IO queue。
/// 破棄はIO停止→IO queue排出→worker排出→aggregate/tapの順に行う。
protocol SystemAudioCapturing: AudioSource {
    var onFailure: ((String) -> Void)? { get set }
}
final class SystemAudioCapture: SystemAudioCapturing {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var microphone: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private var started = false
    private let ioQueue = DispatchQueue(label: "kikigaki.system-audio.io")
    private let worker = SystemAudioWorker()
    private var timer: DispatchSourceTimer?
    private var ring: SystemAudioRing?
    private var conversion: SystemAudioConversion?
    private var emit: (([Float]) -> Void)?
    private var rate: Double = 0
    private var channelCount = 0
    private var lastHealthCheck: UInt64 = 0
    private var watchdog: SystemAudioInputWatchdog?
    private var failed = false // workerのみ
    var onFailure: ((String) -> Void)? // main queueへ通知

    func start(onSamples: @escaping ([Float]) -> Void) throws {
        do {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [try SystemAudioHAL.ownProcess()])
            description.name = "KIKIGAKI system audio"
            description.isPrivate = true; description.muteBehavior = .unmuted
            try SystemAudioHAL.check(AudioHardwareCreateProcessTap(description, &tap), "システム音声タップの作成")
            let tapUID = try SystemAudioHAL.string(tap, kAudioTapPropertyUID)
            let format = try SystemAudioHAL.read(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
            microphone = try SystemAudioHAL.read(SystemAudioHAL.system, kAudioHardwarePropertyDefaultInputDevice, UInt32(0))
            let uid = try SystemAudioHAL.string(microphone, kAudioDevicePropertyDeviceUID)
            let micChannels = try SystemAudioHAL.streams(microphone, scope: kAudioObjectPropertyScopeInput).map(\.end).max() ?? 0
            guard micChannels > 0 else { throw SystemAudioError(reason: "既定マイクに入力がありません") }
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "KIKIGAKI microphone and system audio",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
                kAudioAggregateDeviceMainSubDeviceKey: uid,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationHighQuality]],
            ]
            try SystemAudioHAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "音声の同時取り込み準備")
            rate = try SystemAudioHAL.read(aggregate, kAudioDevicePropertyNominalSampleRate, Double(0))
            guard rate >= 8000 && rate <= 192000 else { throw SystemAudioError(reason: "対応できない音声レートです") }
            channelCount = try inputChannels()
            guard channelCount == micChannels + Int(format.mChannelsPerFrame), format.mChannelsPerFrame > 0 else {
                throw SystemAudioError(reason: "マイクとシステム音声のchannel構成が変わりました")
            }
            let ring = SystemAudioRing(capacity: Int(rate * 2), micChannels: micChannels, tapChannels: Int(format.mChannelsPerFrame))
            self.ring = ring
            conversion = try SystemAudioConversion(rate: rate)
            emit = onSamples
            try SystemAudioHAL.check(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, ioQueue) { _, input, time, _, _ in
                ring.receive(input, time: time.pointee)
            }, "音声コールバックの準備")
            try SystemAudioHAL.check(AudioDeviceStart(aggregate, io), "システム音声の開始")
            started = true
            // 初回許可待ちが何十秒でも、その間は入力を監視しない。
            // IOProcが先に動いていてもlastHostを上書きせず、成功した開始の時刻を別に持つ。
            watchdog = SystemAudioInputWatchdog(startCompletedAt: mach_absolute_time())
            let timer = DispatchSource.makeTimerSource(queue: worker.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer; timer.resume()
        } catch { stop(); throw error }
    }
    private func inputChannels() throws -> Int {
        var channel = 0
        for stream in try SystemAudioHAL.streams(aggregate, scope: kAudioObjectPropertyScopeInput) {
            let f = stream.format
            // OWS 2ではtap表示48kHzでも両IOProc bufferは共通16kHz。表示のレート一致は求めない。
            guard stream.start == channel, f.mFormatID == kAudioFormatLinearPCM, f.mBitsPerChannel == 32,
                  f.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  f.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else {
                throw SystemAudioError(reason: "対応できない音声形式です")
            }
            channel = stream.end
        }
        return channel
    }
    private func drain() throws {
        guard let ring, let conversion, let emit else { return }
        while ring.take(into: conversion.input) > 0 { try conversion.consume(emit: emit) }
    }
    private func poll() {
        guard !failed, let ring else { return }
        do {
            let code = ring.failure.load(ordering: .acquiring)
            guard code == 0 else {
                let reasons = [1: "音声形式が変わりました", 2: "音声の時刻に欠落がありました", 3: "音声処理が追いつかなくなりました"]
                throw SystemAudioError(reason: reasons[code] ?? "音声の取り込みが続けられません")
            }
            try drain()
            let now = mach_absolute_time()
            let last = ring.lastHost.load(ordering: .acquiring)
            guard watchdog?.inputStopped(at: now, lastInputAt: last) != true else {
                throw SystemAudioError(reason: "音声デバイスからの入力が止まりました")
            }
            if AVAudioTime.seconds(forHostTime: now - lastHealthCheck) >= 0.2 {
                lastHealthCheck = now
                let alive = try SystemAudioHAL.read(microphone, kAudioDevicePropertyDeviceIsAlive, UInt32(0))
                let currentRate = try SystemAudioHAL.read(aggregate, kAudioDevicePropertyNominalSampleRate, Double(0))
                guard alive != 0, currentRate == rate, try inputChannels() == channelCount else {
                    throw SystemAudioError(reason: "マイクの接続または音声形式が変わりました")
                }
            }
        } catch {
            failed = true
            let reason = error.localizedDescription
            DispatchQueue.main.async { [weak self] in self?.onFailure?(reason) }
        }
    }
    func stop() {
        timer?.cancel(); timer = nil
        if started { AudioDeviceStop(aggregate, io); started = false }
        if let io { AudioDeviceDestroyIOProcID(aggregate, io); self.io = nil }
        ioQueue.sync {}
        worker.drain {
            // 不正な区間の入力は渡さない。通常停止なら変換器の末尾まで排出する。
            if !failed, ring?.failure.load(ordering: .acquiring) == 0, let emit {
                try? drain(); try? conversion?.consume(ending: true, emit: emit)
            }
            emit = nil; conversion = nil; ring = nil; watchdog = nil
        }
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }
    deinit { stop() }
}
