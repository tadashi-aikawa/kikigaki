import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

extension AppKitTests {
@Suite @MainActor struct AIResolutionRowTests {
    @Test func 確認の三状態に文字倍率を掛け撮影する() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), meeting = UUID()
        var conversation = AIConversation(meetingID: meeting)
        var history = try AIStreamHistory(meetingID: meeting)
        for number in 1...4 {
            let snapshot = try history.prepare(lines: ["[13:19:40] タダシ: うん、その案で進めよう"], outputDirectory: root)
            let p = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
                participantName: "迅雷", cliPath: "/tmp/helper", sessionPath: root.appendingPathComponent(".kikigaki-context/\(meeting)/ai/sessions/1.json").path,
                requestToken: "token", question: "案を確認して", capturedAt: now, audioCutoffSeconds: 1,
                unansweredQuestions: conversation.unansweredQuestions)
            let request = try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: p), number: number)
            try conversation.append(request); try conversation.update(request.id) { try $0.beginSending(at: now) }
            if number < 4 {
                try conversation.receive(AIReceiveEvent(request: request, kind: .needsInput, recordedAt: now,
                    body: "この案で進めてよいですか？", reason: "clarification"), at: now)
            }
        }
        let target = conversation.questions[1].request.id
        try conversation.receive(AIResolutionEvent(request: conversation.questions[3].request, questionRequestID: target,
            evidence: AIAnswerEvidence(speaker: "タダシ", time: "13:19:40", quote: "うん、その案で進めよう"), recordedAt: now))
        try conversation.resolveManually(conversation.questions[2].request.id, at: now)
        let items = AITimeline.items(conversation: conversation, utterances: [], timeline: .init(startedAt: now))
            .filter { !$0.isSend && $0.kind == .reply(.needsInput) }
        #expect(items.count == 3)
        _ = NSApplication.shared
        for scale: CGFloat in [1, 2] {
            let canvas = NSView(frame: .zero)
            canvas.wantsLayer = true; canvas.layer?.backgroundColor = Washi.paper.cgColor
            var y: CGFloat = 8
            for (index, item) in items.enumerated() {
                let row = AIReplyRow(item: item, state: AIViewState(conversation: conversation))
                row.setTextScale(scale)
                row.frame = NSRect(x: 0, y: y, width: 900, height: row.height(for: 900))
                canvas.addSubview(row); row.layoutSubtreeIfNeeded(); y += row.frame.height + 12
                #expect(row.statusPill.title == ["要返答", "声で返答済み", "返答済み"][index])
                #expect(row.accent == (index == 0 ? Washi.red : nil))
                #expect(row.resolveAction.isHidden == (index != 0))
                if index == 0 {
                    var clicked = false; row.onResolve = { clicked = true }
                    row.resolveAction.performClick(nil); #expect(clicked)
                    #expect(row.resolveAction.frame.maxX < 900)
                }
                if index == 1 {
                    #expect(row.answerLabel.font?.pointSize == 12 * scale)
                    #expect(row.answerLabel.stringValue == "答え: タダシ 13:19:40「うん、その案で進めよう」")
                    #expect(row.answerLabel.frame.maxY <= row.frame.height)
                }
                row.update(item, state: AIViewState(conversation: conversation, readOnly: true))
                #expect(row.resolveAction.isHidden)
                row.update(item, state: AIViewState(conversation: conversation, canAsk: false))
                #expect(row.resolveAction.isHidden)
                row.update(item, state: AIViewState(conversation: conversation))
                row.frame = NSRect(x: 0, y: row.frame.minY, width: 420, height: row.height(for: 420))
                row.layoutSubtreeIfNeeded()
                if index == 0 {
                    #expect(row.resolveAction.frame.maxX <= 420)
                    #expect(row.resolveAction.frame.maxY <= row.frame.height)
                }
                row.frame = NSRect(x: 0, y: row.frame.minY, width: 900, height: row.height(for: 900))
                row.layoutSubtreeIfNeeded()
            }
            canvas.setFrameSize(NSSize(width: 900, height: y))
            if let output = ProcessInfo.processInfo.environment["KIKIGAKI_VOICE_RESOLVE_CAPTURE"] {
                let url = URL(fileURLWithPath: output).standardizedFileURL
                guard url.path.hasPrefix("/tmp/") || url.path.hasPrefix("/private/tmp/") else { throw AIError.unsafeFile }
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
                canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
                // AppKitの描画キャッシュはPNGで取り出す。撮影後にcwebpで非可逆WebPへ変換する。
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: url.appendingPathComponent("voice-resolve-\(Int(scale * 100)).png"))
            }
        }
    }
}
}
