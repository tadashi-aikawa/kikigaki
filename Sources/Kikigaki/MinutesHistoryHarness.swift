#if DEBUG
import AppKit
import KikigakiCore

/// 専用suiteだけで、実アプリのクリック・キー操作・再起動と実寸撮影を行う。
@MainActor final class MinutesHistoryHarness: NSObject, NSApplicationDelegate {
    private let output: URL
    private var suite: String { "kikigaki-minutes-history-verification." + output.lastPathComponent }
    private var windows: [NSWindow] = []
    private var controller: TranscriptWindowController?
    private var views: [MinutesPreviewView] = []
    init(output: String) { self.output = URL(fileURLWithPath: output) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = ApplicationMenu.make()
        Task {
            do { try await verify(); log("PASS"); NSApp.terminate(nil) }
            catch { log("FAIL: \(error)"); exit(1) }
        }
    }
    private func log(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
    private func require(_ value: Bool, _ message: String) throws { if !value { throw AIError.invalid(message) } }
    private func wait(_ message: String = "UI待機が完了しません", _ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(condition(), message)
    }
    private func click(_ view: NSView) throws {
        guard let window = view.window else { throw AIError.invalid("window") }
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
    }
    private func key(_ code: UInt16, _ characters: String, in window: NSWindow) {
        window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code)!)
    }
    private func focus(_ view: MinutesPreviewView) async throws {
        // 別の検証アプリによる起動直後の失焦点を、利用者の再クリックと同じ経路で扱う。
        for _ in 0..<3 {
            view.window?.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            view.window?.makeFirstResponder(nil)
            try click(view.pathField)
            for _ in 0..<20 {
                if view.pathField.currentEditor() != nil && (view.history.paths.isEmpty || !view.historyPopup.isHidden) { return }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        throw AIError.invalid("パス欄のフォーカスと一覧")
    }
    private func capture(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AIError.invalid("bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        let actual = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        actual.size = view.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: actual)
        bitmap.draw(in: view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        try actual.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + "-1x.png"))
    }
    private func verify() async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output.appendingPathComponent("meetings"), withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: suite)!
        let files = output.appendingPathComponent("資料/プロジェクト定例/議事録")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let paths = (1...10).map { files.appendingPathComponent(String(format: "第%02d回 開発定例.md", $0)).path }
        let missing = files.appendingPathComponent("移動済みの議事録.md").path
        for (index, path) in paths.enumerated() {
            let text = "# 開発定例 第\(index + 1)回\n\n## 決定事項\n\n- 次回の公開に向けて、確認項目を整理する。\n- 録音と議事録の保存を確認する。\n\n## 次回までの作業\n\n| 担当 | 作業 |\n| --- | --- |\n| 田中 | 公開前の確認 |\n| 佐藤 | 動作確認の記録 |\n\n## 継続して検討すること\n\n前回の議事録を開き、決定事項と残っている課題を引き継ぐ。\n"
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        }
        let restarting = CommandLine.arguments.contains("--history-restart")
        if restarting {
            try require(MinutesHistoryStore(defaults: defaults).paths == [paths[2], paths[1], paths[0]], "再起動後の履歴")
            log("再起動した別プロセスで3件の保存順を確認")
        } else { defaults.removePersistentDomain(forName: suite) }

        log("検証ビュー生成")
        let preview = MinutesPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 740), defaults: defaults)
        log("検証ウィンドウ表示")
        views.append(preview)
        let window = NSWindow(contentRect: preview.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        windows.append(window); window.contentView = preview; window.title = "議事録履歴の検証"
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        preview.layoutSubtreeIfNeeded()
        log("検証ウィンドウ配置済み")
        try await Task.sleep(for: .milliseconds(100))
        var store = MinutesStore(meetingID: UUID(), outputDirectory: output.appendingPathComponent("meetings"))
        func connect() {
            store.onPreviewChange = { [weak preview, weak store] in
                guard let store else { return }
                preview?.update(path: store.state.minutesPath, source: store.state.targetSource, active: true)
            }
            preview.onSelect = { [weak store] in try store?.select($0) }
        }
        connect()
        if restarting {
            try await focus(preview)
            log("再起動後の一覧を表示")
            try require(preview.historyPopup.rows.count == 3, "再起動後の一覧")
            try click(preview.historyPopup.rows[0])
            try await wait { preview.document.renderedText.contains("第3回") }
            log("再起動後に履歴クリックで議事録を再表示")
            defaults.removePersistentDomain(forName: suite)
            return
        }
        try store.select(paths[0])
        try await wait("最初のファイルの描画と履歴記録") { preview.history.paths == [paths[0]] }
        // 600ptはプレビュー単体、1800ptは会話を含む本番分割ウィンドウ。
        for width in [600, 1800] {
            let target: MinutesPreviewView
            let captureView: NSView
            if width == 600 { target = preview; captureView = preview }
            else {
                window.orderOut(nil)
                let value = TranscriptWindowController(minutesDefaults: defaults); controller = value
                value.window?.setFrameAutosaveName("")
                value.connectMinutes(store); value.onSelectMinutes = { try store.select($0) }
                var snapshot = SessionSnapshot(); snapshot.state = .recording
                snapshot.names = SpeakerNames([0: "田中", 1: "佐藤"])
                snapshot.detectedSpeakerSlots = [0, 1]; snapshot.elapsed = 144
                snapshot.timeline = MeetingTimeline(startedAt: Date().addingTimeInterval(-144))
                snapshot.utterances = (0..<18).map { Utterance(speaker: $0 % 2, start: Double($0 * 8), end: Double($0 * 8 + 6), text: "前回の会議を踏まえて、公開に向けた確認事項を整理します。") }
                value.apply(snapshot); value.show()
                if !value.minutesSplit.isPreviewVisible { value.toggleMinutes() }
                value.window?.setContentSize(NSSize(width: 1800, height: 740))
                value.window?.center(); value.window?.makeKeyAndOrderFront(nil)
                target = value.minutesSplit.preview; views.append(target)
                captureView = value.window!.contentView!
                try await wait { target.document.renderedText.contains("第1回") }
            }
            captureView.layoutSubtreeIfNeeded()
            for (name, history) in [("three", Array(paths.prefix(3))), ("ten", paths), ("missing", [paths[0], missing, paths[1]]), ("empty", [])] {
                defaults.set(history, forKey: MinutesHistoryStore.key)
                try await focus(target)
                try await Task.sleep(for: .milliseconds(100))
                try capture(captureView, name: "history-\(name)-\(width)")
                try require(target.historyPopup.isHidden == history.isEmpty, "空の一覧")
                target.window?.makeFirstResponder(nil)
            }
        }
        controller?.minutesSplit.preview.stop(); controller?.window?.orderOut(nil)
        connect()
        window.makeKeyAndOrderFront(nil)
        defaults.set(Array(paths.prefix(3)), forKey: MinutesHistoryStore.key)
        try await focus(preview)
        try click(preview.historyPopup.rows[1])
        try await wait { preview.document.renderedText.contains("第2回") }
        try require(preview.history.paths == [paths[1], paths[0], paths[2]], "クリック後のMRU")
        log("フォーカス→一覧→クリックで開く: 成功")
        try await focus(preview)
        key(125, "\u{F701}", in: window); key(125, "\u{F701}", in: window)
        key(126, "\u{F700}", in: window)
        key(36, "\r", in: window)
        try await wait { preview.document.renderedText.contains("第1回") }
        log("下矢印・上矢印・Returnで開く: 成功")
        try await focus(preview)
        preview.pathField.stringValue = "/tmp/取消前の下書き.md"
        key(53, "\u{1b}", in: window)
        try require(preview.historyPopup.isHidden && preview.pathField.stringValue == "/tmp/取消前の下書き.md", "Escapeの一覧優先")
        key(53, "\u{1b}", in: window)
        try require(preview.pathField.stringValue == paths[0], "二度目Escapeの取消")
        try await focus(preview); window.makeFirstResponder(preview.document.webView)
        try require(preview.historyPopup.isHidden, "フォーカス移動で閉じる")
        log("Escapeは一覧→下書きの順、欄からフォーカスを外して閉じる: 成功")
        preview.resetContext(); store = MinutesStore(meetingID: UUID(), outputDirectory: output.appendingPathComponent("meetings")); connect()
        try await focus(preview)
        try require(preview.historyPopup.rows.count == 3, "別会議の履歴")
        try click(preview.historyPopup.rows[1])
        try await wait { preview.document.renderedText.contains("第2回") }
        try store.select(paths[2])
        try await wait { preview.history.paths == [paths[2], paths[1], paths[0]] }
        log("別会議でも履歴を選択して開く: 成功。再起動検証用に3件を保存")
    }
    func applicationWillTerminate(_ notification: Notification) { views.forEach { $0.stop() } }
}
#endif
