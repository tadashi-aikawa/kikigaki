#if DEBUG
import AppKit
import CoreGraphics
import KikigakiCore

/// 標準ツールチップはOSのイベントループで出るため、swift testとは別プロセスで検証する。
/// 音声・AI・利用者の設定や会議データは使わない。
@MainActor final class PromptHintHoverCheck: NSObject, NSApplicationDelegate {
    private let root: URL
    private var controller: TranscriptWindowController?
    init(output: String) { root = URL(fileURLWithPath: output).standardizedFileURL }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard root.path.hasPrefix("/tmp/") || root.path.hasPrefix("/private/tmp/") else { exit(1) }
        Task {
            do { try await run(); exit(0) }
            catch { print("HOVER FAILED: \(error)"); exit(1) }
        }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "PromptHintHover", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    private func move(_ point: NSPoint) {
        let quartz = CGPoint(x: point.x, y: NSScreen.screens[0].frame.maxY - point.y)
        CGWarpMouseCursorPosition(quartz)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: quartz,
                mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    private var tooltip: NSWindow? {
        // 公開APIで表示窓を列挙する。OSの内部クラス名は検証時の識別にだけ使う。
        NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("ToolTipPanel") }
    }
    private func run() async throws {
        guard let screen = NSScreen.main else { throw CocoaError(.featureUnsupported) }
        let originalMouse = NSEvent.mouseLocation
        defer { move(originalMouse) }
        let suite = "PromptHintHoverCheck.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prompt = (1...24).map {
            "\($0)行目: 必ず日本語で返してください。結論を先にしてください。担当と期限を確認してください。"
        }.joined(separator: "\n")
        let profile = ResolvedAIConfig(config: AIConfig(name: "検証用", command: "/bin/echo", cwd: root.path,
            alwaysPrompt: prompt, initialPrompt: "会話をまとめてください", autoStart: true), home: root, slot: 1)
        let controller = TranscriptWindowController(shouldReduceMotion: { true }, minutesDefaults: defaults, textDefaults: defaults)
        self.controller = controller
        let parent = controller.window!
        parent.setFrameAutosaveName("")
        parent.setFrame(NSRect(x: screen.visibleFrame.minX + 80, y: screen.visibleFrame.minY + 40,
            width: 800, height: min(900, screen.visibleFrame.height - 80)), display: true)
        parent.orderFront(nil)
        defer { parent.orderOut(nil) }
        let start = StartSheet(profiles: [profile], diarizationEnabled: false, exclusion: AudioExclusion(),
            defaults: defaults, microphoneName: { "検証用マイク" })
        let manual = AIQuestionSheet(participant: "検証用", parentNumber: nil, draft: "", voice: "",
            range: "", tentative: false, canSubmit: true, alwaysPrompt: prompt)
        let automatic = AIScheduleSheet(prompt: "会話をまとめてください", minutes: 5,
            workAllowed: false, participant: "検証用", alwaysPrompt: prompt)
        defer { start.close(); manual.close(); automatic.close() }
        let cases: [(String, NSWindow, AIAlwaysPromptHint, () -> Void, () -> Void)] = [
            ("start-automatic", start.window, start.alwaysPromptHint, { start.present(on: parent) }, { start.close() }),
            ("start-manual", start.window, start.manualAlwaysPromptHint, { start.present(on: parent) }, { start.close() }),
            ("manual", manual.window, manual.alwaysPromptHint, { manual.present(on: parent) }, { manual.close() }),
            ("automatic", automatic.window, automatic.alwaysPromptHint, { automatic.present(on: parent) }, { automatic.close() }),
        ]
        let outside = NSPoint(x: screen.visibleFrame.minX + 5, y: screen.visibleFrame.minY + 5)
        let baseline = ProcessInfo.processInfo.environment["KIKIGAKI_PROMPT_HINT_HOVER_BASELINE"] == "1"
        for (name, window, hint, present, close) in cases {
            try require(window.allowsToolTipsWhenApplicationIsInactive, "\(name): 非アクティブ時の表示許可")
            // 修正前の窓は別プロセスで表示する。表示中の切替による追跡領域の
            // 更新タイミングを、実際の初期表示の検証へ混ぜない。
            if baseline { window.allowsToolTipsWhenApplicationIsInactive = false }
            present()
            try await Task.sleep(for: .milliseconds(600))
            window.contentView?.layoutSubtreeIfNeeded()
            hint.scrollToVisible(hint.bounds)
            NSApp.deactivate()
            move(outside)
            try await Task.sleep(for: .milliseconds(600))
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(200))
            let point = window.convertPoint(toScreen: hint.convert(NSPoint(x: 30, y: hint.bounds.midY), to: nil))
            move(point)
            try await Task.sleep(for: .seconds(3))
            try require(!NSApp.isActive && !window.isKeyWindow, "\(name): 非アクティブ・非キー")
            if baseline {
                try require(tooltip == nil, "\(name): 修正前は表示しない")
                print("NO-HOVER \(name) active=false key=false")
                move(outside); close()
                window.allowsToolTipsWhenApplicationIsInactive = true
                try await Task.sleep(for: .milliseconds(600))
                continue
            }
            try require(!NSApp.isActive && !window.isKeyWindow, "\(name): 表示で焦点を奪わない")
            try require(hint.toolTip == prompt && hint.label.toolTip == prompt, "\(name): 全文を登録")
            guard let tooltip else { throw NSError(domain: "PromptHintHover", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(name): 標準ツールチップが出ない"]) }
            try require(screen.visibleFrame.contains(tooltip.frame), "\(name): 全文の窓が画面内へ収まる")
            print("HOVER \(name) active=false key=false tooltip=\(tooltip.frame) chars=\(prompt.count)")
            if let directory = ProcessInfo.processInfo.environment["KIKIGAKI_PROMPT_HINT_CAPTURE"] {
                let output = URL(fileURLWithPath: directory).standardizedFileURL
                try require(output.path.hasPrefix("/tmp/") || output.path.hasPrefix("/private/tmp/"), "撮影先は/tmp配下だけ")
                guard let content = tooltip.contentView,
                      let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw CocoaError(.coderInvalidValue) }
                content.cacheDisplay(in: content.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.coderInvalidValue) }
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try data.write(to: output.appendingPathComponent(name + "-hover.png"))
            }
            move(outside)
            close()
            try await Task.sleep(for: .milliseconds(600))
        }
    }
}
#endif
