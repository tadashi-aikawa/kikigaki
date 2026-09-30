import AVFoundation
import CoreAudio
import Foundation
import Testing
import KikigakiCore
@testable import Kikigaki

struct SystemAudioTests {
    @Test func 開始APIの長い待ち時間を入力停止に数えないが開始後の無応答は検出する() {
        for completedAt: UInt64 in [2300, 7000, 60000] {
            let watchdog = SystemAudioInputWatchdog(startCompletedAt: completedAt,
                                                   secondsForHostTime: { Double($0) / 1000 })
            #expect(!watchdog.inputStopped(at: completedAt, lastInputAt: 0))
            #expect(!watchdog.inputStopped(at: completedAt + 1999, lastInputAt: completedAt - 1))
            #expect(watchdog.inputStopped(at: completedAt + 2000, lastInputAt: 0))
        }
    }
    @Test func 実入力が届けばその時刻から停止を監視し読み取りの前後も安全に扱う() {
        let watchdog = SystemAudioInputWatchdog(startCompletedAt: 60000,
                                               secondsForHostTime: { Double($0) / 1000 })
        #expect(!watchdog.inputStopped(at: 63500, lastInputAt: 62000))
        #expect(watchdog.inputStopped(at: 64000, lastInputAt: 62000))
        #expect(!watchdog.inputStopped(at: 64000, lastInputAt: 64001))
    }
    @Test func workerの後片付けは同じqueueから再入しても同期待ちしない() {
        let worker = SystemAudioWorker()
        var count = 0
        worker.drain { count += 1 }
        worker.queue.sync { worker.drain { count += 1 } }
        #expect(count == 2)
    }
    @Test func 検証変数は通常起動で無視しreplayとsmokeでは形式だけ検証する() throws {
        let env = ["KIKIGAKI_DEBUG_REPLAY_SYSTEM": "~/system.wav"]
        #expect(try ReplayDebugOptions.load(arguments: ["--smoke"], environment: env).systemAudioPath == nil)
        #expect(try ReplayDebugOptions.load(arguments: ["--smoke", "--replay", "mic.wav"], environment: env).systemAudioPath?.hasSuffix("/system.wav") == true)
        for input in ["", "  ", "a\nb", "a\0b"] {
            #expect(throws: (any Error).self) {
                try ReplayDebugOptions.load(arguments: ["--smoke", "--replay", "mic.wav"], environment: ["KIKIGAKI_DEBUG_REPLAY_SYSTEM": input])
            }
        }
    }
    @Test func 接続方式だけでヘッドホンと決めない() {
        #expect(SystemAudioOutput.classify(transport: kAudioDeviceTransportTypeBluetooth, terminals: [], sources: [], kinds: []) == .unknown)
        #expect(SystemAudioOutput.classify(transport: kAudioDeviceTransportTypeUSB, terminals: [kAudioStreamTerminalTypeHeadphones], sources: [], kinds: []) == .headphones)
        #expect(SystemAudioOutput.classify(transport: kAudioDeviceTransportTypeBuiltIn, terminals: [kAudioStreamTerminalTypeSpeaker], sources: [], kinds: []) == .builtInSpeaker)
    }
    @Test func リングは時刻を保ち同じフレーム位置の2系統を分ける() throws {
        let ring = SystemAudioRing(capacity: 4, micChannels: 1, tapChannels: 2)
        var samples: [Float] = [0.1, 0.4, 0.6, 0.2, 0.6, 0.8]
        samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 3, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            var time = AudioTimeStamp(); time.mFlags = .sampleTimeValid
            withUnsafePointer(to: &list) { ring.receive($0, time: time) }
            time.mSampleTime = 2
            withUnsafePointer(to: &list) { ring.receive($0, time: time) }
        }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 2, interleaved: false))
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        #expect(ring.take(into: output) == 3)
        #expect(abs(output.floatChannelData![0][0] - 0.1) < 0.00001)
        #expect(abs(output.floatChannelData![1][1] - 0.7) < 0.00001)
        #expect(ring.take(into: output) == 1)
        #expect(ring.take(into: output) == 0)
        #expect(ring.failure.load(ordering: .acquiring) == 0)
    }
    @Test func 変換器はchunk間で終了せず末尾まで排出する() throws {
        let converter = try SystemAudioConversion(rate: 48000)
        var output: [Float] = []
        var remaining = 48000
        while remaining > 0 {
            let frames = min(remaining, Int(converter.input.frameCapacity))
            converter.input.frameLength = AVAudioFrameCount(frames)
            for frame in 0..<frames {
                converter.input.floatChannelData![0][frame] = 0.01
                converter.input.floatChannelData![1][frame] = 0
            }
            try converter.consume { output += $0 }
            if remaining == 48000 { #expect(!output.isEmpty) }
            remaining -= frames
        }
        try converter.consume(ending: true) { output += $0 }
        #expect(output.count == 16000)
        #expect(output.allSatisfy { $0.isFinite && abs($0) <= 1 })
    }
    @Test func 変換不要なら短い入力を先読みせず渡し停止時に重複しない() throws {
        let converter = try SystemAudioConversion(rate: 16000)
        converter.input.frameLength = 2
        converter.input.floatChannelData![0][0] = 0.125
        converter.input.floatChannelData![1][0] = 0.25
        converter.input.floatChannelData![0][1] = -0.25
        converter.input.floatChannelData![1][1] = 0
        var output: [Float] = []
        try converter.consume { output += $0 }
        #expect(output == [0.375, -0.25])
        try converter.consume(ending: true) { output += $0 }
        #expect(output == [0.375, -0.25])
    }
    @Test func リングの欠落と溢れは黙って詰めず失敗として返す() {
        for gap in [true, false] {
            let ring = SystemAudioRing(capacity: 2, micChannels: 1, tapChannels: 1)
            var samples: [Float] = [0.1, 0.2, 0.3, 0.4]
            samples.withUnsafeMutableBytes { bytes in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                var time = AudioTimeStamp(); time.mFlags = .sampleTimeValid
                withUnsafePointer(to: &list) { ring.receive($0, time: time) }
                time.mSampleTime = gap ? 4 : 2
                withUnsafePointer(to: &list) { ring.receive($0, time: time) }
            }
            #expect(ring.failure.load(ordering: .acquiring) == (gap ? 2 : 3))
        }
    }
}

