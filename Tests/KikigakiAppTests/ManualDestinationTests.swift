import AppKit
import Foundation
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct ManualDestinationTests {
    private func profiles(_ root: URL) -> [ResolvedAIConfig] {
        ["議事録", "スライド"].enumerated().map {
            ResolvedAIConfig(config: AIConfig(name: $0.element, command: "/bin/echo", cwd: root.path,
                                              initialPrompt: $0.element + "を更新"), home: root, slot: $0.offset + 1)
        }
    }

    @Test func 手動宛先は前回を覚え初回と削除済みだけ先頭へ戻る() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ManualDestinationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let list = profiles(root)
        for (name, slot) in [(nil, Int?(1)), ("スライド", 2), ("削除済み", 1), ("", nil)] {
            if let name { defaults.set(name, forKey: StartSheet.manualDefaultsKey) }
            else { defaults.removeObject(forKey: StartSheet.manualDefaultsKey) }
            let sheet = StartSheet(profiles: list, diarizationEnabled: true, exclusion: AudioExclusion(), defaults: defaults)
            #expect(sheet.selectedManualSlot == slot)
            #expect(sheet.options?.manualSlot == slot)
            #expect(sheet.manualDestination.menu?.items.map { String($0.title.split(separator: "\n")[0]) } == ["指定しない", "議事録", "スライド"])
            sheet.close()
        }
        let empty = StartSheet(profiles: [], diarizationEnabled: true, exclusion: AudioExclusion(), defaults: defaults)
        #expect(empty.manualDestination.superview == nil)
        empty.close()
    }

    @Test func 予約の指定と省略と不明宛先と指定しないを前回へ重ねる() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ManualDestinationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("議事録", forKey: StartSheet.manualDefaultsKey)
        let reservations = try ["スライド", nil, "削除済み"].enumerated().map {
            try NextMeeting(minutesPath: root.appendingPathComponent("\($0.offset).md").path,
                            ai: "議事録", manual: $0.element, createdAt: Date(timeIntervalSince1970: Double($0.offset)))
        }
        let sheet = StartSheet(profiles: profiles(root), diarizationEnabled: true, exclusion: AudioExclusion(),
                               nextMeetings: reservations, defaults: defaults)
        defer { sheet.close() }
        #expect(sheet.selectedManualSlot == 2 && sheet.options?.scheduleSlot == 1)
        #expect(sheet.nextDetails[0].stringValue.contains("手動: スライド"))
        sheet.selectNextMeeting(at: 1)
        #expect(sheet.selectedManualSlot == 1)
        sheet.selectNextMeeting(at: 2)
        #expect(sheet.selectedManualSlot == 1 && sheet.nextDetails[2].textColor == Washi.gold)
        sheet.selectNextMeeting(at: 0)
        sheet.selectNextMeeting(at: 3)
        #expect(sheet.selectedManualSlot == 1)
        // 取消前の編集は前回の記憶に書き戻さない。
        sheet.selectManualDestination(2)
        sheet.cancelPressed()
        #expect(defaults.string(forKey: StartSheet.manualDefaultsKey) == "議事録")
    }

    @Test func 手動シートは現在の宛先から開き選び直しだけでは会議の宛先を変えない() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var config = ResolvedConfig(config: KikigakiConfig(), home: root)
        config.aiProfiles = profiles(root)
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
                                     aiStore: AIRecordStore(directory: root))
        session.pendingManualDestination = .init(slot: 2)
        session.beginNextMeetingForTesting(recording: true)
        session.selectManualSheetDestination()
        #expect(session.aiConfiguration?.slot == 2)
        session.selectAIProfile(slot: 1)
        #expect(session.meetingManualAI?.slot == 2)
        session.selectManualSheetDestination()
        #expect(session.aiConfiguration?.slot == 2)
        session.pendingManualDestination = .init(slot: nil)
        session.beginNextMeetingForTesting(recording: true)
        session.selectManualSheetDestination()
        #expect(session.meetingManualAI == nil && session.aiConfiguration?.slot == 1)
    }

    @Test func 本番の手動実行シートは開くたび会議の宛先を初期選択する() throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var config = ResolvedConfig(config: KikigakiConfig(), home: root)
        config.aiProfiles = profiles(root)
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
                                     aiStore: AIRecordStore(directory: root))
        let suite = "ManualDestinationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults)
        window.window?.setFrameAutosaveName("")
        defer { window.window?.orderOut(nil) }
        let app = AppDelegate(testingSession: session, config: config, window: window)
        window.onAskAI = { [weak app] in app?.showAISheet(parent: $0) }
        let manual = window.compactFooter.manualDestination
        // performClickはハイライト中に入れ子のRunLoopを回す。シートのアニメーションが
        // Swift Testingの外側のメインループまで止め、未完のままexit(0)するため、
        // ボタンに配線された本番のtarget/actionを直接送ってシートへの遷移を検証する。
        // ランタイム側の問題: https://github.com/swiftlang/swift/issues/91716
        session.setMeetingManualDestination(slot: 2)
        for _ in 0..<2 {
            session.selectAIProfile(slot: 1)
            window.apply(session.snapshot)
            #expect(manual.sendAction(manual.action, to: manual.target))
            #expect(app.aiSheet?.draft == "スライドを更新")
            #expect(session.aiConfiguration?.slot == 2)
            app.dismissAISheet()
        }
        session.setMeetingManualDestination(slot: nil)
        window.apply(session.snapshot)
        #expect(window.compactFooter.manualDestination.isEnabled)
        #expect(manual.sendAction(manual.action, to: manual.target))
        #expect(app.aiSheet?.draft == "議事録を更新")
        app.dismissAISheet()
    }

    @Test func 合図は未送信のシートで選び直した宛先へ切り替えない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var config = ResolvedConfig(config: KikigakiConfig(), home: root)
        config.aiProfiles = profiles(root)
        let fake = FakeHerdr()
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
                                     aiStore: store, recordedSamples: 16_000)
        session.automaticHelper = URL(fileURLWithPath: "/bin/echo")
        session.setMeetingManualDestination(slot: 2)
        session.selectAIProfile(slot: 1)
        session.updateManualDraft("スライドの下書き", slot: 2)
        // 別宛先の自動が返事待ちでも、会議の手動宛先へ送れる。
        session.setScheduleTranscriptForTesting("会議の内容")
        try session.startAISchedule(options: .init(prompt: "自動の文面", interval: 3600, sendFinal: false),
                                    helper: URL(fileURLWithPath: "/bin/echo"), profile: config.aiProfiles[0])
        defer { session.stopAISchedule() }
        await session.submissionTaskForTesting(slot: 1)?.value
        var sounds: [Bool] = []; session.playAutoSendSound = { sounds.append($0) }
        session.publishForTesting(tokens: [.init(text: "アバンティ", phraseId: -1, start: 0, end: 1)],
                                  speakers: [0], elapsed: 1, finalCount: 1, accurateFinalCount: 0)
        await session.submissionTaskForTesting(slot: 2)?.value
        let questions = try #require(session.aiRecord?.controller.conversation.questions)
        #expect(questions.count == 2)
        #expect(questions[0].request.trigger == .scheduled)
        #expect(questions[1].request.trigger == nil && questions[1].request.envelope.participant.profileSlot == 2)
        #expect(questions[1].request.envelope.participant.question == "スライドの下書き")
        #expect(sounds == [true])
    }
}
