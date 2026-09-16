import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

// 実際にシートを開くので順番に実行し、複数のモーダル表示を競合させない。
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct URLSchemeAppTests {
    private func makeWindow() throws -> (TranscriptWindowController, () -> Void) {
        let suite = "URLSchemeAppTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults)
        controller.window?.setFrameAutosaveName("")
        return (controller, {
            controller.window?.orderOut(nil)
            defaults.removePersistentDomain(forName: suite)
        })
    }

    @Test func 待機中のリンクは議事録入りの開始シートを開き差し替えもする() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = ResolvedConfig(config: KikigakiConfig(), home: root)
        let session = MeetingSession(config: config, models: { throw CancellationError() }, log: { _ in },
                                     aiStore: AIRecordStore(directory: root))
        let (window, teardown) = try makeWindow(); defer { teardown() }
        let app = AppDelegate(testingSession: session, config: config, window: window)
        app.open(url: "kikigaki://start?minutes=/work/minutes/2026-09-16%20%E5%AE%9A%E4%BE%8B.md")
        let sheet = try #require(app.startSheet)
        defer { sheet.cancelPressed() }
        #expect(sheet.minutesBox.stringValue == "/work/minutes/2026-09-16 定例.md")
        #expect(sheet.options?.minutesPath == "/work/minutes/2026-09-16 定例.md")
        // 開いている最中の指定はパス欄を差し替える。シートは開き直さない。
        app.open(url: "kikigaki://start?minutes=/work/minutes/%E5%88%A5.md")
        #expect(app.startSheet === sheet)
        #expect(sheet.minutesBox.stringValue == "/work/minutes/別.md")
    }

    @Test func 読めない議事録はパス欄を空のまま理由だけを出す() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = ResolvedConfig(config: KikigakiConfig(), home: root)
        let session = MeetingSession(config: config, models: { throw CancellationError() }, log: { _ in },
                                     aiStore: AIRecordStore(directory: root))
        let (window, teardown) = try makeWindow(); defer { teardown() }
        let app = AppDelegate(testingSession: session, config: config, window: window)
        app.open(url: "kikigaki://start?minutes=relative.txt")
        let sheet = try #require(app.startSheet)
        defer { sheet.cancelPressed() }
        #expect(sheet.minutesBox.stringValue.isEmpty)
        #expect(sheet.minutesHintText == KikigakiURL.minutesProblem)
        // 議事録が無いリンクは、理由を出さずシートを開くだけ。
        app.open(url: "kikigaki://start")
        #expect(sheet.minutesBox.stringValue.isEmpty)
        #expect(sheet.minutesHintText == KikigakiURL.minutesProblem)
    }

    @Test func 録音中はシートを出さず理由をヘッダーへ出す() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = ResolvedConfig(config: KikigakiConfig(), home: root)
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"),
                                     config: config, aiStore: AIRecordStore(directory: root))
        let (window, teardown) = try makeWindow(); defer { teardown() }
        let app = AppDelegate(testingSession: session, config: config, window: window)
        app.open(url: "kikigaki://start?minutes=/work/minutes/a.md")
        #expect(app.startSheet == nil)
        #expect(window.noticeText == "録音中のため、リンクの指定は受け取れません")
    }

    @Test func start以外のリンクは待機中でも何も起こさない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = ResolvedConfig(config: KikigakiConfig(), home: root)
        let session = MeetingSession(config: config, models: { throw CancellationError() }, log: { _ in },
                                     aiStore: AIRecordStore(directory: root))
        let (window, teardown) = try makeWindow(); defer { teardown() }
        let app = AppDelegate(testingSession: session, config: config, window: window)
        defer { app.startSheet?.cancelPressed() }
        for text in ["kikigaki://stop?minutes=/work/a.md", "https://example.com/start?minutes=/work/a.md"] {
            app.open(url: text)
            #expect(app.startSheet == nil && window.noticeText.isEmpty, "\(text)")
        }
    }
}
