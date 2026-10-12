import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct DestinationFooterTests {
    private func state(_ root: URL, long: Bool, notices: Bool = true,
                       automaticWaiting: Bool = false, manualWaiting: Bool = false) throws -> SessionSnapshot {
        var history = try AIStreamHistory(meetingID: UUID())
        let context = try history.prepare(lines: [], outputDirectory: root)
        var conversation = AIConversation(meetingID: history.meetingID)
        for (slot, waiting) in [(1, automaticWaiting), (2, manualWaiting), (3, notices)] where waiting {
            let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
                participantName: slot == 1 ? "議事録" : "スライド", cliPath: "/tmp/helper",
                sessionPath: root.appendingPathComponent(".kikigaki-context/\(history.meetingID)/ai/sessions/\(slot)/1.json").path,
                requestToken: "test", question: "確認", capturedAt: Date(), audioCutoffSeconds: 0,
                trigger: slot == 1 ? .scheduled : nil, profile: slot == 1 ? "議事録" : "スライド", profileSlot: slot)
            let request = try AIRequest(envelope: AIEnvelope(snapshot: context, participant: participant),
                number: conversation.questions.count + 1, voiceQuestion: "", snapshot: context)
            try conversation.append(request)
            try conversation.update(request.id) { try $0.beginSending(at: Date()); try $0.submitted() }
            if slot == 3 {
                _ = try conversation.receive(AIReceiveEvent(request: request, kind: .needsInput, recordedAt: Date(),
                    body: "この案で進めますか", reason: "clarification"), at: Date())
            }
        }
        var state = SessionSnapshot(ai: AIViewState(conversation: conversation, warning: notices ? "確認してください" : nil), state: .recording,
            utterances: [.init(speaker: 0, start: 0, end: 1, text: "合図でスライドを更新します。")], markdownURL: root.appendingPathComponent("meeting.md"))
        state.aiSchedule.active = true
        state.aiSchedule.nextFire = Date().addingTimeInterval(150)
        state.automaticDestination = .init(slot: 1, name: long ? "議事録と議論のボードを更新する担当" : "議事録")
        state.manualDestination = .init(slot: 2, name: long ? "会議で使うスライドを更新する担当" : "スライド")
        return state
    }

    @Test(arguments: [420, 600]) func 狭い幅でも右端操作を保ち二段の名前だけ縮める(width: Int) throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "DestinationFooterTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults, textDefaults: defaults)
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        window.setContentSize(NSSize(width: width, height: 578))
        window.setFrameOrigin(NSPoint(x: 20000, y: 20000)); window.orderFront(nil)
        defer { window.orderOut(nil) }
        let footer = controller.compactFooter
        for long in [false, true] {
            var state = try state(root, long: long)
            controller.apply(state)
            footer.minutesNotice.isHidden = false
            let size = controller.windowWillResize(window, to: NSSize(width: width, height: 600))
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
            let content = try #require(window.contentView)
            content.layoutSubtreeIfNeeded()
            #expect(abs(content.bounds.width - CGFloat(width)) < 1)
            #expect(footer.frame.height == 54)
            #expect(!footer.destinations.isHidden)
            #expect(footer.confirmation.count == 1 && !footer.confirmation.isHidden)
            #expect(footer.manualDestination.toolTip?.contains(state.manualDestination!.name) == true)
            for button in [footer.confirmation, footer.warning, footer.minutesNotice, footer.pin, footer.more] {
                #expect(button.frame.width == 36)
                #expect(button.frame.maxX <= footer.bounds.maxX - 15)
            }
            #expect(footer.automaticDestination.frame.width == footer.manualDestination.frame.width)
            #expect(footer.automaticDestination.frame.minY > footer.manualDestination.frame.maxY)
            #expect(footer.destinations.frame.maxX < footer.confirmation.frame.minX)
            #expect(footer.automaticDestination.nameFrame.width >= 36)
            #expect(footer.manualDestination.nameFrame.width >= 36)
            if width == 420 && long {
                let name = try #require(state.automaticDestination?.name)
                #expect((name as NSString).size(withAttributes: [.font: footer.automaticDestination.nameFont]).width >
                        footer.automaticDestination.nameFrame.width)
            }
            let nameWidth = footer.automaticDestination.nameFrame.width
            controller.setTextScale(.init(percent: 200))
            content.layoutSubtreeIfNeeded()
            #expect(footer.automaticDestination.nameFrame.width == nameWidth)
            #expect(footer.automaticDestination.nameFont.pointSize == 12)
            controller.setTextScale(.actual)
            state.state = .idle; state.aiSchedule.active = false
            controller.apply(state)
            #expect(!footer.destinations.isHidden && !footer.manualDestination.isEnabled)
            #expect(footer.automaticDestination.destinationName == "送らない")
        }
    }

    @Test func 自動実行中の420pt窓で宛先名を11字以上残し行の高さを枠に収める() throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "DestinationFooterLegibility.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults, textDefaults: defaults)
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        window.setContentSize(NSSize(width: 420, height: 578))
        window.setFrameOrigin(NSPoint(x: 20000, y: 20000)); window.orderFront(nil)
        defer { window.orderOut(nil) }
        controller.apply(try state(root, long: true, notices: false, automaticWaiting: true))
        let footer = controller.compactFooter
        footer.minutesNotice.isHidden = false
        try #require(window.contentView).layoutSubtreeIfNeeded()
        #expect(footer.confirmation.isHidden && footer.warning.isHidden)
        #expect(footer.frame.height == 54)
        let button = footer.automaticDestination
        #expect(button.displayText == "実行中")
        let prefixWithEllipsis = String(button.destinationName.prefix(11)) + "…"
        #expect((prefixWithEllipsis as NSString).size(withAttributes: [.font: button.nameFont]).width <= button.nameFrame.width)
        for row in [button, footer.manualDestination] {
            let nameHeight = (row.destinationName as NSString).size(withAttributes: [.font: row.nameFont]).height
            #expect(nameHeight <= row.nameFrame.height)
            #expect(row.bounds.contains(row.nameFrame) && row.frame.height == 20)
        }
    }

    @Test(arguments: [420, 600]) func 二段フッターの5状態を撮る(width: Int) throws {
        guard ProcessInfo.processInfo.environment["KIKIGAKI_VOICE_CAPTURE"] != nil ||
              ProcessInfo.processInfo.environment["KIKIGAKI_STATE_CAPTURE"] != nil else { return }
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "DestinationFooterCapture.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults, textDefaults: defaults)
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        window.setContentSize(NSSize(width: width, height: 578))
        window.setFrameOrigin(NSPoint(x: 20000, y: 20000)); window.orderFront(nil)
        defer { window.orderOut(nil) }
        for phase in ["automatic", "automatic-notices", "manual", "off", "stopped", "preparing", "both", "stopped-waiting"] {
            var state = try state(root, long: true, notices: phase == "automatic-notices",
                automaticWaiting: phase == "automatic" || phase == "automatic-notices" || phase == "both",
                manualWaiting: phase == "manual" || phase == "both" || phase == "stopped-waiting")
            if phase == "off" { state.aiSchedule.active = false; state.manualDestination = nil }
            if phase == "stopped" || phase == "stopped-waiting" {
                state.state = .idle; state.aiSchedule.active = false; state.saved = true
            }
            if phase == "preparing" { state.ai?.automaticPreparing = true; state.ai?.manualPreparing = true }
            controller.apply(state)
            controller.compactFooter.minutesNotice.isHidden = false
            let size = controller.windowWillResize(window, to: NSSize(width: width, height: 600))
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
            let content = try #require(window.contentView)
            content.layoutSubtreeIfNeeded()
            try capture(content, name: "footer-\(width)-\(phase)")
            try capture(controller.compactFooter, name: "footer-detail-\(width)-\(phase)")
        }
    }

    @Test(arguments: [420, 600], [false, true])
    func 開始シートの手動送信の区切り線に上下の余白を保つ(width: Int, reserved: Bool) throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "DestinationFooterTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("スライド", forKey: StartSheet.manualDefaultsKey)
        let profiles = ["議事録", "スライド"].enumerated().map {
            ResolvedAIConfig(config: AIConfig(name: $0.element, command: "/bin/echo", cwd: root.path,
                autoPrompt: "会議の内容を更新してください", autoStart: $0.offset == 0), home: root, slot: $0.offset + 1)
        }
        let parent = NSWindow(contentRect: NSRect(x: 20000, y: 20000, width: width, height: 578),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; parent.orderFront(nil)
        let meeting = try NextMeeting(minutesPath: root.appendingPathComponent("定例.md").path, title: "開発定例", ai: "議事録", manual: "スライド")
        let sheet = StartSheet(profiles: profiles, diarizationEnabled: true, exclusion: AudioExclusion(),
                               nextMeetings: reserved ? [meeting] : [], defaults: defaults,
                               outputKind: { .builtInSpeaker }, microphoneName: { "MacBook Proのマイク" })
        defer { sheet.close(); parent.orderOut(nil) }
        sheet.present(on: parent)
        #expect(sheet.options?.manualSlot == 2)
        #expect(sheet.window.sheetParent === parent)
        let scroll = try #require(sheet.window.contentView as? NSScrollView)
        let view = try #require(scroll.documentView)
        view.layoutSubtreeIfNeeded()
        let manualRow = try #require(sheet.manualDestination.superview as? NSStackView)
        let rows = try #require(manualRow.superview as? NSStackView)
        let index = try #require(rows.arrangedSubviews.firstIndex { $0 === manualRow })
        let separator = rows.arrangedSubviews[index - 1]
        let line = separator.convert(separator.bounds, to: view)
        let above = sheet.final.convert(sheet.final.bounds, to: view).minY - line.maxY
        let below = line.minY - sheet.manualDestination.convert(sheet.manualDestination.bounds, to: view).maxY
        #expect(above >= 9.5)
        #expect(below >= 9.5)
        try capture(view, rect: scroll.documentVisibleRect, name: "start-sheet-parent-\(width)-\(reserved ? "reserved" : "unreserved")")
    }

    private func capture(_ view: NSView, rect: NSRect? = nil, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["KIKIGAKI_VOICE_CAPTURE"]
            ?? ProcessInfo.processInfo.environment["KIKIGAKI_STATE_CAPTURE"] else { return }
        let bounds = rect ?? view.bounds
        for scale in [1, 2] {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(bounds.width) * scale, pixelsHigh: Int(bounds.height) * scale, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 32))
            bitmap.size = bounds.size
            view.cacheDisplay(in: bounds, to: bitmap)
            let suffix = scale == 1 ? "" : "-2x"
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output).appendingPathComponent(name + suffix + ".png"))
        }
    }
}
