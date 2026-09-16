import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct AudioExclusionAppTests {
    @Test func 除外された音声質問は本番送信経路で止まり明示質問は空本文を送る() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var config = ResolvedConfig(config: KikigakiConfig(outputDir: root.path))
        config.ai = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path), home: root)
        let fake = FakeHerdr()
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        let url = root.appendingPathComponent("meeting.md")
        let session = MeetingSession(testingRecordingAt: url, config: config, aiStore: store, recordedSamples: 16000, diarizationEnabled: false)
        var meter = AudioLevelMeter(); meter.append(Array(repeating: 0.001, count: 16000))
        session.setAudioTranscriptForTesting([.init(speaker: nil, start: 0, end: 1, text: "小声の問い")], meter: meter, url: url)
        session.setAudioExclusion(.init(enabled: true))
        session.submitAI(question: "", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"))
        await session.submissionTaskForTesting?.value
        #expect(session.aiRecord?.controller.conversation.questions.isEmpty == true)
        #expect(await fake.commands.isEmpty)
        session.submitAI(question: "入力した問い", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"))
        await session.submissionTaskForTesting?.value
        let request = try #require(session.aiRecord?.controller.conversation.questions.last?.request)
        #expect(request.displayQuestion == "入力した問い" && request.envelope.totalLineCount == 0)
    }
    @Test func 診断OFFでも除外しコピーと復元と次回設定が一致する() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: "AudioExclusion.\(UUID())"))
        let config = ResolvedConfig(config: KikigakiConfig(outputDir: root.path))
        let session = MeetingSession(config: config, models: { throw CancellationError() }, log: { _ in }, diarizationDefaults: defaults)
        let row = Utterance(speaker: nil, start: 0, end: 1, text: "小声")
        var meter = AudioLevelMeter(); meter.append(Array(repeating: 0.001, count: 16000))
        session.setAudioTranscriptForTesting([row], meter: meter, url: root.appendingPathComponent("meeting.md"))
        session.copyContext(full: true, writeClipboard: { _ in true })
        #expect(session.snapshot.canRecopy)
        let calculationCount = session.audioLevelCalculationCount
        session.setAudioExclusion(.init(enabled: true))
        #expect(session.audioLevelCalculationCount == calculationCount)
        #expect(session.snapshot.audioLevels.isEmpty && session.snapshot.excludedRows == [0])
        #expect(session.snapshot.includedUtterances.isEmpty && !session.snapshot.canRecopy)
        #expect(session.snapshot.handoffPreview?.includesCorrections == true)
        session.copyContext(writeClipboard: { _ in true })
        #expect(session.snapshot.canRecopy)
        session.setAudioExclusion(.init(enabled: true, thresholdDBFS: -70))
        #expect(session.snapshot.includedUtterances == [row])
        #expect(session.audioLevelCalculationCount == calculationCount)
        let next = MeetingSession(config: config, models: { throw CancellationError() }, log: { _ in }, diarizationDefaults: defaults)
        #expect(next.snapshot.audioExclusion.thresholdDBFS == -70 && next.snapshot.audioExclusion.enabled)
    }
    @Test func 除外がOFFのあいだはスライダーとしきい値を畳む() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let popover = SpeakerSettingsPopover(snapshot: SessionSnapshot(state: .recording))
        #expect(popover.exclusionSlider.isHidden && popover.exclusionValue.isHidden)
        popover.exclusionSwitch.state = .on
        popover.exclusionSwitch.sendAction(try #require(popover.exclusionSwitch.action), to: popover.exclusionSwitch.target)
        #expect(!popover.exclusionSlider.isHidden && popover.exclusionValue.stringValue == "-45 dBFS未満を除外")
        popover.close()
    }
    @Test func スライダーの操作値を更新で巻き戻さず閉じると一度だけ反映する() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let snapshot = SessionSnapshot(state: .recording)
        let popover = SpeakerSettingsPopover(snapshot: snapshot)
        var received: [AudioExclusion] = []
        popover.onAudioExclusionChange = { received.append($0) }
        for value in [-60.0, -50, -40] {
            popover.exclusionSlider.doubleValue = value
            popover.exclusionSlider.sendAction(try #require(popover.exclusionSlider.action), to: popover.exclusionSlider.target)
        }
        popover.update(snapshot: snapshot)
        #expect(popover.exclusionSlider.doubleValue == -40 && received.isEmpty)
        popover.close()
        #expect(received.count == 1 && received[0].thresholdDBFS == -40)
    }
    @Test func 連続操作は最後の値を時間差で一度だけ反映する() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let popover = SpeakerSettingsPopover(snapshot: SessionSnapshot(state: .recording))
        var received: [AudioExclusion] = []
        popover.onAudioExclusionChange = { received.append($0) }
        let before = Date()
        for value in [-60.0, -50, -40] {
            popover.exclusionSlider.doubleValue = value
            popover.exclusionSlider.sendAction(try #require(popover.exclusionSlider.action), to: popover.exclusionSlider.target)
        }
        let after = Date()
        #expect(received.isEmpty)
        // 発火を壁時計で待つと並列実行で落ちるため、予定と登録先を検べてから手で発火する。
        let timer = try #require(popover.exclusionDebounceForTesting)
        #expect(timer.isValid)
        #expect(timer.fireDate >= before.addingTimeInterval(0.15) && timer.fireDate <= after.addingTimeInterval(0.15))
        #expect(CFRunLoopContainsTimer(CFRunLoopGetMain(), timer as CFRunLoopTimer, .commonModes))
        popover.fireExclusionDebounceForTesting()
        #expect(received.count == 1 && received[0].thresholdDBFS == -40)
        popover.close()
        #expect(received.count == 1)
    }
    @Test func 停止直前の操作は終了処理後に反映して巻き戻さない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var snapshot = SessionSnapshot(state: .recording)
        let popover = SpeakerSettingsPopover(snapshot: snapshot)
        var received: [AudioExclusion] = []
        popover.onAudioExclusionChange = { received.append($0) }
        popover.exclusionSlider.doubleValue = -40
        popover.exclusionSlider.sendAction(try #require(popover.exclusionSlider.action), to: popover.exclusionSlider.target)
        snapshot.state = .finishing; popover.update(snapshot: snapshot)
        popover.close()
        #expect(received.isEmpty && popover.exclusionSlider.doubleValue == -40)
        snapshot.state = .idle; popover.update(snapshot: snapshot)
        #expect(received.count == 1 && received[0].thresholdDBFS == -40)
    }
    @Test func 除外注釈は診断OFFでも残りアニメーション停止で薄さを失わない() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let row = TranscriptRow()
        row.update(.init(speaker: nil, start: 0, end: 1, text: "小声"), names: SpeakerNames(), timeline: MeetingTimeline(startedAt: Date()))
        let height = row.height(for: 400)
        row.updateExclusion(true)
        row.appear(animated: false); row.highlight(animated: false)
        #expect(row.content.layer?.opacity == 0.4 && row.layer?.opacity == 1 && row.height(for: 400) == height + 20)
        #expect(row.content.subviews.compactMap { $0 as? NSTextField }.contains { !$0.isHidden && $0.stringValue == "小音量のため除外" })
        row.updateExclusion(false)
        #expect(row.content.layer?.opacity == 1 && row.height(for: 400) == height)
    }

    @Test func 計測OFFの除外を実画面へ描く() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var snapshot = SessionSnapshot(state: .recording)
        snapshot.audioExclusion = .init(enabled: true)
        snapshot.names.diarizationEnabled = false
        snapshot.utterances = [.init(speaker: nil, start: 0, end: 1, text: "こちらの会議の声は、そのまま残ります。"),
            .init(speaker: nil, start: 1, end: 2, text: "小さな声は薄く残り、しきい値を戻すと復元できます。")]
        snapshot.excludedRows = [1]
        let defaults = try #require(UserDefaults(suiteName: "ExclusionUI.\(UUID())"))
        let window = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults)
        window.window?.setFrameAutosaveName("")
        window.window?.setContentSize(NSSize(width: 650, height: 480))
        window.apply(snapshot)
        let popover = SpeakerSettingsPopover(snapshot: snapshot)
        if let path = ProcessInfo.processInfo.environment["KIKIGAKI_EXCLUSION_CAPTURE"] {
            for (name, view) in [("transcript", try #require(window.window?.contentView)), ("popover", popover.contentView)] {
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path + "-" + name + ".png"))
            }
        }
    }
}
