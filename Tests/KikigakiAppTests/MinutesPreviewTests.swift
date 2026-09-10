import AppKit
import Darwin
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import Kikigaki

@Suite(.serialized) @MainActor struct MinutesPreviewTests {
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
    private let markdown = """
    ---
    title: 体験会の準備会議
    tags: [meeting]
    ---
    # 体験会の準備会議

    9月18日の午後、社内10名を対象に試行する方針で合意しました。

    ## 決定事項

    - **説明10分・体験20分・質問5分**の順で進めます。
    - 初参加の方にも案内が届くよう、[[準備チェックリスト\\|当日の手順]]を整理します。
    - [x] 参加対象は社内に限定
    - [ ] 受付担当と予備の端末を確保

    ## 次回までの担当

    | 担当 | 次回までに行うこと | 期限 |
    | --- | --- | --- |
    | 佐藤 | 案内文を作成し、参加方法と持ち物を明記する | 9/10 |
    | 鈴木 | 会場予約と接続テスト。[[接続手順\\|確認事項]]を更新 | 9/11 |

    > 質問の時間も五分あると安心ですね。

    ## 保留事項

    開催時刻は未確定です。参加人数を確認してから決めます。

    ```text
    [[コード中のリンク]] と ![画像](photo.png) はそのまま
    ```

    参考資料: ![[会場図]]
    """

    @Test func 幅の要求と画面端を純粋に計算して復元する() throws {
        var layout = MinutesLayout(); layout.visible = true
        let screen = NSRect(x: 0, y: 0, width: 2400, height: 1200)
        let frame = NSRect(x: 100, y: 100, width: 600, height: 700)
        #expect(layout.fitting(frame: frame, screen: screen, divider: 1).width == 1800)
        #expect(layout.fitting(frame: NSRect(x: 1700, y: 100, width: 600, height: 700), screen: screen, divider: 1).maxX == 2400)
        #expect(layout.fitting(frame: frame, screen: NSRect(x: 0, y: 0, width: 600, height: 900), divider: 1).width == 600)
        layout.visible = false; layout.leftWidth = 720
        #expect(layout.fitting(frame: frame, screen: screen, divider: 1).width == 720)
    }

    @Test func 本文の検証とsymlinkとサイズ上限() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("minutes.md")
        try Data(markdown.utf8).write(to: path)
        let link = root.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        if case .body(_, let blocks) = MinutesFileResult.read(link.path) {
            let rendered = MarkdownBodyRenderer.render(blocks).string
            #expect(!rendered.contains("tags:") && rendered.contains("当日の手順"))
            #expect(rendered.contains("[[コード中のリンク]]") && rendered.contains("![[会場図]]"))
        } else { Issue.record("symlink経由で読める") }
        try Data(repeating: 65, count: MinutesPath.bodyBytes + 1).write(to: path)
        if case .failure(let reason) = MinutesFileResult.read(path.path) { #expect(reason.contains("大きすぎる")) }
        else { Issue.record("過大本文を拒否する") }
        let fifo = root.appendingPathComponent("fifo.md"); #expect(mkfifo(fifo.path, 0o600) == 0)
        if case .failure = MinutesFileResult.read(fifo.path) {} else { Issue.record("FIFOを拒否する") }
        try Data([0xff, 0xfe, 0x80]).write(to: path)
        if case .failure(let reason) = MinutesFileResult.read(path.path) { #expect(reason.contains("UTF-8")) }
        else { Issue.record("非UTF-8を拒否する") }
    }

    @Test func 通常保存とrenameと削除再作成と停止を監視する() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("minutes.md")
        var bodies: [String] = [], missing = false
        let monitor = MinutesFileMonitor(path: path.path, interval: 0.05) { result in
            if case .body(let text, _) = result { bodies.append(text) }
            if case .missing = result { missing = true }
        }
        defer { monitor.stop() }
        try await eventually { missing }
        for text in ["初版", "新版"] {
            try Data(text.utf8).write(to: path, options: .atomic)
            try await eventually { bodies.last == text }
        }
        try FileManager.default.removeItem(at: path); missing = false
        try await eventually { missing }
        try Data("復帰".utf8).write(to: path)
        try await eventually { bodies.last == "復帰" }
        monitor.stop(); try Data("停止後".utf8).write(to: path)
        try await Task.sleep(for: .milliseconds(350)); #expect(bodies.last == "復帰")
    }

