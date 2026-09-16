#if DEBUG
import AppKit
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
    }
    func applicationWillTerminate(_ notification: Notification) {
        controller?.minutesSplit.preview.stop()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
#endif
