import AppKit
import Foundation
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import Kikigaki

extension AppKitTests {
@Suite(.serialized) @MainActor struct SpeakerPopoverTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func show(names: SpeakerNames = SpeakerNames([0: "タダシ"]),
                      participants: [String] = ["松岡", "Bob", "Tadashi Aikawa"],
                      frequent: [String] = ["松岡", "Bob", "Tadashi Aikawa", "伊藤", "本田", "松本"],
                      anchorNearTop: Bool = false) throws -> (SpeakerPopover, NSWindow, NSTextField, NSView) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        let anchor = try #require(window.contentView)
        let popover = SpeakerPopover(slot: 1, names: names, speakers: [.init(name: "タダシ")],
            avatars: AvatarStore(cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("speaker-test-avatars")),
            participants: participants, frequentNames: frequent)
        popover.present(relativeTo: NSRect(x: 200, y: anchorNearTop ? 380 : 10, width: 22, height: 22), of: anchor)
        let field = try #require(descendants(popover.contentView)
            .compactMap { $0 as? NSTextField }.first { $0.isEditable && $0.accessibilityLabel() == "話者Bの名前" })
        return (popover, window, field, try #require(field.superview))
    }

    private func edit(_ text: String, field: NSTextField, popover: SpeakerPopover) {
        field.stringValue = text
        (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        popover.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private func command(_ selector: Selector, field: NSTextField, popover: SpeakerPopover) -> Bool {
        popover.control(field, textView: (field.currentEditor() as? NSTextView) ?? NSTextView(), doCommandBy: selector)
    }

    private func labels(_ content: NSView) -> [String] {
        descendants(content).compactMap { $0 as? NSTextField }.filter { !$0.isEditable }.map(\.stringValue)
    }

    /// 任意の撮影先だけへ書く。テストはマイク・モデル・利用者の設定と会議を使わない。
    private func capture(_ name: String, content: NSView, region: NSRect? = nil, scale: CGFloat? = nil) throws {
        guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_SPEAKER_CAPTURE"] else { return }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // NSPopoverの背景合成はcacheDisplayで輪郭が乱れるため、実表示の内容領域を撮る。
        let view = content
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let rect = region ?? view.bounds
        let bitmap: NSBitmapImageRep
        if let scale {
            bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(rect.width * scale), pixelsHigh: Int(rect.height * scale), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 32))
            bitmap.size = rect.size
        } else { bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: rect)) }
        view.cacheDisplay(in: rect, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"))
    }

    @Test func 初期全選択から絞り込みと0件へ移っても入力欄が動かない() async throws {
        for nearTop in [false, true] {
            let (popover, window, field, content) = try show(anchorNearTop: nearTop)
            defer { popover.close(); window.close() }
            let editor = try #require(field.currentEditor() as? NSTextView)
            #expect(editor.selectedRange() == NSRange(location: 0, length: 3))
            try await Task.sleep(for: .milliseconds(100))
            #expect(labels(content).contains("松岡"))
            #expect(!labels(content).contains("⏎"))
            let popoverWindow = try #require(field.window)
            let originalFrame = popoverWindow.frame
            let originalField = popoverWindow.convertToScreen(field.convert(field.bounds, to: nil))
            if !nearTop { try capture("speaker-initial", content: content) }
            edit("松", field: field, popover: popover)
            try await Task.sleep(for: .milliseconds(30))
            #expect(labels(content).contains("「松」をそのまま使う"))
            #expect(labels(content).contains("松岡"))
            #expect(labels(content).contains("松本"))
            #expect(labels(content).filter { $0 == "⏎" }.count == 1)
            var matchedRect = NSRect.null
            for name in ["松岡", "松本"] {
                let matched = try #require(descendants(content).compactMap { $0 as? NSTextField }.first { $0.stringValue == name })
                matchedRect = matchedRect.union(matched.convert(matched.bounds, to: content))
                #expect(matched.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                        == NSFont.systemFont(ofSize: 12, weight: .bold))
                #expect(matched.attributedStringValue.attribute(.font, at: 1, effectiveRange: nil) as? NSFont
                        == NSFont.systemFont(ofSize: 12, weight: .regular))
            }
            if !nearTop {
                try capture("speaker-filtered", content: content)
                try capture("speaker-filtered-enlarged", content: content, region: matchedRect.insetBy(dx: -4, dy: -4), scale: 8)
            }
            edit("佐々木", field: field, popover: popover)
            try await Task.sleep(for: .milliseconds(30))
            #expect(labels(content).contains("一致する候補はありません"))
            #expect(labels(content).contains("「佐々木」をそのまま使う"))
            #expect(popoverWindow.frame == originalFrame)
            #expect(popoverWindow.convertToScreen(field.convert(field.bounds, to: nil)) == originalField)
            if !nearTop { try capture("speaker-empty", content: content) }
        }
    }

    @Test func キー操作は使用中を飛ばし完全一致を選び自由入力を確定できる() throws {
        let (popover, window, field, content) = try show()
        defer { popover.close(); window.close() }
        var renamed: String?
        popover.onRename = { renamed = $0 }
        #expect(command(#selector(NSResponder.moveDown(_:)), field: field, popover: popover))
        #expect(command(#selector(NSResponder.moveUp(_:)), field: field, popover: popover))
        for _ in 0..<20 { _ = command(#selector(NSResponder.moveDown(_:)), field: field, popover: popover) }
        let used = try #require(descendants(content).compactMap { $0 as? NSButton }.first { $0.toolTip == "タダシ" })
        #expect(!used.isEnabled)
        #expect(used.accessibilityLabel()?.contains("話者Aで使用中") == true)
        _ = command(#selector(NSResponder.insertNewline(_:)), field: field, popover: popover)
        #expect(renamed == "松本")

        let (exactPopover, exactWindow, exactField, exactContent) = try show()
        defer { exactPopover.close(); exactWindow.close() }
        exactPopover.onRename = { renamed = $0 }
        edit("Bob", field: exactField, popover: exactPopover)
        #expect(!labels(exactContent).contains("「Bob」をそのまま使う"))
        #expect(labels(exactContent).contains("⏎"))
        _ = command(#selector(NSResponder.insertNewline(_:)), field: exactField, popover: exactPopover)
        #expect(renamed == "Bob")

        let (freePopover, freeWindow, freeField, _) = try show()
        defer { freePopover.close(); freeWindow.close() }
        freePopover.onRename = { renamed = $0 }
        edit("佐々木", field: freeField, popover: freePopover)
        _ = command(#selector(NSResponder.insertNewline(_:)), field: freeField, popover: freePopover)
        #expect(renamed == "佐々木")
    }

    @Test func 選択無しReturnと候補クリックとリセットとEsc() throws {
        for action in ["return", "click", "reset", "escape"] {
            let (popover, window, field, content) = try show()
            defer { popover.close(); window.close() }
            var renamed: String?
            popover.onRename = { renamed = $0 }
            switch action {
            case "return":
                _ = command(#selector(NSResponder.insertNewline(_:)), field: field, popover: popover)
                #expect(renamed == "話者B")
            case "click":
                let button = try #require(descendants(content).compactMap { $0 as? NSButton }.first { $0.toolTip == "Bob" })
                button.performClick(nil)
                #expect(renamed == "Bob")
            case "reset":
                let button = try #require(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "既定に戻す" })
                button.performClick(nil)
                #expect(renamed == "")
            default:
                _ = command(#selector(NSResponder.cancelOperation(_:)), field: field, popover: popover)
                #expect(renamed == nil)
            }
        }
    }

    @Test func 八行超はスクロールし変換確定のReturnでは改名しない() throws {
        let (popover, window, field, content) = try show(participants: (0..<12).map { "候補\($0)" }, frequent: [])
        defer { popover.close(); window.close() }
        let scroll = try #require(descendants(content).compactMap { $0 as? NSScrollView }.first)
        #expect(scroll.frame.height == CGFloat(8 * 28))
        #expect(scroll.hasVerticalScroller)
        for _ in 0..<12 { _ = command(#selector(NSResponder.moveDown(_:)), field: field, popover: popover) }
        #expect(scroll.contentView.bounds.origin.y > 0)
        var renamed: String?
        popover.onRename = { renamed = $0 }
        let editor = NSTextView()
        editor.setMarkedText("まつ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!popover.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(renamed == nil)
    }

    @Test func AI通知の議事録から参加者を読み停止後も現在の会議を履歴から除く() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-review-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("2026-10-09_1000.md")
        try "# KIKIGAKI 2026-10-09 10:00\n- 話者: A=現在だけの名前\n\n## 書き起こし\n".write(to: current, atomically: true, encoding: .utf8)
        let past = root.appendingPathComponent("2026-10-08_1000.md")
        try "# KIKIGAKI 2026-10-08 10:00\n- 話者: A=過去の名前\n\n## 書き起こし\n".write(to: past, atomically: true, encoding: .utf8)
        let minutes = root.appendingPathComponent("AI議事録.md")
        try "---\nparticipants: [松岡]\n---\n".write(to: minutes, atomically: true, encoding: .utf8)
        let meetingID = UUID()
        var history = try AIStreamHistory(meetingID: meetingID)
        let source = try history.prepare(lines: [], outputDirectory: root)
        let participant = AIParticipantContext(streamID: source.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: "テストAI", cliPath: "/tmp/helper",
            sessionPath: root.appendingPathComponent(".kikigaki-context/\(meetingID)/ai/sessions/1.json").path,
            requestToken: "test-token", question: "議事録", capturedAt: Date(), audioCutoffSeconds: 1)
        let request = try AIRequest(envelope: AIEnvelope(snapshot: source, participant: participant), number: 1)
        let disk = MinutesFileStore(root: root, meetingID: meetingID)
        let initial = MinutesState(meetingID: meetingID)
        var notified = initial
        try notified.receive(AIMinutesEvent(request: request, path: minutes.path, recordedAt: Date()), for: request)
        try notified.advanceRevision()
        try disk.save(notified, replacing: initial)
        let store = MinutesStore(meetingID: meetingID, outputDirectory: root, markdownURL: current)
        #expect(store.state.minutesPath == minutes.path)
        #expect(store.state.participantMinutesPath == nil)
        let preferences = MinutesTestDefaults()
        let controller = TranscriptWindowController(minutesDefaults: preferences.value)
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        defer { window.orderOut(nil); controller.minutesSplit.preview.stop() }
        controller.connectMinutes(store)
        for state: RecordingState in [.recording, .idle] {
            controller.apply(SessionSnapshot(state: state,
                utterances: [.init(speaker: 1, start: 0, end: 1, text: "改名の検証")], markdownURL: current, saved: state == .idle))
            let popover = controller.makeSpeakerPopover(slot: 1)
            defer { popover.close() }
            #expect(labels(popover.contentView).contains("松岡"))
            #expect(labels(popover.contentView).contains("過去の名前"))
            #expect(!labels(popover.contentView).contains("現在だけの名前"))
            // 外部エディタで更新した後の再生成も本番の入口で確かめる。
            try "---\nparticipants: [松本]\n---\n".write(to: minutes, atomically: true, encoding: .utf8)
            popover.close()
            let reopened = controller.makeSpeakerPopover(slot: 1)
            #expect(labels(reopened.contentView).contains("松本"))
            #expect(!labels(reopened.contentView).contains("松岡"))
            reopened.close()
            try "---\nparticipants: [松岡]\n---\n".write(to: minutes, atomically: true, encoding: .utf8)
        }
        // 設定で変えたキーを本番の入口で読む。
        try "---\nparticipants: [松岡]\nattendees: [伊藤]\n---\n".write(to: minutes, atomically: true, encoding: .utf8)
        controller.apply(SessionSnapshot(state: .idle, utterances: [.init(speaker: 1, start: 0, end: 1, text: "改名の検証")],
                                         participantsKey: "attendees", markdownURL: current, saved: true))
        let custom = controller.makeSpeakerPopover(slot: 1)
        defer { custom.close() }
        #expect(labels(custom.contentView).contains("伊藤"))
        #expect(!labels(custom.contentView).contains("松岡"))
    }
}
}
