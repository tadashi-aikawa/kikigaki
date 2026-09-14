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

    !!! warning "当日の注意"

        受付は**開始10分前**から始めます。予備の端末は2台用意します。

        - 入館証は当日受付で配布

    > [!tip] 進行のこつ
    > 質問は最後にまとめて受け、時間が余れば体験の延長にあてます。

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

    会場は本社3階の会議室A<br>受付は開始10分前からです。
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
        for expected in ["体験会の準備会議", "participants = 10", "接続テスト", "開催時刻は未確定", "準備チェックリスト",
                         "当日の注意", "入館証は当日受付で配布", "進行のこつ"] {
            #expect(copied.contains(expected))
        }
        // admonitionとcalloutは枠で描き、記法の文字は残さない。
        #expect(!copied.contains("!!!") && !copied.contains("[!tip]"))
        for title in ["当日の注意", "進行のこつ"] {
            let range = (body.string as NSString).range(of: title)
            let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            #expect(style?.textBlocks.isEmpty == false)
        }
        let nested = (body.string as NSString).range(of: "入館証は当日受付で配布")
        #expect((storage.attribute(.paragraphStyle, at: nested.location, effectiveRange: nil) as? NSParagraphStyle)?
            .textBlocks.count == 1)
        #expect(!copied.contains("**") && !copied.contains("```"))
        // `<br>` は段落を割らずに行を折り、コピーでは通常の改行になる。
        #expect(copied.contains("会議室A\n受付は開始10分前からです。") && !copied.lowercased().contains("<br"))
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

    @Test func 表は列の自然幅に収まり本文幅を超えるときだけ詰めて折り返す() throws {
        _ = NSApplication.shared
        // 短い表: 3列とも数文字。本文幅が広くても伸びてほしくない。
        let narrow = MarkdownBodyView()
        narrow.update("|担当|期限|\n| --- | --- |\n|佐藤|9/10|\n|鈴木|9/11|")
        // 広い表: 自然幅の合計が本文幅を超える。本文幅に収め、セル内で折り返す。
        let long = String(repeating: "案内文を作成し、参加方法と持ち物を明記する。", count: 3)
        let wide = MarkdownBodyView()
        wide.update("|担当|次回までに行うこと|準備物|連絡先|\n| --- | --- | --- | --- |\n|佐藤|"
                    + long + "|" + long + "|" + long + "|")
        var narrowRights: [CGFloat] = [], heights: [CGFloat: [CGFloat]] = [:]
        for width in [CGFloat(510), 810, 510] {
            var measured: [CGFloat] = []
            for body in [narrow, wide] {
                // 行と同じ順序で、表示する幅の枠を与えてから測る。
                body.setFrameSize(NSSize(width: width, height: body.frame.height))
                let height = body.height(for: width)
                body.frame = NSRect(x: 0, y: 0, width: width, height: height)
                try assertFits(body)
                measured.append(height)
            }
            let inner = width - narrow.textContainerInset.width * 2
            let narrowRight = try tableRight(narrow), wideRight = try tableRight(wide)
            // 短い表は本文幅の半分にも満たず、左に寄ったまま幅に追従しない。
            #expect(narrowRight < inner / 2)
            narrowRights.append(narrowRight)
            // 「担当」「期限」の列は自然幅どまり。どの列も60ptを超えて広がらない。
            #expect(try fragments(narrow).map(\.width).max() ?? 0 < 60)
            print("TABLE \(Int(width)) narrow=\(Int(narrowRight)) wide=\(Int(wideRight)) columns=\(try fragments(narrow).map { Int($0.width) })")
            // 広い表は本文幅いっぱいまで使い、はみ出さない。
            #expect(wideRight > inner * 0.9 && wideRight <= inner + 1)
            // 詰めるのは長い列だけ。「担当」はほぼ自然幅を保ち、1文字ずつ折り返さない。
            // 比例配分なら本文幅の1/4以下まで潰れるところを、24pt台で残す。
            #expect(try fragments(wide).map(\.width).min() ?? 0 >= 24)
            if let previous = heights[width] { #expect(previous == measured) }
            heights[width] = measured
            try capture("table-\(Int(width))", view: canvas(narrow, wide, width: width))
        }
        // 幅の往復で短い表の幅は変わらない。
        #expect(Set(narrowRights.map { Int($0) }).count == 1)
        #expect(try #require(heights[510]).last! > #require(heights[810]).last!)
        // 短い表は折り返さないので、本文幅が変わっても高さが変わらない。
        #expect(try #require(heights[510]).first! == #require(heights[810]).first!)
    }

    @Test func 列幅の配分は収まる表を変えず超える表だけ広い列から詰める() {
        // 収まるなら自然幅のまま。
        #expect(MarkdownBodyView.fit([24, 120, 40], into: 300) == [24, 120, 40])
        // 超えるときは広い列から均す。狭い列は自然幅のまま残る。
        #expect(MarkdownBodyView.fit([24, 300, 40], into: 200) == [24, 136, 40])
        // どの列も均した幅を超えるなら等分になる。
        #expect(MarkdownBodyView.fit([300, 300], into: 200) == [100, 100])
        // 下限24ptを割る予算では下限で置き、残りはTextKitが器の幅まで詰める。
        #expect(MarkdownBodyView.fit([300, 300], into: 20) == [24, 24])
    }

    /// 表の右端。行断片の枠は列の幅そのものなので、最大値が表の右端になる。
    private func tableRight(_ body: MarkdownBodyView) throws -> CGFloat {
        try fragments(body).map(\.maxX).max() ?? 0
    }

    private func fragments(_ body: MarkdownBodyView) throws -> [NSRect] {
        let manager = try #require(body.layoutManager), container = try #require(body.textContainer)
        manager.ensureLayout(for: container)
        var rects: [NSRect] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { rect, _, _, _, _ in
            rects.append(rect)
        }
        return rects
    }

    private func canvas(_ views: MarkdownBodyView..., width: CGFloat) -> NSView {
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: width, height: views.reduce(16) { $0 + $1.frame.height + 16 }))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = Washi.paper.cgColor
        var y: CGFloat = 16
        for view in views.reversed() {
            view.setFrameOrigin(NSPoint(x: 0, y: y))
            canvas.addSubview(view)
            y += view.frame.height + 16
        }
        return canvas
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
