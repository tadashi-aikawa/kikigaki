import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct AudioLevelAppTests {
    @Test func 注釈だけの更新でも行の高さが変わり本文を隠さない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let voice = Utterance(speaker: nil, start: 0, end: 1, text: "小さな声も、そのまま表示と送信に残します。")
        var meter = AudioLevelMeter(); meter.append(Array(repeating: 0.001, count: 16000))
        let assessment = try #require(meter.track().assessments(for: [voice])[0])
        let row = TranscriptRow()
        row.update(voice, names: SpeakerNames(), timeline: MeetingTimeline(startedAt: Date()))
        let originalHeight = row.height(for: 360)
        row.updateAudioLevel(assessment)
        #expect(row.height(for: 360) == originalHeight + 20)
        row.frame = NSRect(x: 0, y: 0, width: 360, height: row.height(for: 360))
        row.layoutSubtreeIfNeeded()
        let labels = row.content.subviews.compactMap { $0 as? NSTextField }
        let label = try #require(labels.first { $0.stringValue.contains("小音量候補") })
        let body = try #require(labels.first { $0.stringValue == voice.text })
        #expect(!label.isHidden && !body.isHidden && label.frame.minY >= body.frame.maxY)
        #expect(label.frame.maxY <= row.bounds.height)
        row.updateAudioLevel(nil)
        #expect(row.height(for: 360) == originalHeight && label.isHidden)
    }

    @Test func 計測中の本文と手入力を実ウィンドウで描く() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var meter = AudioLevelMeter()
        meter.append(Array(repeating: 0.1, count: 16000))
        meter.append(Array(repeating: 0.001, count: 16000))
        var snapshot = SessionSnapshot(state: .recording)
        snapshot.names.diarizationEnabled = false
        snapshot.utterances = [.init(speaker: nil, start: 0, end: 1, text: "普段の声で話しています。"),
                               .init(speaker: nil, start: 1, end: 2, text: "小さな声も、消さずに残しています。"),
                               try .init(typedText: "手入力は音量の計測対象外です。", at: 2, postedAt: Date())]
        snapshot.audioLevels = meter.track().assessments(for: snapshot.utterances)
        #expect(snapshot.audioLevels.last! == nil)
        let defaults = try #require(UserDefaults(suiteName: "AudioLevelUI.\(UUID())"))
        let window = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults)
        window.window?.setFrameAutosaveName("")
        window.window?.setContentSize(NSSize(width: 600, height: 500))
        window.apply(snapshot)
        if let path = ProcessInfo.processInfo.environment["KIKIGAKI_LEVEL_CAPTURE"] {
            let view = try #require(window.window?.contentView)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }

    @Test func 実Speechと併用し一時停止と設定固定と取り止めを守る() async throws {
        guard ProcessInfo.processInfo.environment["KIKIGAKI_TEST_SPEECH"] == "1" else { return }
        final class ManualSource: AudioSource {
            var receive: (([Float]) -> Void)?
            func start(onSamples: @escaping ([Float]) -> Void) throws { receive = onSamples }
            func stop() { receive = nil }
        }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var config = ResolvedConfig(config: KikigakiConfig(outputDir: root.path, measureAudioLevels: true))
        let session = MeetingSession(config: config, models: { Issue.record("モデル不要"); throw CancellationError() }, log: { _ in })
        session.setDiarizationEnabled(false)
        let source = ManualSource()
        #expect(await session.start(source: source))
        source.receive?(Array(repeating: 0.01, count: 1600))
        session.togglePause()
        source.receive?(Array(repeating: 1, count: 16000))
        session.togglePause()
        source.receive?(Array(repeating: 0.001, count: 321))
        config.measureAudioLevels = false
        session.update(config: config)
        await session.stop()
        let url = try #require(session.snapshot.markdownURL)
        let report = try JSONDecoder().decode(AudioLevelReport.self, from: Data(contentsOf: MeetingFiles.levelsURL(for: url)))
        #expect(report.track.sampleCount == 1921 && report.track.levels.count == 2)
        #expect(session.snapshot.saved)
        #expect(!FileManager.default.fileExists(atPath: MeetingFiles.wavURL(for: url).path))
        #expect(await session.start(source: source))
        source.receive?(Array(repeating: 0, count: 1600))
        await session.stop()
        let disabledURL = try #require(session.snapshot.markdownURL)
        #expect(!FileManager.default.fileExists(atPath: MeetingFiles.levelsURL(for: disabledURL).path))
        config.measureAudioLevels = true; session.update(config: config)
        #expect(await session.start(source: source))
        let abandonedURL = try #require(session.snapshot.markdownURL)
        source.receive?(Array(repeating: 0, count: 1600))
        await session.abandon()
        #expect(!FileManager.default.fileExists(atPath: MeetingFiles.levelsURL(for: abandonedURL).path))
        #expect(!FileManager.default.fileExists(atPath: abandonedURL.path))
    }
}
