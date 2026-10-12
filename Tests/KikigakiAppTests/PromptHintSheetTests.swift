import AppKit
import Testing
import KikigakiCore
@testable import Kikigaki

extension AppKitTests {
@Suite(.serialized) @MainActor struct PromptHintSheetTests {
    private func profiles(_ root: URL) -> [ResolvedAIConfig] {
        let names: [String] = ["指示あり", "指示なし", "別の指示"]
        return names.enumerated().map { index, name in
            ResolvedAIConfig(config: AIConfig(name: name, command: "/bin/echo", cwd: root.path,
                alwaysPrompt: index == 1 ? "" : "\(name): 必ず日本語で返してください\n結論を先にしてください",
                initialPrompt: "\(name)の初期文面", autoStart: index == 0), home: root, slot: index + 1)
        }
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func select(_ index: Int, in window: NSWindow) throws {
        let content = try #require(window.contentView)
        let picker = try #require(descendants(content).compactMap { $0 as? AIDestinationPicker }.first)
        let popup = try #require(descendants(picker).compactMap { $0 as? NSPopUpButton }.first)
        popup.selectItem(at: index)
        #expect(popup.sendAction(popup.action, to: popup.target))
    }
    private func check(_ hint: AIAlwaysPromptHint, prompt: String) {
        #expect(hint.isHidden == prompt.isEmpty)
        #expect(hint.toolTip == (prompt.isEmpty ? nil : prompt))
        #expect(hint.label.toolTip == hint.toolTip)
        #expect(hint.label.stringValue == "＋ 毎回付く指示あり")
        #expect(hint.label.font?.pointSize == 11)
        if !prompt.isEmpty {
            #expect(hint.window?.allowsToolTipsWhenApplicationIsInactive == true)
            hint.window?.contentView?.layoutSubtreeIfNeeded()
            #expect(hint.superview != nil && hint.frame.height > 0 && hint.frame.width > 0)
        }
    }
    private func capture(_ name: String, window: NSWindow) async throws {
        guard let path = ProcessInfo.processInfo.environment["KIKIGAKI_PROMPT_HINT_CAPTURE"] else { return }
        let directory = URL(fileURLWithPath: path).standardizedFileURL
        try #require(directory.path.hasPrefix("/tmp/") || directory.path.hasPrefix("/private/tmp/"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = try #require(window.contentView)
        // 窓の背景とレイヤー上の標準コントロールも、本文のキャッシュへ含める。
        content.wantsLayer = true
        content.layer?.backgroundColor = window.backgroundColor.cgColor
        content.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        content.layoutSubtreeIfNeeded()
        let view: NSView, bounds: NSRect
        if let scroll = content as? NSScrollView, let document = scroll.documentView {
            view = document; bounds = scroll.documentVisibleRect
        } else { view = content; bounds = content.bounds }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    @Test func 手動シートの表示は宛先切替に追従し下書きを変えない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var config = ResolvedConfig(config: KikigakiConfig(), home: root)
        config.aiProfiles = profiles(root)
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
                                     aiStore: AIRecordStore(directory: root))
        let suite = "PromptHintSheetTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let parent = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults)
        parent.window?.setFrameAutosaveName("")
        defer { parent.window?.orderOut(nil) }
        let app = AppDelegate(testingSession: session, config: config, window: parent)
        app.showAISheet(parent: nil)
        let sheet = try #require(app.aiSheet)
        defer { sheet.close(); app.dismissAISheet() }
        check(sheet.alwaysPromptHint, prompt: config.aiProfiles[0].alwaysPrompt)
        #expect(sheet.draft == config.aiProfiles[0].initialPrompt)
        sheet.restoreDraft("編集した下書き")
        try await capture("manual-with-instruction", window: sheet.window)
        try select(1, in: sheet.window)
        check(sheet.alwaysPromptHint, prompt: "")
        #expect(sheet.draft == config.aiProfiles[1].initialPrompt)
        try await capture("manual-without-instruction", window: sheet.window)
        try select(2, in: sheet.window)
        check(sheet.alwaysPromptHint, prompt: config.aiProfiles[2].alwaysPrompt)
        try select(0, in: sheet.window)
        check(sheet.alwaysPromptHint, prompt: config.aiProfiles[0].alwaysPrompt)
        #expect(sheet.draft == "編集した下書き")
        // 宛先を固定する返答・再送でも、その宛先の毎回付く指示を示す。
        let fixed = AIQuestionSheet(participant: "指示あり", parentNumber: 1, draft: "返答", voice: "",
            range: "", tentative: false, canSubmit: true, fixedSlot: 1, alwaysPrompt: config.aiProfiles[0].alwaysPrompt)
        #expect(!fixed.alwaysPromptHint.isHidden && fixed.alwaysPromptHint.toolTip == config.aiProfiles[0].alwaysPrompt)
        fixed.close()
    }