    @Test func 右ペインの五場面と編集保護と幅の往復() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "minutes-preview-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults)
        let window = try #require(controller.window); window.setFrameAutosaveName("")
        defer { controller.minutesSplit.preview.stop(); window.orderOut(nil) }
        window.setContentSize(NSSize(width: 600, height: 780)); window.orderFront(nil)
        let content = try #require(window.contentView)
        let store = MinutesStore(meetingID: UUID(), outputDirectory: root)
        controller.connectMinutes(store)
        controller.onSelectMinutes = { try store.select($0) }
        controller.apply(SessionSnapshot())
        controller.toggleMinutes(); content.layoutSubtreeIfNeeded()
        #expect(controller.minutesSplit.left.frame.width >= 420)
        #expect(controller.minutesSplit.preview.frame.width >= 320)
        let preview = controller.minutesSplit.preview
        #expect(window.makeFirstResponder(preview.pathField))
        #expect(preview.pathField.currentEditor() != nil)
        preview.pathField.stringValue = root.path + "/notes/../指定.md"
        _ = preview.control(preview.pathField, textView: preview.textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(store.state.humanMinutesPath == root.path + "/指定.md")
        preview.pathField.stringValue = ""
        _ = preview.control(preview.pathField, textView: preview.textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(store.state.humanMinutesPath == nil)
        func capture(_ name: String) throws {
            guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_MINUTES_CAPTURE"] else { return }
            content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
            if !preview.scroll.isHidden { #expect(preview.textView.frame.minY == 0) }
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
        }
        try capture("01-empty")
        let path = root.appendingPathComponent("定例会議.md")
        try Data(markdown.utf8).write(to: path); try store.select(path.path)
        try await eventually { preview.textView.string.contains("当日の手順") }; content.layoutSubtreeIfNeeded()
        #expect(preview.textView.string.contains("当日の手順"))
        #expect(!preview.scroll.isHidden)
        try capture("02-body")
        preview.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification))
        preview.pathField.stringValue = "/tmp/編集中.md"
        let missing = root.appendingPathComponent("見つからない.md")
        try store.select(missing.path)
        #expect(preview.pathField.stringValue == "/tmp/編集中.md")
        _ = preview.control(preview.pathField, textView: preview.textView, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(preview.pathField.stringValue == missing.path)
        try await eventually { preview.message.stringValue == "指定したファイルはまだありません。作成されると自動で表示します" }; try capture("03-missing")
        #expect(preview.message.stringValue.contains("自動で表示"))
        let started = Date(timeIntervalSince1970: 1_788_795_600)
        let utterances = (0..<60).map { i in Utterance(speaker: i % 3, start: Double(i * 15), end: Double(i * 15 + 10), text: i % 2 == 0 ? "当日の体験会は説明と体験を合わせて三十分、最後に質問の時間を取りましょう。" : "案内文には持ち物と集合場所を明記します。受付担当と予備の端末も確認します。") }
        var history = try AIStreamHistory(meetingID: store.meetingID)
        var conversation = AIConversation(meetingID: store.meetingID)
        for index in 0..<8 {
            let snapshot = try history.prepare(lines: [], outputDirectory: root)
            let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
                participantName: "迅雷", cliPath: "/tmp/helper", sessionPath: root.appendingPathComponent(".kikigaki-context/\(store.meetingID)/ai/sessions/1.json").path,
                requestToken: "fixture", question: "決定事項と次回までの担当をまとめて", capturedAt: started.addingTimeInterval(Double(index * 3 + 300)), audioCutoffSeconds: Double(index * 3 + 300))
            let request = try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant), number: index + 1)
            try conversation.append(request); try conversation.update(request.id) { try $0.beginSending(at: participant.capturedAt); try $0.submitted() }
            _ = try conversation.receive(AIReceiveEvent(request: request, kind: .answered, recordedAt: participant.capturedAt.addingTimeInterval(5), body: "担当と期限を議事録に反映しました。受付担当は次回までに確認します。"), at: participant.capturedAt.addingTimeInterval(5))
        }
        controller.apply(SessionSnapshot(ai: AIViewState(conversation: conversation, connection: .idle), state: .paused,
            utterances: utterances, timeline: MeetingTimeline(startedAt: started), names: SpeakerNames([0: "佐藤", 1: "鈴木", 2: "田中"]), elapsed: 900, markdownURL: root.appendingPathComponent("meeting.md")))
        try Data((markdown + String(repeating: "\n\n## 補足\n\n会場の接続環境と案内手順を確認し、次回の会議で担当者から報告します。", count: 30)).utf8).write(to: path)
        try store.select(path.path); try await eventually { preview.textView.string.contains("補足") }
        content.layoutSubtreeIfNeeded()
        if let reply = controller.transcriptDocument.rows.compactMap({ $0 as? AIReplyRow }).first {
            controller.transcriptDocument.scroll(NSPoint(x: 0, y: max(0, reply.frame.minY - 60)))
        }
        try capture("04-busy")
        window.setContentSize(NSSize(width: 1800, height: 900)); content.layoutSubtreeIfNeeded()
        preview.scroll.contentView.scroll(to: .zero)
        preview.scroll.reflectScrolledClipView(preview.scroll.contentView)
        try capture("05-wide-1800")
        #expect(try #require(preview.textView.textContainer).containerSize.width <= 720)
        #expect(abs(content.bounds.width - 1800) < 1)
        preview.scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
        preview.scroll.reflectScrolledClipView(preview.scroll.contentView)
        let selected = (preview.textView.string as NSString).range(of: "接続環境")
        preview.textView.setSelectedRange(selected)
        let oldY = preview.scroll.contentView.bounds.minY
        let oldBody = try String(contentsOf: path, encoding: .utf8)
        try Data((oldBody + "\n追記しました").utf8).write(to: path, options: .atomic)
        try await eventually { preview.textView.string.contains("追記しました") }
        #expect(abs(preview.scroll.contentView.bounds.minY - oldY) < 2)
        #expect(preview.textView.selectedRange() == selected)
        try Data("短い本文".utf8).write(to: path, options: .atomic)
        try await eventually { preview.textView.string == "短い本文" }
        #expect(preview.scroll.contentView.bounds.minY == 0)
        #expect(NSMaxRange(preview.textView.selectedRange()) <= (preview.textView.string as NSString).length)
        let left = controller.minutesSplit.left.frame.width
        controller.toggleMinutes(); #expect(abs(window.frame.width - left) < 1)
        let notificationRequest = try #require(conversation.questions.first?.request)
        let notification = try AIMinutesEvent(request: notificationRequest, path: path.path, recordedAt: Date())
        try AIFileStore(root: root).write(AIJSON.encode(notification), to: [".kikigaki-context", store.meetingID.uuidString, "ai", "inbox", notification.filename])
        store.scan(questions: conversation.questions)
        #expect(store.hasUnseenMinutes)
        try capture("06-minutes-notice")
        controller.toggleMinutes(); #expect(controller.minutesSplit.isPreviewVisible)
        #expect(!store.hasUnseenMinutes)
        #expect(MinutesLayout.load(defaults).visible)
    }
}
