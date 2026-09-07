import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite(.timeLimit(.minutes(1))) @MainActor struct TypedEntryTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func config(_ root: URL) throws -> ResolvedConfig {
        var value = ResolvedConfig(config: try ConfigLoader.parse(toml: ""), home: root)
        value.ai = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path), home: root)
        return value
    }
    private final class NoAudio: AudioSource {
        func start(onSamples: @escaping ([Float]) -> Void) throws { Issue.record("音源は起動しない") }
        func stop() {}
    }
    private func enter(_ editor: TypedEntryEditor, modifiers: NSEvent.ModifierFlags = .command) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: editor.window?.windowNumber ?? 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.keyDown(with: event)
    }

    @Test func 投稿は独立保持され音声更新と一時停止と停止保存をまたぐ() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AIRecordStore(directory: root)
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"),
            config: try config(root), aiStore: store, recordedSamples: 32_000)
        #expect(!session.submitTyped(" \n "))
        #expect(session.submitTyped(" https://example.com/meeting\n補足 "))
        let first = try #require(session.snapshot.utterances.first)
        #expect(first.start == 2 && first.end == 2 && first.text == "https://example.com/meeting 補足")
        #expect(session.snapshot.elapsed == 0 && session.snapshot.contextEnd == 2)
        session.publishForTesting(tokens: [.init(text: "URL送ります", phraseId: 0, start: 0, end: 1)], speakers: [0], elapsed: 1)
        #expect(session.snapshot.utterances == [.init(speaker: 0, start: 0, end: 1, text: "URL送ります"), first])
        #expect(session.snapshot.pendingSpeakerRows == [0])
        session.togglePause()
        #expect(session.submitTyped("一時停止中"))
        let paused = try #require(session.snapshot.utterances.last)
        #expect(paused.start == first.start && paused.postedAt! >= first.postedAt!)
        session.togglePause()
        #expect(session.snapshot.utterances.filter { $0.kind == .typed } == [first, paused])
        session.rename(slot: 0, to: "田中")
        session.publishForTesting(tokens: [.init(text: "前の声", phraseId: 0, start: 0, end: 0.5),
                                          .init(text: "別の声", phraseId: 1, start: 1, end: 1.5)], speakers: [0, 1], elapsed: 2)
        session.setSpeakerMapping(source: 0, target: 1)
        #expect(session.snapshot.speakerMapping[0] == 1)
        #expect(session.snapshot.utterances.filter { $0.kind == .typed } == [first, paused])
        var rejectedWhileFinishing = false
        session.onChange = { if $0.state == .finishing { rejectedWhileFinishing = !session.submitTyped("保存中は拒否") } }
        await session.stop()
        #expect(rejectedWhileFinishing && !session.submitTyped("停止後も拒否"))
        #expect(session.snapshot.utterances == [first, paused])
        session.rename(slot: 0, to: "佐藤")
        let saved = try String(contentsOf: root.appendingPathComponent("meeting.md"), encoding: .utf8)
        #expect(saved.contains("手入力: " + first.text) && saved.contains("手入力: 一時停止中"))
        #expect(await !session.start(source: NoAudio()))
        #expect(session.snapshot.utterances.isEmpty && !session.submitTyped("待機中"))
    }

    @Test func AI送信は一時停止の同じ位置でも受付後の投稿を混ぜない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"),
            config: try config(root), aiStore: store)
        session.togglePause()
        #expect(session.submitTyped("送信前のURL"))
        session.submitAI(question: "このURLを見て", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"))
        let task = try #require(session.submissionTaskForTesting)
        #expect(session.submitTyped("送信後のURL"))
        await task.value
        let first = try #require(session.aiRecord?.controller.conversation.questions.first)
        #expect(first.state == .submitted)
        let file = URL(fileURLWithPath: first.request.envelope.transcriptPath)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("手入力: 送信前のURL") && !text.contains("送信後のURL"))
        await session.stop()
    }

    @Test func 入力欄はIME確定と投稿を分け下書きを成功時だけ消す() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = TranscriptWindowController(shouldReduceMotion: { true })
        controller.window!.setFrameAutosaveName("")
        var state = SessionSnapshot(state: .recording)
        controller.apply(state)
        let editor = controller.typedEntry.editor
        controller.window?.makeFirstResponder(editor)
        var posted: [String] = []
        var accept = true
        controller.onSubmitTyped = { text in posted.append(text); return accept }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("https://example.com/a\r\n補足\u{2028}続き", forType: .string)
        #expect(editor.readSelection(from: pasteboard, type: .string))
        #expect(editor.string == "https://example.com/a 補足 続き")
        try enter(editor, modifiers: [])
        try enter(editor, modifiers: .shift)
        editor.insertNewline(nil)
        editor.insertLineBreak(nil)
        #expect(posted.isEmpty && editor.string == "https://example.com/a 補足 続き")
        #expect(editor.placeholder.contains("⌘Enterで投稿") && editor.toolTip == "⌘Enterで投稿")
        try enter(editor)
        #expect(posted.count == 1 && editor.string.isEmpty)
        editor.setMarkedText("へんかん", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        try enter(editor, modifiers: [])
        #expect(posted.count == 1)
        editor.setMarkedText("へんかん", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try enter(editor)
        #expect(posted.count == 1)
        editor.unmarkText()
        try enter(editor)
        #expect(posted.count == 2 && editor.string.isEmpty)
        editor.string = "未投稿"
        accept = false
        try enter(editor)
        #expect(editor.string == "未投稿")
        editor.cancelOperation(nil)
        #expect(editor.string == "未投稿" && controller.window?.firstResponder !== editor)
        state.state = .idle; controller.apply(state)
        #expect(!editor.isEditable && !editor.isSelectable && editor.string == "未投稿")
        #expect(editor.placeholder == "録音中に書き込めます")
        #expect(editor.backgroundColor == Washi.paper)
        #expect(descendants(controller.typedEntry).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "未投稿" && !$0.isHidden })
        let count = posted.count; try enter(editor)
        #expect(posted.count == count)
        state.state = .preparing; controller.apply(state)
        #expect(editor.string.isEmpty)
    }

    @Test func 過去の行を検索中でも投稿成功時は末尾を見せる() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = TranscriptWindowController(shouldReduceMotion: { true })
        controller.window!.setFrameAutosaveName("")
        controller.window!.setContentSize(NSSize(width: 600, height: 460))
        var state = SessionSnapshot(state: .paused, utterances: (0..<40).map {
            Utterance(speaker: 0, start: Double($0), end: Double($0 + 1), text: "過去の発言 \($0)")
        })
        controller.apply(state)
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        controller.showSearch(nil)
        controller.searchField.stringValue = "過去"
        controller.refreshSearch(reset: true, reveal: true)
        let document = try #require(descendants(controller.window!.contentView!).compactMap { $0 as? TranscriptDocument }.first)
        document.scroll(.zero)
        #expect(!document.anchor().atBottom && !document.followsBottom)
        controller.onSubmitTyped = { text in
            state.utterances.append(try! Utterance(typedText: text, at: 40, postedAt: Date()))
            controller.apply(state)
            return true
        }
        controller.typedEntry.editor.string = "https://example.com/"
        try enter(controller.typedEntry.editor)
        #expect(document.anchor().atBottom)
        #expect(controller.typedEntry.editor.string.isEmpty)
    }

    @Test func 手入力の四状態を実ビューと保存結果で確認する() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let temporary = try testDirectory(); defer { try? FileManager.default.removeItem(at: temporary) }
        let output = ProcessInfo.processInfo.environment["KIKIGAKI_TYPED_CAPTURE"].map { URL(fileURLWithPath: $0) }
        let url = temporary.appendingPathComponent("meeting.md")
        let startedAt = Date(timeIntervalSince1970: 1_788_804_000)
        var voices = [Utterance(speaker: 0, start: 12, end: 17, text: "体験会の案内、こちらの資料を使いましょう。"),
                      Utterance(speaker: 1, start: 65, end: 68, text: "共有用のURLを送ります。")]
        var entries: [Utterance] = []
        var state = SessionSnapshot(ai: AIViewState(), state: .recording, timeline: .init(startedAt: startedAt),
            names: SpeakerNames([0: "佐藤", 1: "鈴木"]), elapsed: 70, markdownURL: url, detectedSpeakerSlots: [0, 1])
        let controller = TranscriptWindowController(shouldReduceMotion: { true })
        controller.window!.setFrameAutosaveName("")
        controller.window!.setContentSize(NSSize(width: 600, height: 640))
        func refresh() {
            state.utterances = TranscriptEntries.merge(voice: voices, typed: entries, timeline: state.timeline).utterances
            state.handoffPreview = HandoffHistory().preview(utterances: state.utterances, names: state.names, timeline: state.timeline)
            controller.apply(state)
        }
        func capture(_ name: String) throws {
            let content = controller.window!.contentView!
            content.layoutSubtreeIfNeeded()
            #expect(abs(content.bounds.width - 600) < 1)
            #expect(controller.typedEntry.bounds.height == 34)
            #expect(controller.typedEntry.editor.frame.width >= controller.typedEntry.contentSize.width)
            guard let output else { return }
            let view = content.superview!
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }
        controller.onSubmitTyped = { text in
            guard state.canSubmitTyped, let entry = try? Utterance(typedText: text, at: state.elapsed,
                postedAt: startedAt.addingTimeInterval(state.state == .paused ? 240 : state.elapsed)) else { return false }
            entries.append(entry); refresh(); return true
        }
        refresh()
        controller.typedEntry.editor.string = "https://example.com/workshop"
        try enter(controller.typedEntry.editor)
        #expect(entries.count == 1 && controller.typedEntry.editor.string.isEmpty)
        try capture("posted")
        voices.append(.init(speaker: 0, start: 95, end: 99, text: "開けました。参加者にはこのページを案内します。"))
        state.elapsed = 105; refresh()
        #expect(state.utterances[2].kind == .typed && state.utterances[3].kind == .voice)
        try capture("between-voices")
        state.state = .paused; refresh()
        controller.typedEntry.editor.string = "会場案内: https://example.com/access"
        try enter(controller.typedEntry.editor)
        #expect(entries.count == 2 && entries[1].start == 105)
        try capture("paused-post")
        #expect(state.contextEndClock == TranscriptRenderer.clock(for: entries[1], timeline: state.timeline))
        state.timeline = .init(startedAt: startedAt, pauses: [.init(audioTime: 105, duration: 180)])
        voices.append(.init(speaker: 1, start: 110, end: 115, text: "再開します。会場案内も確認できました。"))
        state.elapsed = 120
        controller.typedEntry.editor.string = "案内文も後で確認する"
        state.state = .idle; refresh()
        let meeting = MeetingMarkdown.Meeting(startedAt: startedAt, duration: 120, utterances: state.utterances,
            names: state.names, pauses: state.timeline.pauses)
        var archive = MeetingArchive(original: meeting, processed: state.utterances, candidateCount: 0, markdownURL: url)
        let result = archive.save()
        #expect(result.message.hasPrefix("保存:"))
        state.utterances = result.utterances; state.saved = result.succeeded; state.message = result.message
        controller.apply(state)
        #expect(state.saved && !controller.typedEntry.editor.isEditable)
        #expect(state.utterances.filter { $0.kind == .typed } == entries)
        try capture("saved")
        for file in [url, MeetingFiles.rawURL(for: url)] {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.contains("手入力: https://example.com/workshop") && text.contains("手入力: 会場案内:"))
            if let output { try text.write(to: output.appendingPathComponent(file.lastPathComponent), atomically: true, encoding: .utf8) }
        }
        // 狭い高さ・長いURLでも入力欄は一行を保ち、会話本文の幅を押し広げない。
        state.state = .recording; controller.apply(state)
        controller.typedEntry.editor.string = ""
        controller.window!.setContentSize(NSSize(width: 600, height: 460))
        let editor = controller.typedEntry.editor
        editor.insertText("https://example.com/" + String(repeating: "long-path/", count: 80), replacementRange: NSRange(location: 0, length: 0))
        editor.scrollRangeToVisible(NSRange(location: editor.string.utf16.count, length: 0))
        try capture("long-url")
        #expect(!editor.string.contains("\n"))
    }

    @Test func 手入力の名前とURLを検索してもリンクと行の由来を保つ() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = TranscriptWindowController(shouldReduceMotion: { true })
        controller.window!.setFrameAutosaveName("")
        let entry = try Utterance(typedText: "https://example.com/meeting mailto:a@example.com file:///tmp/a", at: 10, postedAt: Date(timeIntervalSince1970: 120))
        var state = SessionSnapshot(state: .recording, utterances: [entry], timeline: .init(startedAt: Date(timeIntervalSince1970: 0)))
        controller.apply(state)
        let key = TranscriptWindowController.RowID(kind: .typed, start: 10, occurrence: 0)
        let row = try #require(controller.rows[key])
        let body = try #require(descendants(row).compactMap { $0 as? TypedEntryBody }.first { $0.string == entry.text })
        let avatar = try #require(descendants(row).compactMap { $0 as? AvatarView }.first)
        #expect(avatar.typed && avatar.slot == nil)
        #expect(descendants(row).compactMap { $0 as? SpeakerButton }.allSatisfy { $0.isHidden })
        controller.showSearch(nil)
        controller.searchField.stringValue = "手入力"; controller.refreshSearch(reset: true, reveal: false)
        #expect(controller.searchHits.count == 1 && controller.searchHits[0].inName)
        controller.searchField.stringValue = "example"; controller.refreshSearch(reset: true, reveal: false)
        #expect(controller.searchHits.count == 2)
        var links: [URL] = []
        body.attributedString().enumerateAttribute(.link, in: NSRange(location: 0, length: body.attributedString().length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        #expect(links == [URL(string: "https://example.com/meeting")!])
        #expect(body.linkTextAttributes?[.foregroundColor] as? NSColor == Washi.red)
        state.utterances.insert(.init(speaker: 0, start: 10, end: 11, text: "遅れて確定した声"), at: 0)
        controller.apply(state)
        #expect(controller.rows[key] === row)
        #expect(controller.searchHits.allSatisfy { $0.row == key })
    }

    @Test func AIシートの声の候補へ手入力を混ぜない() throws {
        let entry = try Utterance(typedText: "https://example.com/", at: 2, postedAt: Date())
        var value = SessionSnapshot(utterances: [.init(speaker: 0, start: 0, end: 1, text: "声の問い"), entry])
        #expect(value.voiceQuestionPlaceholder == "声の問い")
        value.tentativeText = "聞き取り中"
        #expect(value.voiceQuestionPlaceholder == "聞き取り中")
        value.tentativeText = nil; value.utterances = [entry]
        #expect(value.voiceQuestionPlaceholder == "空欄なら声の末尾を送ります")
    }
}
