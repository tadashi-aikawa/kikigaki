#if DEBUG
import AppKit
import WebKit
import KikigakiCore

/// マイク・モデル・AIを起動せず、署名済み.appの議事録UIを検証する。
@MainActor final class MinutesPreviewHarness: NSObject, NSApplicationDelegate {
    private let path: String
    private var controller: TranscriptWindowController?
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("kikigaki-preview-" + UUID().uuidString)
    private let suite = "kikigaki-preview-" + UUID().uuidString
    init(path: String) { self.path = path }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = ApplicationMenu.make()
        let defaults = UserDefaults(suiteName: suite)!
        let controller = TranscriptWindowController(minutesDefaults: defaults)
        self.controller = controller
        controller.window?.setFrameAutosaveName("")
        controller.window?.title = "KIKIGAKI 議事録プレビュー検証"
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { FileHandle.standardError.write(Data("preview directory: \(error)\n".utf8)); NSApp.terminate(nil); return }
        let store = MinutesStore(meetingID: UUID(), outputDirectory: root)
        controller.connectMinutes(store)
        controller.onSelectMinutes = { try store.select($0) }
        do { try store.select(path) }
        catch { FileHandle.standardError.write(Data("preview: \(error)\n".utf8)) }
        if let heading = ProcessInfo.processInfo.environment["KIKIGAKI_DEBUG_BOARD_HEADING"] {
            do { try store.bindBoard(heading) }
            catch { FileHandle.standardError.write(Data("board preview: \(error)\n".utf8)) }
        }
        var snapshot = SessionSnapshot()
        if CommandLine.arguments.contains("--preview-warning") {
            snapshot.aiRecoveryWarning = "検証用の警告: AIセッションを復元できませんでした。接続先を確認してください。"
        }
        controller.apply(snapshot)
        controller.show()
        if !controller.minutesSplit.isPreviewVisible { controller.toggleMinutes() }
        controller.window?.setContentSize(NSSize(width: 1500, height: 900))
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)
        if let output = ProcessInfo.processInfo.environment["KIKIGAKI_DEBUG_BOARD_CAPTURE"] {
            Task { do { try await captureBoard(output: URL(fileURLWithPath: output)) }
                catch { FileHandle.standardError.write(Data("board capture: \(error)\n".utf8)) }
                NSApp.terminate(nil)
            }
        }
    }
    private func captureBoard(output: URL) async throws {
        guard let preview = controller?.minutesSplit.preview else { return }
        for _ in 0..<500 {
            if !preview.boardDocument.renderedText.isEmpty && !preview.minutesDocument.renderedText.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard !preview.boardDocument.renderedText.isEmpty else { throw AIError.invalid("ボードの描画が完了しません") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (board, name) in [(false, "minutes"), (true, "board")] {
            preview.selectBoard(board); preview.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            guard let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) else { throw AIError.invalid("capture") }
            preview.cacheDisplay(in: preview.bounds, to: bitmap)
            let webImage = try await preview.document.webView.takeSnapshot(configuration: WKSnapshotConfiguration())
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            webImage.draw(in: preview.convert(preview.document.bounds, from: preview.document))
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        controller?.minutesSplit.preview.stop()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
#endif
