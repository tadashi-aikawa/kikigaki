import AppKit
import KikigakiCore

/// メニューの「アップデートを確認…」から起動する確認(NSAlert ベース)。
/// 走るのは押したときだけで、起動時・定期の確認はしない。仕様は docs/update-check.md
@MainActor
final class UpdaterFeature {
    /// 確認からアラートを閉じるまで立てる。開発ビルドのアラートを出している間も再入を断る
    private var checking = false
    /// 終了させない理由。結果が出た時点と、終了のボタンを押した時点の2回引く
    private let quitBlocker: () -> UpdateQuitBlocker?

    init(quitBlocker: @escaping () -> UpdateQuitBlocker?) {
        self.quitBlocker = quitBlocker
    }

    func checkForUpdates() {
        guard !checking else { return }
        checking = true
        let currentVersion =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "0.0.0-development"

        Task { @MainActor in
            defer { checking = false }
            let content: UpdateAlertContent
            do {
                let result = try await UpdateChecker.check(currentVersion: currentVersion)
                content = .forResult(
                    result, target: UpdateChecker.target,
                    isInstalledViaHomebrew: UpdateChecker.isInstalledViaHomebrew,
                    quitBlocker: quitBlocker())
            } catch {
                content = .forFailure(
                    errorDescription: error.localizedDescription, target: UpdateChecker.target)
            }
            present(content)
        }
    }

    private func present(_ content: UpdateAlertContent) {
        // クリップボードへ書けなかったら終了せず、同じアラートを出し直す
        while true {
            let alert = NSAlert()
            alert.messageText = content.title
            alert.informativeText = content.message
            alert.alertStyle = content.style == .warning ? .warning : .informational
            if let primary = content.primaryButton {
                alert.addButton(withTitle: primary.title)
                alert.addButton(withTitle: UpdateAlertContent.closeButtonTitle)
            }
            let response = alert.runModal()
            guard let primary = content.primaryButton, response == .alertFirstButtonReturn else { return }

            switch primary.action {
            case .copyCommandAndQuit(let command), .copyCommand(let command):
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(command, forType: .string) else { continue }
                switch primary.action.afterCopy(blocker: quitBlocker(), target: UpdateChecker.target) {
                case .quit:
                    NSApp.terminate(nil)
                case .keepRunning:
                    break
                case .notifyNotQuit(let notice):
                    present(notice)
                }
            case .openURL(let url):
                NSWorkspace.shared.open(url)
            }
            return
        }
    }
}
