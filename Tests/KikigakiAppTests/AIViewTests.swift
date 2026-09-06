import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct AIViewTests {
    @Test func 実ビューで状態と返答導線と到着印を検証する() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let started = Date(timeIntervalSince1970: 1_788_759_600)
        let meeting = UUID(), config = ResolvedAIConfig(config: AIConfig(), home: root)
        let controller = try AIConversationController(meetingID: meeting, outputDirectory: root, herdr: AIHerdr(run: { _, _ in throw AIHerdrError.notReady }))
        let request = try controller.prepare(lines: ["[14:05:30] 田中: 迅雷、抜けている観点はありますか。"], question: "抜けている観点はありますか", voiceQuestion: "",
            capturedAt: started.addingTimeInterval(330), cutoff: 330, tail: nil, config: config, helper: root.appendingPathComponent("helper"))
        var conversation = controller.conversation
        try conversation.update(request.id) { try $0.beginSending(at: started.addingTimeInterval(335)); try $0.submitted() }
        var state = SessionSnapshot(ai: AIViewState(conversation: conversation, connection: .working), state: .recording,
            utterances: [Utterance(speaker: 0, start: 320, end: 325, text: "来月の体験会は、まず社内で試しましょう。"),
                         Utterance(speaker: 1, start: 330, end: 334, text: "迅雷、抜けている観点はありますか。"),
                         Utterance(speaker: 0, start: 350, end: 355, text: "次の話題へ進めましょう。")],
            tentativeText: "参加者への案内は", timeline: MeetingTimeline(startedAt: started),
            names: SpeakerNames([0: "田中", 1: "松村"]), elapsed: 375, markdownURL: root.appendingPathComponent("meeting.md"))
        state.handoffPreview = HandoffHistory().preview(utterances: state.utterances, names: state.names, timeline: state.timeline)
        let window = TranscriptWindowController(shouldReduceMotion: { true })
        window.window!.setFrameAutosaveName("")
        window.window!.setFrame(NSRect(x: 20000, y: 20000, width: 600, height: 600), display: false)
        let content = window.window!.contentView!
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func buttons() -> [NSButton] { descendants(content).compactMap { $0 as? NSButton } }
        func capture(_ name: String, view: NSView? = nil) throws {
            guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] else { return }
            content.layoutSubtreeIfNeeded()
            let target = view ?? content.superview!
            target.layoutSubtreeIfNeeded()
            let bitmap = try #require(target.bitmapImageRepForCachingDisplay(in: target.bounds))
            target.cacheDisplay(in: target.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
        }
        window.apply(state)
        #expect(state.ai?.summary == "Q1 · 回答待ち")
        #expect(buttons().contains { $0.title == "AIに質問…  ⌃⌥⌘A" })
        try capture("collapsed")
        content.layoutSubtreeIfNeeded()
        let transcript = try #require(descendants(content).compactMap { $0 as? TranscriptDocument }.first { $0.rows.contains { $0 is AIMarkRow } })
        try #require(buttons().first { $0.title == "最新の発言へ ↓" }).performClick(nil)
        #expect(transcript.anchor().atBottom)
        try #require(buttons().first { $0.title.hasPrefix("▸ AIとのやりとり") }).performClick(nil)
        #expect(transcript.anchor().atBottom)
        try capture("waiting")
        let longText = "対象者\n開催日時\n会場\n連絡方法\n持ち物\n当日の担当者も決めてください。"
        let result = try AIReceiveEvent(request: request, kind: .answered, recordedAt: started.addingTimeInterval(369), body: longText)
        _ = try conversation.receive(result, at: started.addingTimeInterval(370))
        state.ai = AIViewState(conversation: conversation, connection: .idle)
        window.apply(state); content.layoutSubtreeIfNeeded()
        #expect(state.ai?.summary == "Q1 · 未読1件")
        #expect(descendants(content).compactMap { $0 as? AIMarkRow }.contains { $0.title == "Q1 迅雷の回答" && $0.date == started.addingTimeInterval(370) })
        try capture("unread")
        let more = try #require(buttons().first { $0.title == "全文を読む ▾" })
        #expect(!more.isHidden)
        var readID: UUID?
        window.onReadAI = { readID = $0 }
        more.performClick(nil)
        #expect(readID == request.id)
        var confirming = controller.conversation
        try confirming.update(request.id) { try $0.beginSending(at: started.addingTimeInterval(335)) }
        _ = try confirming.receive(AIReceiveEvent(request: request, kind: .needsInput, recordedAt: started.addingTimeInterval(369), body: "参加対象は社内だけですか？", reason: "clarification"), at: started.addingTimeInterval(370))
        state.ai = AIViewState(conversation: confirming, connection: .idle)
        window.apply(state); content.layoutSubtreeIfNeeded()
        #expect(state.ai?.summary == "Q1 · 確認待ち")
        #expect(descendants(content).compactMap { $0 as? AIMarkRow }.contains { $0.title == "Q1 迅雷の確認" })
        var replyID: UUID?
        window.onAskAI = { replyID = $0 }
        let reply = try #require(buttons().first { $0.title == "返答する" })
        #expect(!reply.isHidden); reply.performClick(nil)
        #expect(replyID == request.id)
        try capture("clarification")
        let sheet = AIQuestionSheet(participant: "迅雷", parentNumber: 1, draft: "社内だけです", voice: "", range: "直近3発言 · 14:05:20〜14:05:50", tentative: true, canSubmit: true, confirmation: "参加対象は社内だけですか？")
        #expect(descendants(sheet.window.contentView!).compactMap { $0 as? NSButton }.contains { $0.title == "送信 ⏎" && $0.keyEquivalent == "\r" })
        try capture("sheet", view: sheet.window.contentView!.superview!)
    }
}
