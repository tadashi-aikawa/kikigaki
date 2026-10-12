import AppKit
import Testing
import KikigakiCore
import WebKit
@testable import Kikigaki

extension AppKitTests {
@Suite(.serialized) @MainActor struct TranscriptTextScaleAppTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "KikigakiTextScaleTest.\(UUID())")! }
    private var percentages: [Int] {
        ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] == nil ? [100, 200] : TranscriptTextScale.percentages
    }

    @Test func 全行を再計測して末尾追従と読んでいる行を保つ() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let defaults = defaults()
        defer { defaults.removeObject(forKey: TranscriptWindowController.textScaleDefaultsKey) }
        let controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults, textDefaults: defaults)
        controller.window!.setFrameAutosaveName("")
        controller.window!.setContentSize(NSSize(width: 420, height: 578))
        var state = SessionSnapshot(state: .recording,
            utterances: (0..<400).map { .init(speaker: $0 % 2, start: Double($0 * 6), end: Double($0 * 6 + 5),
                text: "発言\($0) 次回までに資料を読み、検討した結果と担当者を共有してください。") },
            tentativeText: "聞き取り途中の発言", timeline: .init(startedAt: Date(timeIntervalSince1970: 0)),
            markdownURL: URL(fileURLWithPath: "/tmp/text-scale-fixture.md"))
        controller.apply(state)
        controller.typedEntry.attachmentsView.update(previews: [nil], removable: true)
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        let document = controller.transcriptDocument
        document.scroll(NSPoint(x: 0, y: document.frame.height))
        #expect(document.anchor().atBottom)
        let originalRows = document.rows
        let originalHeights = document.rows.map(\.frame.height)
        let originalContent = TranscriptRenderer.lines(state.utterances, names: state.names, timeline: state.timeline)
        controller.typedEntry.editor.string = "未投稿の下書き"
        controller.typedEntry.editor.setSelectedRange(NSRange(location: 2, length: 3))
        let inputSelection = controller.typedEntry.editor.selectedRange()
        let headerFonts = descendants(controller.window!.contentView!).compactMap { $0 as? NSTextField }
            .filter { $0.superview !== controller.typedEntry && !descendants(document).contains($0)
                && !descendants(controller.typedEntry.attachmentsView).contains($0) && $0 !== controller.typedEntry.attachmentError }
            .map { ($0, $0.font) }
        controller.setTextScale(.init(percent: 200))
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        #expect(document.rows.count == originalRows.count)
        #expect(zip(document.rows, originalRows).allSatisfy { $0 === $1 })
        #expect(zip(document.rows.map(\.frame.height), originalHeights).allSatisfy { $0 > $1 })
        #expect(abs(controller.scrollView.contentView.bounds.maxY - document.frame.height) < 1)
        #expect(document.rows.first?.superview == nil)
        #expect(document.rows.last?.superview === document)
        #expect(controller.typedEntry.editor.font?.pointSize == 14)
        #expect(controller.typedEntry.attachmentsView.contentHeight == 84)
        #expect(descendants(controller.typedEntry.attachmentsView).compactMap { $0 as? NSTextField }.first?.font?.pointSize == 11)
        #expect(controller.typedEntry.frame.height == 78)
        #expect(controller.typedEntry.editor.string == "未投稿の下書き")
        #expect(controller.typedEntry.editor.selectedRange() == inputSelection)
        #expect(headerFonts.allSatisfy { $0.0.font == $0.1 })
        let first = try #require(document.rows.first as? TranscriptRow)
        let body = try #require(descendants(first).compactMap { $0 as? NSTextField }.first { $0.stringValue == state.utterances[0].text })
        #expect((body.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 30)
        // 画面外の行も倍率を変更済みで、次のsnapshotで元のサイズへ戻らない。
        state.utterances[0].text += "追記"
        state.state = .idle; state.saved = true; state.tentativeText = nil
        controller.apply(state)
        #expect((body.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 30)
        let middle = document.rows[200]
        document.scroll(NSPoint(x: 0, y: middle.frame.minY + 11))
        let offset = middle.frame.minY - controller.scrollView.contentView.bounds.minY
        controller.resetTextSize(nil)
        #expect(abs(middle.frame.minY - controller.scrollView.contentView.bounds.minY - offset) < 1)
        #expect(document.rows[200] === middle)
        #expect(document.rows[1].frame.height == originalHeights[1])
        #expect(TranscriptRenderer.lines(Array(state.utterances.dropFirst()), names: state.names, timeline: state.timeline) == Array(originalContent.dropFirst()))
    }

    @Test func 保存復元とメニューの全キーと端の無効化() throws {
        _ = NSApplication.shared
        let defaults = defaults()
        defer { defaults.removeObject(forKey: TranscriptWindowController.textScaleDefaultsKey) }
        defaults.set(125, forKey: TranscriptWindowController.textScaleDefaultsKey)
        let controller = TranscriptWindowController(minutesDefaults: defaults, textDefaults: defaults)
        controller.window!.setFrameAutosaveName("")
        controller.window!.setFrameOrigin(NSPoint(x: 20000, y: 20000))
        controller.typedEntry.update(enabled: true, resetDraft: false)
        controller.window!.makeFirstResponder(controller.typedEntry.editor)
        #expect(controller.textScale.percent == 125)
        let menu = ApplicationMenu.make()
        let view = try #require(menu.items.first { $0.submenu?.title == "表示" }?.submenu)
        let zoom = view.items.filter { $0.action == #selector(TranscriptWindowController.increaseTextSize(_:)) }
        #expect(Set(zoom.map(\.keyEquivalent)) == ["+", "=", ";"])
        #expect(zoom.filter { !$0.isHidden }.count == 1)
        // CLIのテストではkeyWindowが無い。入力欄からの経路とキーの照合を分けて検証する。
        controller.resetTextSize(nil)
        #expect(controller.typedEntry.editor.tryToPerform(#selector(TranscriptWindowController.increaseTextSize(_:)), with: nil))
        #expect(controller.textScale.percent == 110)
        for item in view.items { item.target = controller }
        for (key, code, modifiers) in [(";", UInt16(41), NSEvent.ModifierFlags.command),
                                        ("=", 24, .command), ("+", 24, [.command, .shift]),
                                        ("-", 27, .command), ("0", 29, .command)] {
            // ⌘0は100%で無効なので、125%から戻す。
            controller.setTextScale(.init(percent: key == "0" ? 125 : 100))
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            #expect(menu.performKeyEquivalent(with: event))
            #expect(controller.textScale.percent == (key == "-" ? 90 : key == "0" ? 100 : 110))
        }
        for percent in TranscriptTextScale.percentages {
            controller.setTextScale(.init(percent: percent))
            for item in zoom { #expect(controller.validateMenuItem(item) == (percent < 200)) }
            let decrease = try #require(view.items.first { $0.keyEquivalent == "-" })
            let reset = try #require(view.items.first { $0.keyEquivalent == "0" })
            #expect(controller.validateMenuItem(decrease) == (percent > 80))
            #expect(controller.validateMenuItem(reset) == (percent != 100))
        }
        let restored = TranscriptWindowController(minutesDefaults: defaults, textDefaults: defaults)
        restored.window!.setFrameAutosaveName("")
        #expect(restored.textScale.percent == 200 && restored.typedEntry.editor.font?.pointSize == 14)
        #expect(restored.minutesSplit.preview.minutesDocument.textScale == 2)
        defaults.set(125.5, forKey: TranscriptWindowController.textScaleDefaultsKey)
        let invalid = TranscriptWindowController(minutesDefaults: defaults, textDefaults: defaults)
        invalid.window!.setFrameAutosaveName("")
        #expect(invalid.textScale == .actual)
    }

    @Test func Markdown全記法の倍率と選択と本文を保つ() throws {
        _ = NSApplication.shared
        let markdown = """
        # 大見出し
        ## 見出し
        本文 **太字** `コード` [リンク](https://example.com)
        - 箇条書き
        > 引用

        ```swift
        let x = 1
        ```

        | 名前 | 値 |
        | --- | --- |
        | 田中 | 長い内容も折り返します |

        !!! warning "注意"
            説明
        """
        let body = MarkdownBodyView()
        body.frame = NSRect(x: 0, y: 0, width: 300, height: 1000)
        body.update(markdown)
        body.frame = NSRect(x: 0, y: 0, width: 300, height: body.height(for: 300))
        let original = NSAttributedString(attributedString: body.attributedString())
        let originalHeight = body.height(for: 300)
        let selection = NSRange(location: 2, length: 3)
        body.setSelectedRange(selection)
        for percent in percentages {
            let scale = CGFloat(percent) / 100
            body.setTextScale(scale)
            #expect(body.string == original.string)
            #expect(body.selectedRange() == selection)
            original.enumerateAttribute(.font, in: NSRange(location: 0, length: original.length)) { value, range, _ in
                let before = value as? NSFont
                let after = body.textStorage?.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
                #expect(abs((after?.pointSize ?? 0) - (before?.pointSize ?? 0) * scale) < 0.001)
            }
            let height = body.height(for: 300)
            #expect(height > 0 && height < 10000)
            if percent == 200 { #expect(height > originalHeight) }
        }
        body.setTextScale(1)
        #expect(body.height(for: 300) == originalHeight)
        body.update("新しい本文")
        body.setTextScale(1.5)
        body.update("更新した本文")
        #expect((body.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 22.5)
    }

    @Test func AI全種類を各倍率で更新し狭い幅でも文字を収める() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = defaults()
        defer { defaults.removeObject(forKey: TranscriptWindowController.textScaleDefaultsKey) }
        let started = Date(timeIntervalSince1970: 0)
        var history = try AIStreamHistory(meetingID: UUID())
        var conversation = AIConversation(meetingID: history.meetingID)
        for number in 1...3 {
            let context = try history.prepare(lines: ["[00:00:00] 田中: 議題を確認します"], outputDirectory: root)
            let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
                participantName: "迅雷", cliPath: root.appendingPathComponent("helper").path,
                sessionPath: root.appendingPathComponent(".kikigaki-context/\(history.meetingID)/"
                    + AIEnvelope.sessionPath(slot: 1, generation: 1)).path, requestToken: "test",
                question: number == 2 ? "" : "抜けた観点を確認してください", capturedAt: started.addingTimeInterval(Double(number * 10)),
                audioCutoffSeconds: Double(number * 10), profile: "fixture", profileSlot: 1)
            let request = try AIRequest(envelope: AIEnvelope(snapshot: context, participant: participant), number: number,
                voiceQuestion: number == 2 ? "声からの送信" : "", snapshot: context)
            try conversation.append(request)
            try conversation.update(request.id) { try $0.beginSending(at: participant.capturedAt); try $0.submitted() }
            if number != 2 {
                try conversation.receive(AIReceiveEvent(request: request, kind: number == 1 ? .needsInput : .failed,
                    recordedAt: participant.capturedAt, body: "## 見出し\n確認する**本文**と`コード`です。\n\n| 名前 | 値 |\n| --- | --- |\n| 田中 | 期限未定 |",
                    reason: number == 3 ? "検証用の失敗" : "clarification"), at: participant.capturedAt)
            } else {
                try conversation.receive(AIReceiveEvent(request: request, kind: .accept,
                    recordedAt: participant.capturedAt), at: participant.capturedAt)
            }
            try history.acknowledge(snapshotID: context.id, streamID: history.streamID, sessionGeneration: 1)
        }
        var ai = AIViewState(conversation: conversation)
        ai.modelLabels = [1: .init(model: "gpt-6-astra", effort: "high", directory: "minutes")]
        var state = SessionSnapshot(ai: ai, state: .recording,
            utterances: [.init(speaker: 0, start: 0, end: 2, text: "議題を確認します"),
                         try .init(typedText: "手入力の本文 https://example.com", at: 3, postedAt: started,
                                   imagePaths: [root.appendingPathComponent("missing.webp").path])],
            timeline: .init(startedAt: started), markdownURL: root.appendingPathComponent("fixture.md"))
        let controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults, textDefaults: defaults)
        controller.window!.setFrameAutosaveName("")
        let content = controller.window!.contentView!
        controller.apply(state); content.layoutSubtreeIfNeeded()
        let rows = controller.transcriptDocument.rows
        #expect(rows.contains { $0 is AISendLineRow })
        #expect(rows.contains { $0 is AITypedSendRow })
        #expect(rows.contains { $0 is AIReplyRow })
        let typed = try #require(rows.compactMap { $0 as? TranscriptRow }.last)
        let typedBody = try #require(descendants(typed).compactMap { $0 as? TypedEntryBody }.first)
        typedBody.setSelectedRange(NSRange(location: 1, length: 2))
        let reply = try #require(rows.compactMap { $0 as? AIReplyRow }.first { !$0.isFailure && !$0.isWaiting })
        let waiting = try #require(rows.compactMap { $0 as? AIReplyRow }.first { $0.isWaiting })
        reply.quoteButton.performClick(nil)
        let quoteExpanded = reply.quoteButton.expanded
        let sources = rows.compactMap { $0 as? AITimelineRowView }.map { ($0, $0.item) }
        func font(_ field: NSTextField) -> NSFont? {
            field.attributedStringValue.length > 0 ? field.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : field.font
        }
        let fonts = rows.flatMap { descendants($0).compactMap { $0 as? NSTextField } }
            .filter { !$0.stringValue.isEmpty && $0.stringValue != "画像1" }.map { ($0, font($0)?.pointSize ?? 0) }
        let operatorFonts = descendants(content).compactMap { $0 as? NSControl }
            .filter { !descendants(controller.transcriptDocument).contains($0) }.map { ($0, $0.font) }
        for width in [420, 600] {
            controller.window!.setContentSize(NSSize(width: width, height: 900))
            // 撮影時はOSのスクロールバー自動切替による本文幅の差を除く。
            if ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] != nil {
                controller.scrollView.scrollerStyle = .overlay
            }
            content.layoutSubtreeIfNeeded()
            for percent in percentages {
                let scale = CGFloat(percent) / 100
                controller.setTextScale(.init(percent: percent))
                // 定期snapshotで属性が100%へ戻らないことも確かめる。
                controller.apply(state); content.layoutSubtreeIfNeeded()
                #expect(zip(rows, controller.transcriptDocument.rows).allSatisfy { $0 === $1 })
                #expect(fonts.allSatisfy { abs((font($0.0)?.pointSize ?? 0) - $0.1 * scale) < 0.001 })
                #expect(operatorFonts.allSatisfy { $0.0.font == $0.1 })
                #expect(controller.typedEntry.editor.font?.pointSize == 14)
                #expect(typedBody.selectedRange() == NSRange(location: 1, length: 2))
                #expect((typedBody.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 15 * scale)
                let imageLabel = try #require(descendants(typed).compactMap { $0 as? NSTextField }.first { $0.stringValue == "画像1" })
                #expect(imageLabel.font?.pointSize == 11 * scale)
                #expect(reply.quoteButton.expanded == quoteExpanded)
                #expect(waiting.progressView.textScale == scale)
                if scale != 1, waiting.quoteButton.attributedTitle.length > 0 {
                    #expect((waiting.quoteButton.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 12 * scale)
                }
                for row in rows {
                    #expect(row.frame.height == row.height(for: controller.scrollView.contentSize.width))
                    #expect(row.frame.height > 0 && row.frame.height < 10000)
                    for field in descendants(row).compactMap({ $0 as? NSTextField }) where !field.isHiddenOrHasHiddenAncestor {
                        let rect = row.convert(field.bounds, from: field)
                        #expect(rect.minY >= 0 && rect.maxY <= row.bounds.height + 1)
                    }
                }
                if let output = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] {
                    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                    controller.transcriptDocument.scroll(.zero)
                    content.layoutSubtreeIfNeeded()
                    let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                        URL(fileURLWithPath: output).appendingPathComponent("text-\(width)-\(percent).png"))
                }
            }
        }
        if ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] != nil {
            // 本体の撮影を終えてからWeb描画を開き、窓の表示状態を比較条件へ混ぜない。
            for width in [420, 600] {
                let fixture = root.appendingPathComponent("minutes.md")
                try "# 会議の議事録\n\n## 決定事項\n\n担当者と期限を確認します。\n\n## ボード\n\n### 議題\n\n- 田中: 次回まで".write(to: fixture, atomically: true, encoding: .utf8)
                controller.showMinutes()
                controller.window!.setContentSize(NSSize(width: width + 601, height: 900))
                controller.minutesSplit.setPosition(CGFloat(width), ofDividerAt: 0)
                controller.setTextScale(.init(percent: 200))
                let preview = controller.minutesSplit.preview
                preview.update(path: fixture.path, source: .human, active: true, boardHeading: "## ボード")
                for _ in 0..<500 {
                    if preview.minutesDocument.renderedText.contains("決定事項") && preview.boardDocument.renderedText.contains("田中") { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(preview.minutesDocument.renderedText.contains("決定事項"))
                preview.updateStatus.setDate(nil)
                controller.transcriptDocument.scroll(.zero)
                try await captureShared(content, name: "ai-minutes-\(width)-200", web: preview.minutesDocument)
                preview.stop(); controller.minutesSplit.setVisible(false)
            }
        }
        state.state = .idle; state.saved = true; state.ai?.readOnly = true
        controller.apply(state)
        controller.setTextScale(.init(percent: 125))
        #expect(controller.transcriptDocument.rows.compactMap { $0 as? AITimelineRowView }.allSatisfy { row in
            sources.contains { $0.0 === row && $0.1.body == row.item.body }
        })
    }

    private func captureShared(_ view: NSView, name: String, web: MinutesWebView? = nil) async throws {
        guard let directory = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] else { return }
        let output = URL(fileURLWithPath: directory).appendingPathComponent("review")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        view.window?.makeFirstResponder(nil)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        view.window?.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let result: NSBitmapImageRep
        if let web {
            let page = try await web.webView.takeSnapshot(configuration: nil)
            let converted = view.convert(web.bounds, from: web)
            let rect = view.isFlipped ? NSRect(x: converted.minX, y: view.bounds.height - converted.maxY,
                                               width: converted.width, height: converted.height) : converted
            let background = NSImage(size: view.bounds.size); background.addRepresentation(bitmap)
            let combined = NSImage(size: view.bounds.size, flipped: false) { _ in
                background.draw(in: view.bounds); page.draw(in: rect); return true
            }
            result = try #require(combined.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        } else { result = bitmap }
        try #require(result.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }

    @Test func 議事録のWeb描画だけが拡大し操作部分と閲読位置は変わらない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let configured = ProcessInfo.processInfo.environment["KIKIGAKI_UI_FIXTURE"]
        let directory = try configured.map { URL(fileURLWithPath: $0) } ?? testDirectory()
        defer { if configured == nil { try? FileManager.default.removeItem(at: directory) } }
        let fixture = directory.appendingPathComponent("scale-review.md")
        let source = "# 会議の議事録\n\n## 決定事項\n\n担当者と期限を確認します。\n\n| 担当 | 期限 |\n| --- | --- |\n| 田中 | 次回まで |\n\n"
            + (1...15).map { "## 議題\($0)\n\n資料をまとめて共有します。\n\n" }.joined()
            + "## ボード\n\n### 議題\n\n担当と期限\n\n- 田中: 次回まで"
        try source.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: fixture.path)
        let capture = ProcessInfo.processInfo.environment["KIKIGAKI_UI_CAPTURE"] != nil
        for width in capture ? [420, 600] : [420] {
            let defaults = defaults()
            defer { defaults.removeObject(forKey: TranscriptWindowController.textScaleDefaultsKey) }
            let controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults, textDefaults: defaults)
            let window = try #require(controller.window)
            window.setFrameAutosaveName("")
            window.setContentSize(NSSize(width: width, height: 850)); window.setFrameOrigin(NSPoint(x: 20, y: 60))
            var state = SessionSnapshot(state: .recording,
                utterances: [.init(speaker: 0, start: 0, end: 3, text: "議題を確認します。担当者と期限を議事録へ残しましょう。"),
                             .init(speaker: 1, start: 3, end: 6, text: "次回までに資料をまとめます。")],
                timeline: .init(startedAt: Date(timeIntervalSince1970: 0)), markdownURL: fixture)
            state.elapsed = 125; state.detectedSpeakerSlots = Array(0..<8)
            state.audioExclusion = AudioExclusion(enabled: true, thresholdDBFS: -45)
            controller.apply(state); window.orderFront(nil)
            defer { controller.minutesSplit.preview.stop(); window.orderOut(nil) }
            for percent in percentages {
                controller.setTextScale(.init(percent: percent))
                try await captureShared(window.contentView!, name: "main-\(width)-\(percent)")
            }
            controller.setTextScale(.actual)
            controller.minutesSplit.visibleScreen = { _ in NSRect(x: 0, y: 0, width: 1470, height: 956) }
            controller.showMinutes()
            window.setContentSize(NSSize(width: width + 601, height: 850)); window.setFrameOrigin(NSPoint(x: 20, y: 60))
            controller.minutesSplit.setPosition(CGFloat(width), ofDividerAt: 0)
            let preview = controller.minutesSplit.preview
            preview.update(path: fixture.path, source: .human, active: true, boardHeading: "## ボード")
            for _ in 0..<500 {
                if preview.minutesDocument.renderedText.contains("議題15") && preview.boardDocument.renderedText.contains("田中") { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(preview.minutesDocument.renderedText.contains("議題15"))
            #expect(preview.boardDocument.renderedText.contains("田中"))
            preview.updateStatus.setDate(nil)
            preview.showSearch(); preview.searchField.stringValue = "資料"; preview.search(reveal: false)
            preview.closeSearch()
            window.contentView!.layoutSubtreeIfNeeded()
            let controls = descendants(preview).compactMap { $0 as? NSControl }.map { ($0, $0.font, $0.frame) }
            let preference = controller.minutesSplit.preference
            let web = preview.minutesDocument.webView
            for percent in percentages {
                _ = try await web.evaluateJavaScript("window.minutes.search('資料', 0, false); window.scrollTo(0, 400)")
                controller.setTextScale(.init(percent: percent))
                window.contentView!.layoutSubtreeIfNeeded()
                #expect(preview.minutesDocument.webView.pageZoom == CGFloat(percent) / 100)
                #expect(preview.boardDocument.webView.pageZoom == CGFloat(percent) / 100)
                #expect(controls.allSatisfy { $0.0.font == $0.1 && $0.0.frame == $0.2 })
                #expect(controller.minutesSplit.preference == preference)
                #expect(try await web.evaluateJavaScript("CSS.highlights.get('matches').size") as? Int == 15)
                #expect(abs((try await web.evaluateJavaScript("window.scrollY") as? Double ?? 0) - 400) <= 46)
                _ = try await web.evaluateJavaScript("window.minutes.search('', 0, false); window.scrollTo(0, 0)")
                if percent > 100 {
                    #expect(try await web.evaluateJavaScript("document.querySelector('#minutes h1').getBoundingClientRect().top >= document.querySelector('#toc summary').getBoundingClientRect().bottom") as? Bool == true)
                }
                try await captureShared(window.contentView!, name: "minutes-\(width)-\(percent)", web: preview.minutesDocument)
                preview.selectBoard(true)
                try await captureShared(window.contentView!, name: "board-\(width)-\(percent)", web: preview.boardDocument)
                preview.selectBoard(false)
            }
        }
    }
}
}
