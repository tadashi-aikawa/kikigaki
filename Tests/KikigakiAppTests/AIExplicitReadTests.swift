import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct AIExplicitReadTests {
    @Test func 本文の明示押下で既読になり選択と本文を保持する() throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var history = try AIStreamHistory(meetingID: UUID())
        let context = try history.prepare(lines: [], outputDirectory: root)
        let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: "議事録", cliPath: "/tmp/helper",
            sessionPath: root.appendingPathComponent(".kikigaki-context/\(history.meetingID)/ai/sessions/1.json").path,
            requestToken: "test", question: "確認", capturedAt: Date(), audioCutoffSeconds: 0)
        let request = try AIRequest(envelope: AIEnvelope(snapshot: context, participant: participant), number: 1, voiceQuestion: "", snapshot: context)
        var conversation = AIConversation(meetingID: history.meetingID)
        try conversation.append(request)
        try conversation.update(request.id) { try $0.beginSending(at: Date()); try $0.submitted() }
        try conversation.receive(AIReceiveEvent(request: request, kind: .answered, recordedAt: Date(), body: "担当と期限を確認しました。"), at: Date())
        var snapshot = SessionSnapshot(ai: AIViewState(conversation: conversation))
        let window = TranscriptWindowController(shouldReduceMotion: { true })
        window.apply(snapshot)
        let row = try #require(window.transcriptDocument.rows.compactMap { $0 as? AIReplyRow }.first)
        let body = try #require(row.subviews.compactMap { $0 as? MarkdownBodyView }.first)
        var callbacks = 0
        window.onReadAI = { id in
            callbacks += 1
            try! conversation.update(id) { $0.markRead() }
            snapshot.ai?.conversation = conversation; window.apply(snapshot)
        }
        body.setSelectedRange(NSRange(location: 0, length: 5))
        #expect(row.item.isUnread && callbacks == 0)
        #expect(body.accessibilityPerformPress())
        #expect(!conversation.questions[0].isUnread && callbacks == 1)
        #expect(row.statusPill.isHidden && body.selectedRange() == NSRange(location: 0, length: 5))
        #expect(body.string == "担当と期限を確認しました。")
        #expect(body.accessibilityPerformPress())
        #expect(callbacks == 1)
    }

    @Test func 末尾追従で可視になっても明示操作まで未読を保つ() async throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let started = Date(timeIntervalSince1970: 0)
        for scenario in ["manual-follow", "manual-scrolled", "scheduled"] {
            var history = try AIStreamHistory(meetingID: UUID())
            let context = try history.prepare(lines: ["[00:00:00] 話者: 検証"], outputDirectory: root)
            let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
                participantName: "議事録", cliPath: "/tmp/helper",
                sessionPath: root.appendingPathComponent(".kikigaki-context/\(history.meetingID)/ai/sessions/1.json").path,
                requestToken: "research", question: "確認", capturedAt: started.addingTimeInterval(400), audioCutoffSeconds: 400,
                trigger: scenario == "scheduled" ? .scheduled : nil)
            let request = try AIRequest(envelope: AIEnvelope(snapshot: context, participant: participant), number: 1, voiceQuestion: "", snapshot: context)
            var conversation = AIConversation(meetingID: history.meetingID)
            try conversation.append(request)
            try conversation.update(request.id) { try $0.beginSending(at: started.addingTimeInterval(400)); try $0.submitted() }
            var snapshot = SessionSnapshot(ai: AIViewState(conversation: conversation), state: .recording,
                utterances: (0..<40).map { .init(speaker: 0, start: Double($0 * 5), end: Double($0 * 5 + 2), text: "会議の発言 \($0)") },
                timeline: .init(startedAt: started), elapsed: 450, markdownURL: root.appendingPathComponent("meeting.md"))
            let window = TranscriptWindowController(shouldReduceMotion: { true })
            window.window!.setFrameAutosaveName(""); window.window!.setContentSize(NSSize(width: 600, height: 650))
            window.apply(snapshot); window.window!.contentView!.layoutSubtreeIfNeeded()
            window.transcriptDocument.reflow(anchor: .init(candidates: [], y: 0, atBottom: true))
            if scenario == "manual-scrolled" {
                window.transcriptDocument.followsBottom = false
                window.scrollView.contentView.scroll(to: .zero)
            }
            try conversation.receive(AIReceiveEvent(request: request, kind: .answered, recordedAt: started.addingTimeInterval(451),
                body: String(repeating: "長い回答です。\n\n", count: 30)), at: started.addingTimeInterval(452))
            snapshot.ai?.conversation = conversation
            window.apply(snapshot); window.window!.contentView!.layoutSubtreeIfNeeded()
            let row = try #require(window.transcriptDocument.rows.compactMap { $0 as? AIReplyRow }.first)
            let clip = window.scrollView.contentView.bounds
            let before = conversation.questions[0].isUnread
            var callbacks = 0
            window.onReadAI = { id in
                callbacks += 1
                try! conversation.update(id) { $0.markRead() }
                snapshot.ai?.conversation = conversation; window.apply(snapshot)
            }
            try await Task.sleep(for: .milliseconds(1300))
            #expect(callbacks == 0)
            #expect(clip.intersects(row.frame) == (scenario != "manual-scrolled"))
            #expect(!clip.contains(row.frame))
            #expect(before)
            #expect(callbacks == 0)
            #expect(conversation.questions[0].isUnread)
            window.compactFooter.unread.performClick(nil)
            #expect(conversation.questions[0].isUnread && callbacks == 0)
            row.statusPill.performClick(nil)
            #expect(!conversation.questions[0].isUnread && callbacks == 1)
        }
    }

}
