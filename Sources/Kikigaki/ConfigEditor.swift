import AppKit
import KikigakiCore

/// メニューの「設定ファイルを開く」。JINRAIの `ConfigLoader.openInEditor()` と同じ挙動
@MainActor
enum ConfigEditor {
    /// 設定ファイルをエディタで開く。無ければ雛形を作る。
    /// .toml を開くアプリが無いか開けなければテキストエディットで開く
    static func open(_ url: URL) {
        do {
            try ConfigLoader.ensureFileExists(at: url)
        } catch {
            showOpenError(error.localizedDescription)
            return
        }
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil, NSWorkspace.shared.open(url) {
            return
        }
        guard
            let textEdit = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.TextEdit")
        else {
            showOpenError(url.path)
            return
        }
        NSWorkspace.shared.open(
            [url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            guard let error else { return }
            Task { @MainActor in showOpenError("\(error.localizedDescription)\n\n\(url.path)") }
        }
    }

    private static func showOpenError(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = "設定ファイルを開けません"
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}