    @Test func 自動シートの表示は宛先切替に追従し下書きを変えない() async throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var config = ResolvedConfig(config: KikigakiConfig(), home: root)
        config.aiProfiles = profiles(root)
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
                                     aiStore: AIRecordStore(directory: root))
        let sheet = AIScheduleSheet(session: session, profile: config.aiProfiles[0])
        defer { sheet.close() }
        sheet.window.orderFront(nil)
        check(sheet.alwaysPromptHint, prompt: config.aiProfiles[0].alwaysPrompt)
        let content = try #require(sheet.window.contentView)
        let editor = try #require(descendants(content).compactMap { $0 as? AIQuestionEditor }.first)
        editor.string = "自動の編集"; sheet.textDidChange(Notification(name: NSText.didChangeNotification))
        try await capture("automatic-with-instruction", window: sheet.window)
        try select(1, in: sheet.window)
        check(sheet.alwaysPromptHint, prompt: "")
        #expect(sheet.draft.prompt == config.aiProfiles[1].initialPrompt)
        try await capture("automatic-without-instruction", window: sheet.window)
        try select(2, in: sheet.window)
        check(sheet.alwaysPromptHint, prompt: config.aiProfiles[2].alwaysPrompt)
        try select(0, in: sheet.window)
        check(sheet.alwaysPromptHint, prompt: config.aiProfiles[0].alwaysPrompt)
        #expect(sheet.draft.prompt == "自動の編集")
    }

    @Test func 録音開始シートの手動表示は宛先と指定しないに追従し高さを保つ() async throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let list = profiles(root)
        let suite = "PromptHintSheetTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // 指示の無い宛先で開いても、後から表示する1行分の高さを確保する。
        defaults.set(list[1].name, forKey: StartSheet.manualDefaultsKey)
        let sheet = StartSheet(profiles: list, diarizationEnabled: true, exclusion: AudioExclusion(),
                               defaults: defaults, microphoneName: { "テスト用マイク" })
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.orderFront(nil); sheet.present(on: parent)
        defer { sheet.close(); parent.orderOut(nil) }
        let content = try #require(sheet.window.contentView)
        content.layoutSubtreeIfNeeded()
        let frame = sheet.window.frame
        let manualChoices = try #require(sheet.manualAlwaysPromptHint.superview)
        let choicesHeight = manualChoices.frame.height
        check(sheet.manualAlwaysPromptHint, prompt: "")
        #expect(sheet.selectedManualSlot == list[1].slot)
        #expect(sheet.manualAlwaysPromptHint.frame.height > 0)
        try await capture("start-manual-without-instruction", window: sheet.window)
        for slot in [1, 3, 0, 2, 1] {
            sheet.manualDestination.selectItem(withTag: slot)
            #expect(sheet.manualDestination.sendAction(sheet.manualDestination.action, to: sheet.manualDestination.target))
            content.layoutSubtreeIfNeeded()
            check(sheet.manualAlwaysPromptHint, prompt: list.first { $0.slot == slot }?.alwaysPrompt ?? "")
            #expect(sheet.selectedManualSlot == (slot == 0 ? nil : slot))
            #expect(sheet.window.frame == frame)
            #expect(manualChoices.frame.height == choicesHeight)
            #expect(sheet.manualAlwaysPromptHint.frame.height > 0)
            // 自動送信の宛先と指示は、手動側の選び直しでは変わらない。
            check(sheet.alwaysPromptHint, prompt: list[0].alwaysPrompt)
            #expect(sheet.selectedSlot == list[0].slot)
        }
        try await capture("start-manual-with-instruction", window: sheet.window)
    }

    @Test func 録音開始シートの表示は宛先と送らないに追従し高さを保つ() async throws {
        _ = NSApplication.shared
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let list = profiles(root)
        let suite = "PromptHintSheetTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sheet = StartSheet(profiles: list, diarizationEnabled: true, exclusion: AudioExclusion(),
                               defaults: defaults, microphoneName: { "テスト用マイク" })
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.orderFront(nil); sheet.present(on: parent)
        defer { sheet.close(); parent.orderOut(nil) }
        let height = sheet.window.frame.height
        check(sheet.alwaysPromptHint, prompt: list[0].alwaysPrompt)
        sheet.editor.string = "開始時の編集"; sheet.textDidChange(Notification(name: NSText.didChangeNotification))
        try await capture("start-with-instruction", window: sheet.window)
        for slot in [2, 3, 0, 1] {
            sheet.destination.selectItem(withTag: slot); sheet.destinationChanged()
            check(sheet.alwaysPromptHint, prompt: list.first { $0.slot == slot }?.alwaysPrompt ?? "")
            #expect(sheet.window.frame.height == height)
            if slot == 2 { try await capture("start-without-instruction", window: sheet.window) }
        }
        #expect(sheet.editor.string == "開始時の編集")
    }
}
}
