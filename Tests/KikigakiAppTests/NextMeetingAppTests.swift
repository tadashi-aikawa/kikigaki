import AppKit
import Foundation
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import Kikigaki

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct NextMeetingAppTests {
    @Test func シートを開く時だけ失効分を消し取消は予約を残す() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = NextMeetingStore(directory: root.appendingPathComponent("next"))
        let expired = try NextMeeting(minutesPath: root.appendingPathComponent("古い.md").path,
                                      createdAt: Date().addingTimeInterval(-86_401))
        let next = try NextMeeting(minutesPath: root.appendingPathComponent("次.md").path)
        try store.add(expired); try store.add(next)
        let config = ResolvedConfig(config: KikigakiConfig(), home: root)
        let session = MeetingSession(config: config, models: { throw CancellationError() }, log: { _ in },
                                     aiStore: AIRecordStore(directory: root))
        let suite = "NextMeetingAppTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults)
        window.window?.setFrameAutosaveName("")
        defer { window.window?.orderOut(nil) }
        let app = AppDelegate(testingSession: session, config: config, window: window, nextMeetingStore: store)
        app.presentStartSheet()
        let sheet = try #require(app.startSheet)
        // 録音ボタンの二重押しでも同じシートへ焦点を戻す。
        app.presentStartSheet()
        #expect(app.startSheet === sheet)
        #expect(window.window?.attachedSheet === sheet.window)
        #expect(window.window?.sheets.count == 1)
        #expect(sheet.nextMeetings.map(\.id) == [next.id])
        #expect(sheet.options?.minutesPath == next.minutesPath)
        #expect(try store.load().meetings.map(\.id) == [next.id])
        sheet.cancelPressed()
        #expect(app.startSheet == nil)
        #expect(try store.load().meetings.map(\.id) == [next.id])
        app.presentStartSheet()
        #expect(app.startSheet?.minutesBox.stringValue == next.minutesPath)
        app.startSheet?.cancelPressed()
    }

    @Test(arguments: ["選択", "別のパス", "指定しない", "開始失敗", "不正パス", "取消"])
    func 開始時は選んだ一件だけを消費し未使用と失敗と取消は残す(_ scenario: String) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = NextMeetingStore(directory: root.appendingPathComponent("next"))
        let path = root.appendingPathComponent("共通.md").path
        let first = try NextMeeting(minutesPath: path, title: "先の会議", createdAt: Date().addingTimeInterval(-2))
        let second = try NextMeeting(minutesPath: path, title: "後の会議", createdAt: Date().addingTimeInterval(-1))
        try store.add(first); try store.add(second)
        let config = ResolvedConfig(config: KikigakiConfig(), home: root)
        let session = MeetingSession(config: config, models: { throw CancellationError() }, log: { _ in },
                                     aiStore: AIRecordStore(directory: root))
        let app = AppDelegate(testingSession: session, config: config, nextMeetingStore: store)
        let sheet = StartSheet(profiles: [], diarizationEnabled: false, exclusion: AudioExclusion(),
                               nextMeetings: try store.load().candidates)
        defer { sheet.close() }
        sheet.selectNextMeeting(at: 1)
        #expect(sheet.options?.nextMeetingID == second.id)
        switch scenario {
        case "別のパス": sheet.minutesBox.stringValue = root.appendingPathComponent("別.md").path
        case "指定しない":
            sheet.selectNextMeeting(at: sheet.nextMeetings.count)
            // 予約と同じパスを手入力しても、選ばなかった予約は消費しない。
            sheet.minutesBox.stringValue = path
        case "不正パス": sheet.minutesBox.stringValue = "relative.md"
        default: break
        }
        var submitted: StartSheet.Options?
        sheet.onStart = { options in
            submitted = options
            // マイクやモデルを使わず、実際の開始後と同じ消費経路へ成功・失敗を渡す。
            app.consumeNextMeeting(options: options, started: scenario != "開始失敗")
        }
        if scenario == "取消" { sheet.cancelPressed() }
        else { sheet.startPressed() }
        #expect(try store.load().meetings.map(\.id) == (scenario == "選択" ? [first.id] : [first.id, second.id]))
        switch scenario {
        case "選択", "開始失敗": #expect(submitted?.nextMeetingID == second.id)
        case "不正パス", "取消": #expect(submitted == nil)
        default:
            #expect(submitted != nil)
            #expect(submitted?.nextMeetingID == nil)
        }
    }
}
