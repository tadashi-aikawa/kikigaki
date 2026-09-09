import AppKit
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import Kikigaki

@Suite(.timeLimit(.minutes(1))) @MainActor struct AIScheduleReviewTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func key(_ window: NSWindow, code: UInt16, shift: Bool = false) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: code == 36 ? "\r" : "\u{1b}", charactersIgnoringModifiers: code == 36 ? "\r" : "\u{1b}",
            isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }

    @Test func 自動シートのキー入力と失敗後の再操作と下書き() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let sheet = AIScheduleSheet(prompt: "依頼", minutes: 3, workAllowed: true)
        let editor = try #require(descendants(sheet.window.contentView!).compactMap { $0 as? AIQuestionEditor }.first)
        sheet.window.makeFirstResponder(editor)
        var submitted = 0, cancelled = 0, draft = ""
        sheet.onStart = { _ in submitted += 1 }; sheet.onCancel = { cancelled += 1 }; sheet.onDraft = { draft = $0 }
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        try key(sheet.window, code: 36, shift: true)
        #expect(editor.string.contains("\n") && submitted == 0)
        editor.setMarkedText("へんかん", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try key(sheet.window, code: 36)
        #expect(!editor.hasMarkedText() && submitted == 0)
        editor.setMarkedText("取消候補", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try key(sheet.window, code: 53)
        #expect(cancelled == 0)
        editor.unmarkText(); sheet.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(draft == editor.string)
        try key(sheet.window, code: 36); #expect(submitted == 1)
        sheet.update(warning: "開始できませんでした")
        try key(sheet.window, code: 36); #expect(submitted == 2)
        try key(sheet.window, code: 53); #expect(cancelled == 1)
    }

    /// 実herdrの保存済み会議を土台に、同じ本文と時刻を保った表示状態を撮る。
    @Test func 保存済み会議の自動送信UI撮影() throws {
        guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"],
              let input = ProcessInfo.processInfo.environment["KIKIGAKI_SCHEDULE_REVIEW_AI"] else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: input)
        let archive = try AIJSON.decode(MeetingArchive.self, from: Data(contentsOf: directory.appendingPathComponent("archive.json")))
        let conversation = try AIJSON.decode(AIConversation.self, from: Data(contentsOf: directory.appendingPathComponent("state.json")))
        func capture(_ name: String, _ view: NSView) throws {
            view.layoutSubtreeIfNeeded()
            if let scroll = descendants(view).compactMap({ $0 as? NSScrollView }).first {
                scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
            }
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
        }
        let sheet = AIScheduleSheet(prompt: "", minutes: 3, workAllowed: true)
        try capture("schedule-sheet-empty", sheet.window.contentView!.superview!)
        let editor = try #require(descendants(sheet.window.contentView!).compactMap { $0 as? AIQuestionEditor }.first)
        editor.string = "会議の決定事項と担当・期限をMarkdown議事録へ更新してください。\n変更点を短く返してください。"
        sheet.textDidChange(Notification(name: NSText.didChangeNotification))
        try capture("schedule-sheet", sheet.window.contentView!.superview!)
        let window = TranscriptWindowController(shouldReduceMotion: { true })
        window.window?.setFrameAutosaveName("")
        window.window?.setContentSize(NSSize(width: 600, height: 650))
        let view = try #require(window.window?.contentView?.superview)
        let meeting = archive.original
        var state = SessionSnapshot(ai: AIViewState(conversation: conversation, connection: .idle), state: .recording,
            utterances: meeting.utterances, timeline: meeting.timeline, names: meeting.names,
            elapsed: meeting.duration, markdownURL: archive.markdownURL)
        state.handoffPreview = HandoffHistory().preview(utterances: state.utterances, names: state.names, timeline: state.timeline)
        state.ai?.conversation = nil
        window.apply(state); try capture("schedule-entry", view)
        state.ai?.conversation = conversation
        var schedule = AIScheduleState(meetingID: conversation.meetingID)
        try schedule.start(options: .init(prompt: editor.string), now: meeting.timeline.date(at: meeting.duration), runID: UUID())
        state.aiSchedule = AIScheduleViewState(schedule: schedule)
        for width in [600, 900] {
            window.window?.setContentSize(NSSize(width: width, height: 650))
            window.apply(state); try capture("schedule-\(width)", view)
        }
        // 先の返事が未到着の状態を復元。本文・保存先は停止後も残す。
        var pending = AIConversation(meetingID: conversation.meetingID)
        for (index, question) in conversation.questions.enumerated() {
            try pending.append(question.request)
            try pending.update(question.request.id) { try $0.beginSending(at: question.sendAttemptedAt!); try $0.submitted() }
            if index < conversation.questions.count - 1, let event = question.result {
                _ = try pending.receive(event, at: question.resultReceivedAt!)
            }
        }
        window.window?.setContentSize(NSSize(width: 600, height: 650))
        state.state = .idle; state.saved = true
        state.ai = AIViewState(conversation: pending, connection: .working, warning: "フック観測を確認できません", canSubmit: false)
        schedule.recordingStopped(); _ = schedule.finalSaveCompleted(succeeded: true)
        state.aiSchedule = AIScheduleViewState(schedule: schedule)
        window.apply(state); try capture("schedule-final-wait", view)
        state.ai = AIViewState(conversation: pending, connection: .disconnected,
            warning: "入力準備を確認できません。herdrで確認してください", canSubmit: false, canRecreate: true)
        state.aiSchedule = AIScheduleViewState(warning: "接続できないため最後の1回を中止しました")
        window.apply(state); try capture("schedule-warning", view)
        let items = AITimeline.items(conversation: conversation, utterances: [], timeline: MeetingTimeline(startedAt: Date()))
        #expect(items.map(\.kind) == [.sendLine(automatic: true), .reply(.answered)])
        #expect(try #require(items.first).notes == ["対象: 2発言"])
        #expect(try #require(items.last).body == conversation.questions[0].result?.body)
        // 自動のansweredは取り込み時点で既読なので、印も帯も出さない。
        #expect(items.allSatisfy { !$0.isUnread })
    }
}
