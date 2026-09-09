import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite @MainActor struct MarkdownBodyViewTests {
    // 会議を受けた返事の例。描画する全要素を、実際に読む順序で混ぜる。
    private let minutes = """
    # 体験会の準備会議

    社内10名を対象に、**9月18日の午後に試行**する方針で合意しました。

    ## 決定事項

    - 初参加の人が迷わないよう、説明10分・体験20分・質問5分の順で進めます。
      - [x] 参加対象は社内に限定
      - [ ] 受付担当と予備の端末を確保

    1. 佐藤さんが案内文を作成し、参加者へ送る。
    2. 鈴木さんが会場と当日の接続環境を確認する。

    > 「質問の時間も五分あると安心ですね」— 鈴木さん

    ### 試行時の設定

    配信前に `trial.toml` の内容を確認してください。

    ```toml
    [trial]
    participants = 10
    note = "初参加の方への説明、体験、質問の順で進め、機材トラブル時は予備の端末へ切り替える"
    ```

    #### 次回までの担当

    | 担当 | 次回までに行うこと | 期限 |
    | --- | --- | --- |
    | 佐藤 | 案内文を作成し、参加方法と持ち物を明記する | 9/10 |
    | 鈴木 | 会場予約と接続テスト | 9/11 |

    ---

    *開催時刻は未確定*です。~~社外への同時案内~~は見送り、[準備チェックリスト](https://example.com/trial/checklist)に確認事項をまとめます。
    """

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @Test func 返事全体を選択でき幅の往復と既読更新で選択と高さを保つ() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date(timeIntervalSince1970: 1_788_795_600)
        let meeting = UUID()
        var history = try AIStreamHistory(meetingID: meeting)
        let context = try history.prepare(lines: ["[14:00:00] 佐藤: 決定事項と次回までの担当をまとめてください。"], outputDirectory: root)
        let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: "迅雷", cliPath: root.appendingPathComponent("helper").path,
            sessionPath: root.appendingPathComponent(".kikigaki-context/\(meeting)/ai/sessions/1.json").path,
            requestToken: "test", question: "決定事項と次回までの担当をまとめてください。",
            capturedAt: started.addingTimeInterval(60), audioCutoffSeconds: 60)
        let request = try AIRequest(envelope: AIEnvelope(snapshot: context, participant: participant), number: 1, snapshot: context)
        var conversation = AIConversation(meetingID: meeting)
        try conversation.append(request)
        try conversation.update(request.id) { try $0.beginSending(at: started.addingTimeInterval(60)); try $0.submitted() }
        _ = try conversation.receive(AIReceiveEvent(request: request, kind: .answered,
            recordedAt: started.addingTimeInterval(70), body: minutes), at: started.addingTimeInterval(70))
        var state = SessionSnapshot(ai: AIViewState(conversation: conversation, connection: .idle), state: .paused,
            utterances: [.init(speaker: 0, start: 58, end: 60, text: "決定事項と次回までの担当をまとめてください。")],
            timeline: MeetingTimeline(startedAt: started), names: SpeakerNames([0: "佐藤"]), elapsed: 90,
            markdownURL: root.appendingPathComponent("meeting.md"))
        let controller = TranscriptWindowController(shouldReduceMotion: { true })
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        window.setFrameOrigin(NSPoint(x: 20000, y: 20000))
        window.setContentSize(NSSize(width: 600, height: 1100))
        let content = try #require(window.contentView)
        controller.apply(state); content.layoutSubtreeIfNeeded()
        let row = try #require(controller.transcriptDocument.rows.compactMap { $0 as? AIReplyRow }.first)
        controller.onReadAI = { id in
            try! conversation.update(id) { $0.markRead() }
            state.ai?.conversation = conversation
            controller.apply(state)
        }
        // 展開は既定なので開く操作はない。未読の印を押して既読にする。
        row.onRead?(); content.layoutSubtreeIfNeeded()
        let body = try #require(descendants(row).compactMap { $0 as? MarkdownBodyView }.first)
        #expect(descendants(row).compactMap { $0 as? NSTextView }.count == 1)
        #expect(!body.isEditable && body.isSelectable)
        #expect(body.layoutManager != nil && body.textLayoutManager == nil)
        #expect(row.accent == nil)
        let selection = (body.string as NSString).range(of: "初参加")
        body.setSelectedRange(selection)
        let storage = try #require(body.textStorage)
        let firstBlock = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as AnyObject?
        var heights: [Int: CGFloat] = [:]
        for width in [600, 900, 600] {
            window.setContentSize(NSSize(width: width, height: 1100))
            content.layoutSubtreeIfNeeded()
            controller.transcriptDocument.reflow(anchor: .init(candidates: [], y: 0, atBottom: false))
            content.layoutSubtreeIfNeeded()
            let chrome = content.bounds.height - controller.scrollView.contentSize.height
            let rowsHeight = controller.transcriptDocument.rows.reduce(CGFloat(16)) { $0 + $1.frame.height }
            window.setContentSize(NSSize(width: CGFloat(width), height: ceil(rowsHeight + chrome)))
            content.layoutSubtreeIfNeeded()
            controller.transcriptDocument.reflow(anchor: .init(candidates: [], y: 0, atBottom: false))
            content.layoutSubtreeIfNeeded()
            #expect(abs(content.bounds.width - CGFloat(width)) < 1)
            #expect(body.selectedRange() == selection)
            #expect(body.textStorage === storage)
            #expect(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as AnyObject? === firstBlock)
            if let previous = heights[width] { #expect(abs(previous - row.frame.height) < 1) }
            heights[width] = row.frame.height
            try assertFits(body)
            #expect(body.frame.maxY <= row.bounds.height)
            #expect(body.frame.width == max(44, row.bounds.width - 90))
            body.setSelectedRange(NSRange(location: 0, length: 0))
            try capture("minutes-\(width)", view: content.superview!)
            body.setSelectedRange(selection)
            print("Markdown \(width): row=\(row.frame.height), body=\(body.frame), content=\(content.bounds.size)")
        }
        #expect(try #require(heights[600]) > #require(heights[900]))
        state.names = SpeakerNames([0: "佐藤 太郎"])
        state.utterances.append(.init(speaker: 0, start: 92, end: 94, text: "担当はこの内容で進めましょう。"))
        controller.apply(state); content.layoutSubtreeIfNeeded()
        // 改名と発話追加だけの更新では、本文の選択もtextStorageも作り直さない。
        #expect(body.selectedRange() == selection && row.accent == nil && !body.isHidden)
        #expect(body.textStorage === storage)

        // NSTextViewの標準の選択書き出しを使う。利用者のクリップボードには触れない。
        let clipboard = NSPasteboard(name: .init("KIKIGAKI-markdown-" + UUID().uuidString))
        defer { clipboard.releaseGlobally() }
        body.selectAll(nil)
        #expect(body.selectedRange().length == storage.length)
        #expect(body.writeSelection(to: clipboard, types: body.writablePasteboardTypes))
        #expect(clipboard.string(forType: .string) == body.string)
        let copied = try #require(clipboard.string(forType: .string))
        for expected in ["体験会の準備会議", "participants = 10", "接続テスト", "開催時刻は未確定", "準備チェックリスト"] {
            #expect(copied.contains(expected))
        }
        #expect(!copied.contains("**") && !copied.contains("```"))
        let link = (body.string as NSString).range(of: "準備チェックリスト")
        #expect((storage.attribute(.link, at: link.location, effectiveRange: nil) as? URL)?.absoluteString
            == "https://example.com/trial/checklist")
    }

    @Test func 空本文と末尾の表やコードも高さを測り直せる() throws {
        _ = NSApplication.shared
        let body = MarkdownBodyView()
        for source in ["", "本文\n", "```\n```", "|担当|対応|\n|-|-|\n|佐藤|長い説明をここに書きます|", "```\n" + String(repeating: "x", count: 240) + "\n```"] {
            body.update(source)
            for width in [CGFloat(510), 810, 510] {
                let height = body.height(for: width)
                #expect(height.isFinite && height >= 0)
                body.frame = NSRect(x: 0, y: 0, width: width, height: height)
                try assertFits(body)
            }
        }
    }

    private func assertFits(_ body: MarkdownBodyView) throws {
        let manager = try #require(body.layoutManager), container = try #require(body.textContainer)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(for: container)
        #expect(glyphs.length == manager.numberOfGlyphs)
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            #expect(used.maxX <= container.size.width + 1)
            #expect(used.maxY + body.textContainerInset.height <= body.bounds.height + 1)
        }
    }

    private func capture(_ name: String, view: NSView) throws {
        guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] else { return }
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
    }
}
