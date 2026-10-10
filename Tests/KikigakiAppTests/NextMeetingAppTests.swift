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
}
