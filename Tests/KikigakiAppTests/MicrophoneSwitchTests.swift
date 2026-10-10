import AppKit
import AVFoundation
import Foundation
import Testing
import KikigakiCore
@testable import Kikigaki

private final class SwitchCapture: MicrophoneCapturing {
    let notifications = NotificationCenter()
    lazy var observer = EngineMicrophoneCapture(notifications: notifications)
    var onConfigurationChange: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var isRunning = false
    var stopped = false
    var fails = false
    var samples: (([Float], Double) -> Void)?
    func start(onSamples: @escaping ([Float], Double) -> Void) throws {
        if fails { throw SystemAudioError(reason: "試験用の接続失敗") }
        samples = onSamples; isRunning = true
        observer.onConfigurationChange = { [weak self] in
            self?.isRunning = false
            self?.onConfigurationChange?()
        }
        observer.observeConfigurationChanges()
    }
    func change() {
        notifications.post(name: .AVAudioEngineConfigurationChange, object: observer.notificationObject)
    }
    func stop() { stopped = true; isRunning = false; observer.stop() }
}

private final class SwitchFixture {
    var current = MicrophoneDevice(id: 1, name: "MacBook Proのマイク")
    var inputChanged: (() -> Void)?
    var cancelled = false
    var captures: [SwitchCapture] = []
    var failNext = false
    var uptime = 100.0
    let wall = Date(timeIntervalSince1970: 1_800_000_000)
    lazy var source = MicSource(makeCapture: { [unowned self] in
        let capture = SwitchCapture(); capture.fails = failNext; failNext = false
        captures.append(capture); return capture
    }, device: { [unowned self] in current }, observeInput: { [unowned self] changed in
        inputChanged = changed
        return { [weak self] in self?.cancelled = true }
    }, now: { [unowned self] in uptime }, date: { [unowned self] in wall.addingTimeInterval(uptime - 100) }, retryDelay: 0.01)
    func deliver(_ value: Float = 0.25, count: Int = 1600, end: Double) {
        uptime = end
        captures.last?.samples?(Array(repeating: value, count: count), end)
        source.drain()
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct MicrophoneSwitchTests {
    @Test func 実通知の注入で停止した入力を破棄し新しい収録と無音を順に渡す() throws {
        let f = SwitchFixture()
        var output: [Float] = [], switches: [String] = []
        f.source.onSwitch = { name, _ in switches.append(name) }
        try f.source.start { output += $0 }; defer { f.source.stop() }
        f.deliver(end: 100.1)
        let old = f.captures[0]
        f.current = MicrophoneDevice(id: 2, name: "スピーカーフォン")
        old.change(); f.source.drain()
        #expect(old.stopped && f.captures.count == 2 && f.captures[1].isRunning)
        // 同じ切替のHAL通知・破棄済みengine通知・遅れたbufferは重複適用しない。
        f.inputChanged?(); old.onConfigurationChange?(); old.samples?([0.9], 102)
        f.source.drain()
        #expect(f.captures.count == 2 && switches.isEmpty)
        f.deliver(0.5, end: 101.45)
        #expect(output.count == 23200)
        #expect(Array(output[1600..<21600]) == Array(repeating: Float(0), count: 20000))
        #expect(output.suffix(1600).allSatisfy { $0 == 0.5 })
        #expect(switches == ["スピーカーフォン"])
        f.deliver(end: 101.55)
        #expect(output.count == 24800 && switches.count == 1)
    }

    @Test func 同じ形式でengine通知が無くても既定入力リスナーで乗り換える() throws {
        let f = SwitchFixture()
        var output: [Float] = []
        try f.source.start { output += $0 }; defer { f.source.stop() }
        f.deliver(end: 100.1)
        f.current = MicrophoneDevice(id: 2, name: "USBマイク")
        f.inputChanged?(); f.source.drain()
        #expect(f.captures[0].stopped && f.captures.count == 2)
        f.deliver(end: 100.2)
        #expect(output.count == 3200)
    }

    @Test func 同じ装置の形式変更も再起動するが機器の切替行は増やさない() throws {
        let f = SwitchFixture()
        var output: [Float] = [], switches = 0
        f.source.onSwitch = { _, _ in switches += 1 }
        try f.source.start { output += $0 }; defer { f.source.stop() }
        f.deliver(end: 100.1)
        f.captures[0].change(); f.source.drain()
        f.deliver(end: 100.7)
        #expect(f.captures.count == 2 && output.count == 11200 && switches == 0)
    }

    @Test func 開始失敗でタップとリスナーを片付け再開始には前の通知を持ち越さない() throws {
        let f = SwitchFixture(); f.failNext = true
        #expect(throws: SystemAudioError.self) { try f.source.start { _ in } }
        #expect(f.cancelled && f.captures[0].stopped)
        let oldListener = f.inputChanged
        var output: [Float] = []
        try f.source.start { output += $0 }; defer { f.source.stop() }
        oldListener?(); f.source.drain()
        #expect(f.captures.count == 2)
        f.deliver(end: 100.1)
        #expect(output.count == 1600)
    }

    @Test func 再開失敗は無音を流し続けず理由を通知し復帰時に欠落を一度だけ補う() async throws {
        let f = SwitchFixture()
        var output: [Float] = [], warnings: [String?] = []
        f.source.onWarning = { warnings.append($0) }
        try f.source.start { output += $0 }; defer { f.source.stop() }
        f.deliver(end: 100.1)
        f.failNext = true
        f.current = MicrophoneDevice(id: 2, name: "USBマイク")
        f.captures[0].change(); f.source.drain()
        #expect(output.count == 1600 && warnings.first??.contains("試験用の接続失敗") == true)
        try await Task.sleep(for: .milliseconds(40)); f.source.drain()
        #expect(f.captures.count == 3 && f.captures[1].stopped)
        #expect(output.count == 1600 && warnings.count == 1)
        f.deliver(end: 101.2)
        #expect(output.count == 19200 && warnings.count == 2 && warnings[1] == nil)
        f.source.stop()
        let oldListener = f.inputChanged
        oldListener?(); f.captures.last?.samples?([1], 104); f.source.drain()
        #expect(output.count == 19200 && f.cancelled)
    }

    @Test func 再試行待ちで止めたら遅延処理が録音を復活させない() async throws {
        let f = SwitchFixture()
        try f.source.start { _ in }
        f.failNext = true; f.captures[0].change(); f.source.drain()
        f.source.stop()
        try await Task.sleep(for: .milliseconds(40)); f.source.drain()
        #expect(f.captures.count == 2 && f.captures.allSatisfy(\.stopped))
    }

    @Test func 欠落PCMをWAVと音量トラックに同じ時刻で保存できる() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let f = SwitchFixture()
        let url = root.appendingPathComponent("switch.wav")
        let wav = try WavWriter(url: url)
        var meter = AudioLevelMeter(), failures: [Error] = []
        try f.source.start {
            meter.append($0)
            do { try wav.write($0) } catch { failures.append(error) }
        }; defer { f.source.stop() }
        f.deliver(end: 100.1)
        f.captures[0].change(); f.source.drain(); f.deliver(end: 101.2)
        wav.close()
        let file = try AVAudioFile(forReading: url)
        #expect(failures.isEmpty && file.length == 19200)
        let track = meter.track(includingPartial: true)
        #expect(track.levels.count == 12)
        #expect(track.levels[1..<11].allSatisfy { $0 == -120 })
    }

    @Test func 欠落の途中の一時停止を無音へ二重に加算せず共通の入力へ流す() async throws {
        let pause = PauseFlag(), origin = Date(timeIntervalSince1970: 100)
        pause.reset(startedAt: origin)
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        pause.accept(Array(repeating: 0.2, count: 16000), into: continuation)
        pause.pause(at: origin.addingTimeInterval(1.5))
        pause.resume(at: origin.addingTimeInterval(2.5))
        pause.acceptGap(sampleCount: 48000, start: origin.addingTimeInterval(1), end: origin.addingTimeInterval(4), into: continuation)
        pause.accept(Array(repeating: 0.3, count: 1600), into: continuation)
        continuation.finish()
        var output: [Float] = []
        for await chunk in stream { output += chunk }
        #expect(output.count == 49600 && pause.audioTime == 3.1)
        #expect(pause.timeline.date(at: 3).timeIntervalSince(origin) == 4)
        #expect(pause.timeline.date(at: 1.25).timeIntervalSince(origin) == 1.25)
        #expect(pause.timeline.pauses.first?.audioTime == 1.5)
        #expect(output[16000..<48000].allSatisfy { $0 == 0 })
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct MicrophoneSwitchUITests {
    @Test func マイク行は値だけで追従し長い名前でもシートの高さを変えない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var name = "MacBook Proのマイク"
        let sheet = StartSheet(profiles: [], diarizationEnabled: true, exclusion: AudioExclusion(), microphoneName: { name })
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        defer { sheet.close(); parent.orderOut(nil) }
        sheet.present(on: parent)
        let frame = sheet.window.frame
        #expect(sheet.microphoneLabel.stringValue == name && !sheet.microphoneLabel.isEditable)
        let microphoneRow = try #require(sheet.microphoneLabel.superview as? NSStackView)
        #expect((microphoneRow.arrangedSubviews.first as? NSTextField)?.stringValue == "マイク")
        let rows = try #require(microphoneRow.superview as? NSStackView)
        let index = try #require(rows.arrangedSubviews.firstIndex(of: microphoneRow))
        let previous = try #require(rows.arrangedSubviews[index - 2] as? NSStackView)
        #expect((previous.arrangedSubviews.first as? NSTextField)?.stringValue == "システム音声")
        name = "スピーカーフォン"
        waitForMicrophone(sheet, name: name)
        #expect(sheet.microphoneLabel.stringValue == name && sheet.window.frame == frame)
        try capture(sheet.window.contentView!, name: "start-sheet-microphone")
        name = String(repeating: "とても長いUSBマイクの装置名", count: 20)
        waitForMicrophone(sheet, name: name)
        #expect(sheet.microphoneLabel.stringValue == name && sheet.window.frame == frame)
        #expect(sheet.microphoneLabel.toolTip == name && sheet.microphoneLabel.usesSingleLineMode)
    }

    @Test func 切替行と再開失敗は本番セッションへ届き会話と保存とAIには混ざらない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = ResolvedConfig(config: KikigakiConfig(outputDir: root.path))
        let url = root.appendingPathComponent("meeting.md")
        let store = AIRecordStore(directory: root)
        let session = MeetingSession(testingRecordingAt: url, config: config, aiStore: store, recordedSamples: 16000, diarizationEnabled: false)
        let f = SwitchFixture()
        session.configureMicrophone(f.source)
        var output: [Float] = []
        try f.source.start { output += $0 }; defer { f.source.stop() }
        f.deliver(end: 100.1)
        f.current = MicrophoneDevice(id: 2, name: "スピーカーフォン")
        f.failNext = true; f.captures[0].change(); f.source.drain()
        try await Task.sleep(for: .milliseconds(40))
        #expect(session.snapshot.message?.contains("試験用の接続失敗") == true)
        let window = TranscriptWindowController(shouldReduceMotion: { true })
        window.window!.setFrameAutosaveName("")
        window.window!.setContentSize(NSSize(width: 640, height: 560))
        window.apply(session.snapshot)
        #expect(window.noticeText == session.snapshot.message)
        f.source.drain(); f.deliver(end: 101.2)
        try await Task.sleep(for: .milliseconds(30))
        let event = try #require(session.snapshot.microphoneSwitches.first)
        #expect(event.audioTime == 1 && event.name == "スピーカーフォン")
        #expect(event.text.hasSuffix(" マイクを スピーカーフォン へ切替"))
        #expect(session.snapshot.message == nil && session.snapshot.utterances.isEmpty)
        var state = session.snapshot
        state.timeline = .init(startedAt: f.wall)
        state.elapsed = 1.2
        state.utterances = [.init(speaker: nil, start: 0, end: 0.8, text: "先に録音を始めます。"),
                            .init(speaker: nil, start: 1.1, end: 2, text: "マイクをつなぎました。続けましょう。")]
        window.apply(state)
        let document = window.transcriptDocument
        #expect(document.rows.count == 3 && document.rows[1] is MicrophoneSwitchRow)
        #expect((document.rows[1] as? MicrophoneSwitchRow)?.label.textColor == Washi.muted)
        window.apply(state)
        #expect(document.rows.filter { $0 is MicrophoneSwitchRow }.count == 1)
        try capture(window.window!.contentView!.superview!, name: "transcript-microphone-switch")
        let lines = TranscriptRenderer.lines(state.utterances, names: state.names, timeline: state.timeline)
        #expect(lines.count == 2 && !lines.joined().contains("へ切替"))
        await session.stop()
        #expect(session.snapshot.microphoneSwitches.count == 1)
        #expect(try !String(contentsOf: url, encoding: .utf8).contains("へ切替"))
        let count = session.snapshot.microphoneSwitches.count
        f.source.onSwitch?("停止後の通知", Date())
        try await Task.sleep(for: .milliseconds(20))
        #expect(session.snapshot.microphoneSwitches.count == count)
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["KIKIGAKI_MICROPHONE_CAPTURE"] else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
    }
    private func waitForMicrophone(_ sheet: StartSheet, name: String) {
        // 並列テストのMainActor復帰順とTimerの発火順は一致しない。
        // タイマーを手動で呼ばず、実際のRunLoopで表示への反映を待つ。
        let deadline = Date().addingTimeInterval(2)
        while sheet.microphoneLabel.stringValue != name, Date() < deadline {
            RunLoop.main.run(mode: .default, before: deadline)
        }
    }
}
