import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct AISheetDismissalTests {
    private func parentWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 20000, y: 20000, width: 600, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.orderFront(nil)
        return window
    }
    private func click(_ window: NSWindow, at point: NSPoint = NSPoint(x: 5, y: 5)) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test(arguments: ["手動", "自動", "準備"]) func 親側のクリックを消費して閉じ監視を解除する(kind: String) throws {
        let parent = parentWindow(); defer { parent.orderOut(nil) }
        let ask = AIQuestionSheet(participant: "迅雷", parentNumber: nil, draft: "下書き", voice: "", range: "", tentative: false, canSubmit: true)
        let auto = AIScheduleSheet(prompt: "依頼", minutes: 3, workAllowed: true)
        let prepare = AIPrepareSheet(profiles: [(1, "迅雷")], selected: 1)
        var closed = 0
        ask.onCancel = { closed += 1 }; auto.onCancel = { closed += 1 }; prepare.onCancel = { closed += 1 }
        let window = try #require((kind == "手動" ? ask.window : kind == "自動" ? auto.window : prepare.window) as? AIQuestionWindow)
        if kind == "手動" { ask.present(on: parent) }
        else if kind == "自動" { auto.present(on: parent) }
        else { prepare.present(on: parent) }
        #expect(window.monitorsOutsideClicks)
        #expect(window.handleOutsideClick(try click(window)) != nil && closed == 0)
        let other = parentWindow(); defer { other.orderOut(nil) }
        #expect(window.handleOutsideClick(try click(other)) != nil && closed == 0)
        #expect(window.handleOutsideClick(try click(parent)) == nil)
        #expect(closed == 1 && !window.monitorsOutsideClicks)
        #expect(window.handleOutsideClick(try click(parent)) != nil && closed == 1)
    }

    @Test func 局所イベント監視から親側クリックを受け取る() throws {
        let parent = parentWindow(); defer { parent.orderOut(nil) }
        let sheet = AIScheduleSheet(prompt: "依頼", minutes: 3, workAllowed: true)
        var closed = false; sheet.onCancel = { closed = true }
        sheet.present(on: parent)
        NSApp.sendEvent(try click(parent))
        #expect(closed)
        sheet.close()
    }

    @Test func 準備シートの名前編集中もEscで同じ閉じる経路を通る() throws {
        let parent = parentWindow(); defer { parent.orderOut(nil) }
        let sheet = AIPrepareSheet(profiles: [(1, "迅雷")], selected: 1)
        var closed = 0; sheet.onCancel = { closed += 1 }
        sheet.present(on: parent); sheet.window.makeFirstResponder(sheet.nameField)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: sheet.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        sheet.window.sendEvent(event)
        #expect(closed == 1 && (sheet.window as? AIQuestionWindow)?.monitorsOutsideClicks == false)
    }

    @Test func 紐づけシートは外側クリックでは閉じない() throws {
        let parent = parentWindow(); defer { parent.orderOut(nil) }
        let sheet = AIAttachSheet(choices: [.init(slot: 1, name: "迅雷", prepared: [])])
        var cancelled = false; sheet.onCancel = { cancelled = true }
        sheet.present(on: parent)
        let window = try #require(sheet.window as? AIQuestionWindow)
        #expect(!window.monitorsOutsideClicks)
        #expect(window.handleOutsideClick(try click(parent)) != nil && !cancelled)
        sheet.close()
    }

    @Test func 本番の閉じる処理は送信準備と自動実行を止めない() async throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let config = ResolvedConfig(config: try ConfigLoader.parse(toml: """
        [ai]
        command = "/bin/echo"
        cwd = "\(root.path)"
        """), home: root)
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config, aiStore: store)
        let prepared = AIPreparedStore(directory: root.appendingPathComponent("prepared"))
        let app = AppDelegate(testingSession: session, config: config, preparedStore: prepared)
        try session.startAISchedule(options: AIScheduleOptions(prompt: "議事録を更新", interval: 180), helper: URL(fileURLWithPath: "/bin/echo"))
        defer { session.stopAISchedule() }
        session.beginAIDraft()
        session.submitAI(question: "確認してください", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"))
        let task = try #require(session.submissionTaskForTesting)
        app.dismissAISheet()
        #expect(!task.isCancelled && session.snapshot.aiSchedule.active)
        await task.value
        #expect(session.aiRecord?.controller.conversation.questions.first?.state == .submitted)
        #expect(session.snapshot.aiSchedule.active)
    }
}