@MainActor struct SystemAudioFallbackTests {
    final class DelayedCapture: SystemAudioCapturing {
        var onFailure: ((String) -> Void)?
        let entered: AsyncStream<Void>.Continuation
        let release = DispatchSemaphore(value: 0)
        var ranOnMain: Bool?
        var failStart = false
        var stopped = false
        init(entered: AsyncStream<Void>.Continuation) { self.entered = entered }
        func start(onSamples: @escaping ([Float]) -> Void) throws {
            ranOnMain = Thread.isMainThread
            entered.yield(()); entered.finish()
            // 回帰でmainへ戻った場合も、テスト自身がmainを永久に止めない。
            guard !Thread.isMainThread else { throw SystemAudioError(reason: "main上で同期開始された") }
            release.wait()
            if failStart { throw SystemAudioError(reason: "試験用の許可拒否") }
            onSamples([0.1])
        }
        func stop() { stopped = true }
    }
    final class Capture: SystemAudioCapturing {
        var onFailure: ((String) -> Void)?
        var failStart = false
        var stopped = false
        func start(onSamples: @escaping ([Float]) -> Void) throws {
            if failStart { throw SystemAudioError(reason: "試験用の準備失敗") }
            onSamples([0.1])
        }
        func stop() { stopped = true }
    }
    final class Microphone: AudioSource {
        var starts = 0
        func start(onSamples: @escaping ([Float]) -> Void) throws { starts += 1; onSamples([0.2]) }
        func stop() {}
    }
    @Test func 許可待ち相当の開始をawaitしてもMainActorが進み準備完了を待つ() async throws {
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let capture = DelayedCapture(entered: signal), mic = Microphone()
        let source = MicAndSystemSource(makeCapture: { capture }, makeMicrophone: { mic })
        var samples: [Float] = []
        let preparation = Task { try await source.prepare { samples += $0 } }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        #expect(capture.ranOnMain == false)
        #expect(samples.isEmpty && mic.starts == 0)
        // このmain上の処理に到達するまで、capture.startは専用queue上で待機している。
        capture.release.signal()
        try await preparation.value
        #expect(samples == [0.1] && mic.starts == 0 && source.warning == nil)
        source.stop()
        #expect(capture.stopped)
    }
    @Test func 開始待ち中の停止は遅れた音声と開始完了を適用せず後片付けする() async throws {
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let capture = DelayedCapture(entered: signal), mic = Microphone()
        let source = MicAndSystemSource(makeCapture: { capture }, makeMicrophone: { mic })
        var samples: [Float] = []
        let preparation = Task { try await source.prepare { samples += $0 } }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        source.stop()
        capture.release.signal()
        do { try await preparation.value; Issue.record("停止した開始処理が成功した") }
        catch { #expect(error is CancellationError) }
        #expect(capture.stopped && mic.starts == 0 && samples.isEmpty)
        capture.onFailure?("古い通知")
        #expect(source.warning == nil)
    }
    @Test func 非同期開始の拒否と復帰に先行する失敗はcaptureを残さずマイクへ切り替える() async throws {
        for failStart in [true, false] {
            let (entered, signal) = AsyncStream<Void>.makeStream()
            let capture = DelayedCapture(entered: signal), mic = Microphone()
            capture.failStart = failStart
            let source = MicAndSystemSource(makeCapture: { capture }, makeMicrophone: { mic })
            var samples: [Float] = []
            let preparation = Task { try await source.prepare { samples += $0 } }
            var iterator = entered.makeAsyncIterator()
            _ = await iterator.next()
            if !failStart { capture.onFailure?("試験用の入力停止") }
            #expect(mic.starts == 0)
            capture.release.signal()
            try await preparation.value
            #expect(capture.stopped && mic.starts == 1 && samples.last == 0.2)
            #expect(source.warning?.contains(failStart ? "試験用の許可拒否" : "試験用の入力停止") == true)
            source.stop()
        }
    }
    @Test func 準備と録音中の失敗はマイクへ切り替え停止後の通知は無視する() throws {
        for failStart in [true, false] {
            let capture = Capture(); capture.failStart = failStart
            let mic = Microphone()
            let source = MicAndSystemSource(makeCapture: { capture }, makeMicrophone: { mic })
            var samples: [Float] = [], warnings: [String] = []
            source.onWarning = { warnings.append($0) }
            try source.start { samples += $0 }
            if !failStart { capture.onFailure?("試験用の入力停止") }
            #expect(mic.starts == 1)
            #expect(capture.stopped)
            #expect(samples.last == 0.2)
            #expect(warnings.count == 1)
            source.stop()
            capture.onFailure?("旧世代の通知")
            #expect(mic.starts == 1 && warnings.count == 1)
        }
    }
}
