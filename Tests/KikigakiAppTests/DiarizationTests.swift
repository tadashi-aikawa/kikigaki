import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct DiarizationTests {
    private func config(_ root: URL) throws -> ResolvedConfig {
        ResolvedConfig(config: try ConfigLoader.parse(toml: "outputDir = \"\(root.path)\""))
    }

    @Test func 選択は再生成後も残り会議中は変更できず停止後は次回だけ変える() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "DiarizationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = try config(root)
        let first = MeetingSession(config: config, models: { throw CancellationError() }, log: { _ in }, diarizationDefaults: defaults)
        #expect(first.snapshot.nextDiarizationEnabled)
        first.setDiarizationEnabled(false)
        let second = MeetingSession(config: config, models: { throw CancellationError() }, log: { _ in }, diarizationDefaults: defaults)
        #expect(!second.snapshot.nextDiarizationEnabled)
        let store = AIRecordStore(directory: root)
        let recording = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
                                       aiStore: store, diarizationEnabled: false)
        recording.setDiarizationEnabled(false)
        #expect(recording.snapshot.nextDiarizationEnabled) // 録音中の変更は無視する。
        recording.togglePause()
        recording.setDiarizationEnabled(false)
        #expect(recording.snapshot.nextDiarizationEnabled)
        await recording.stop()
        recording.setDiarizationEnabled(true)
        #expect(recording.snapshot.nextDiarizationEnabled)
        #expect(!recording.snapshot.displayedDiarizationEnabled)
        #expect(!recording.snapshot.names.diarizationEnabled)
    }

    @Test func 一時停止中の確定通知を表示し次の会議へ古い通知を混ぜない() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AIRecordStore(directory: root)
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: try config(root),
                                     aiStore: store, diarizationEnabled: false)
        let receive = session.undiarizedResultHandlerForTesting
        let tokens = [TimedToken(text: "はい。", phraseId: 1, start: 0, end: 1),
                      TimedToken(text: "進めます。", phraseId: 2, start: 1.1, end: 2)]
        receive(tokens, 1)
        #expect(session.snapshot.utterances.map(\.text) == ["はい。"])
        #expect(session.snapshot.tentativeText == "進めます。")
        session.togglePause()
        receive(tokens, 2)
        #expect(session.snapshot.utterances.map(\.text) == ["はい。", "進めます。"])
        #expect(session.snapshot.tentativeText == nil && session.snapshot.pendingSpeakerRows.isEmpty)
        let previous = session.snapshot.utterances
        session.beginNextMeetingForTesting(recording: true)
        receive([.init(text: "古い通知", phraseId: 3, start: 2, end: 3)], 1)
        #expect(session.snapshot.utterances == previous)
    }

    /// 話者判別の切替は録音開始シートへ移した。ポップオーバーは表示中の会議だけを扱う。
    @Test func 状態別に開始シートのラジオとヘッダーの対象を保つ() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var snapshot = SessionSnapshot()
        let popover = SpeakerSettingsPopover(snapshot: snapshot)
        let button = SpeakerCountButton()
        let sheet = StartSheet(profiles: [], diarizationEnabled: true, exclusion: AudioExclusion())
        #expect(sheet.diarizeOn.state == .on && sheet.diarizeOff.state == .off)
        #expect(sheet.options?.diarizationEnabled == true)
        sheet.diarizeOff.performClick(nil)
        #expect(sheet.options?.diarizationEnabled == false)
        let off = StartSheet(profiles: [], diarizationEnabled: false, exclusion: AudioExclusion())
        #expect(off.diarizeOff.state == .on && off.options?.diarizationEnabled == false)
        for state in [RecordingState.preparing, .recording, .paused, .finishing] {
            snapshot.state = state
            snapshot.names.diarizationEnabled = false
            popover.update(snapshot: snapshot); button.update(snapshot: snapshot)
            #expect(button.countText == "なし")
        }
        snapshot.state = .idle; snapshot.markdownURL = URL(fileURLWithPath: "/tmp/meeting.md")
        snapshot.names.diarizationEnabled = true; snapshot.detectedSpeakerSlots = [0, 1]
        snapshot.nextDiarizationEnabled = false
        popover.update(snapshot: snapshot); button.update(snapshot: snapshot)
        #expect(button.countText == "2/4")
        try capture("stopped-on-next-off", popover.contentView)
        snapshot.names.diarizationEnabled = false; snapshot.nextDiarizationEnabled = true
        popover.update(snapshot: snapshot); button.update(snapshot: snapshot)
        #expect(button.countText == "なし")
        try capture("stopped-off-next-on", popover.contentView)
        snapshot.state = .recording; snapshot.nextDiarizationEnabled = false
        popover.update(snapshot: snapshot)
        try capture("recording-off", popover.contentView)
        snapshot = SessionSnapshot(); snapshot.nextDiarizationEnabled = false
        popover.update(snapshot: snapshot)
        try capture("idle-off", popover.contentView)
        let suite = "DiarizationUI.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults)
        window.window?.setFrameAutosaveName("")
        window.window?.setContentSize(NSSize(width: 600, height: 578))
        snapshot.state = .recording; snapshot.names.diarizationEnabled = false
        snapshot.utterances = [.init(speaker: nil, start: 1, end: 3, text: "今日の方針を整理します。"),
                               .init(speaker: nil, start: 3.1, end: 5, text: "次のフキダシへ分かれます。")]
        window.apply(snapshot)
        try capture("transcript-off", try #require(window.window?.contentView))
    }

    @Test func 暫定通知をまとめても確定は即時に反映する() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: try config(root),
            aiStore: AIRecordStore(directory: root), diarizationEnabled: false)
        let receive = session.undiarizedResultHandlerForTesting
        func token(_ text: String) -> [TimedToken] { [.init(text: text, phraseId: 1, start: 0, end: 1)] }
        var changes = 0
        session.onChange = { _ in changes += 1 }
        receive(token("最初"), 0)
        receive(token("途中"), 0)
        receive(token("最新の暫定"), 0)
        #expect(changes == 1)
        #expect(session.snapshot.tentativeText == "最初")
        // 入力が止まっても末尾の暫定を捨てない。
        let pending = try #require(session.pendingUndiarizedDrawForTesting)
        await pending.value
        #expect(session.snapshot.tentativeText == "最新の暫定")
        #expect(changes == 2)
        receive(token("確定"), 1)
        #expect(changes == 3 && session.snapshot.tentativeText == nil)
        #expect(session.snapshot.utterances.map(\.text) == ["確定"])
        await session.stop()
    }

    @Test func 停止の途中に届く通知や改名と統合を受け付けない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var receive: (([TimedToken], Int) -> Void)?
        var session: MeetingSession!
        session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: try config(root),
            aiStore: AIRecordStore(directory: root), finishAudio: {
                #expect(session.snapshot.state == .finishing)
                let before = session.snapshot.utterances
                receive?([.init(text: "後着", phraseId: 2, start: 1, end: 2)], 1)
                #expect(session.snapshot.utterances == before)
            }, diarizationEnabled: false)
        receive = session.undiarizedResultHandlerForTesting
        receive?([.init(text: "最初", phraseId: 1, start: 0, end: 1)], 1)
        session.rename(slot: 0, to: "改名禁止")
        session.setSpeakerMapping(source: 0, target: 1)
        #expect(session.snapshot.names.customName(for: 0) == nil)
        #expect(session.snapshot.speakerOverrides.isEmpty)
        await session.stop()
        let after = session.snapshot.utterances
        receive?([.init(text: "停止後", phraseId: 3, start: 2, end: 3)], 1)
        #expect(session.snapshot.utterances == after)
        session = nil
    }

    /// オンデバイスSpeechを使う結合検証。通常のテストではモデル・言語アセットを要求しない。
    @Test func 本番の開始停止でモデルを読み込まず相槌省略ファイルを作らない() async throws {
        guard ProcessInfo.processInfo.environment["KIKIGAKI_TEST_SPEECH"] == "1" else { return }
        final class Silence: AudioSource {
            func start(onSamples: @escaping ([Float]) -> Void) throws { onSamples(Array(repeating: 0, count: 1600)) }
            func stop() {}
        }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var settings = try ConfigLoader.parse(toml: "outputDir = \"\(root.path)\"\ndropRepeatedBackchannels = true")
        settings.saveRecording = false
        var modelCalls = 0
        let session = MeetingSession(config: ResolvedConfig(config: settings), models: {
            modelCalls += 1; throw CancellationError()
        }, log: { _ in })
        session.setDiarizationEnabled(false)
        #expect(await session.start(source: Silence()))
        #expect(!session.snapshot.names.diarizationEnabled)
        await session.stop()
        #expect(modelCalls == 0 && session.snapshot.saved)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(files.filter { $0.hasSuffix(".md") }.count == 1)
        #expect(!files.contains { $0.hasSuffix(".raw.md") })
        session.setDiarizationEnabled(true)
        #expect(await !session.start(source: Silence()))
        #expect(modelCalls == 1)
        session.setDiarizationEnabled(false)
        #expect(await session.start(source: Silence()))
        #expect(modelCalls == 1 && !session.snapshot.names.diarizationEnabled)
        await session.stop()
    }

    private func capture(_ name: String, _ view: NSView) throws {
        guard let path = ProcessInfo.processInfo.environment["KIKIGAKI_DIARIZATION_CAPTURE"] else { return }
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
    }

    @Test func replayの無効指定は日常の設定と独立する() throws {
        #expect(try ReplayDebugOptions.load(arguments: [], environment: ["KIKIGAKI_DEBUG_DIARIZATION": "off"]).diarizationEnabled == nil)
        #expect(try ReplayDebugOptions.load(arguments: ["--replay"], environment: ["KIKIGAKI_DEBUG_DIARIZATION": "off"]).diarizationEnabled == false)
        #expect(throws: (any Error).self) {
            try ReplayDebugOptions.load(arguments: ["--replay"], environment: ["KIKIGAKI_DEBUG_DIARIZATION": "invalid"])
        }
    }
}
