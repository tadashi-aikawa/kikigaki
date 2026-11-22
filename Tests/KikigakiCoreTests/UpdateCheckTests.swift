import Foundation
import Testing

@testable import KikigakiCore

private let target = UpdateTarget.kikigaki
private let releasePage = URL(string: "https://github.com/tadashi-aikawa/kikigaki/releases/tag/v1.3.0")!
private let command = "brew update && brew upgrade --cask kikigaki && open -a KIKIGAKI"

private func latestBody(tag: String) -> Data {
    Data(#"{"tag_name": "\#(tag)", "html_url": "\#(releasePage.absoluteString)", "assets": []}"#.utf8)
}

private struct NetworkDown: Error {}

@Suite struct SemanticVersionTests {
    @Test func vの有無を問わず3要素の数値を読む() {
        #expect(SemanticVersion("1.2.3") == SemanticVersion(major: 1, minor: 2, patch: 3))
        #expect(SemanticVersion("v1.2.3") == SemanticVersion(major: 1, minor: 2, patch: 3))
        #expect(SemanticVersion("v1.2.3")?.description == "1.2.3")
    }

    @Test func 開発ビルドや不正な文字列は読まない() {
        for text in ["0.0.0-development", "1.2.3-beta.1", "1.2", "1.2.3.4", "abc", "", "1.x.3"] {
            #expect(SemanticVersion(text) == nil)
        }
    }

    @Test func 要素ごとに数値で比べる() throws {
        let pairs = [("1.0.0", "2.0.0"), ("1.0.0", "1.1.0"), ("1.1.0", "1.1.1"), ("0.9.9", "0.10.0")]
        for (lower, higher) in pairs {
            #expect(try #require(SemanticVersion(lower)) < #require(SemanticVersion(higher)))
        }
        #expect(!(try #require(SemanticVersion("1.2.3")) < #require(SemanticVersion("1.2.3"))))
    }
}

@Suite struct UpdateTargetTests {
    @Test func cask名からrepoとURLとCaskroomとbrewのコマンドを組み立てる() {
        #expect(target.repo == "tadashi-aikawa/kikigaki")
        #expect(target.latestReleaseAPIURL.absoluteString == "https://api.github.com/repos/tadashi-aikawa/kikigaki/releases/latest")
        #expect(target.releasesPageURL.absoluteString == "https://github.com/tadashi-aikawa/kikigaki/releases")
        #expect(target.caskroomPaths == ["/opt/homebrew/Caskroom/kikigaki", "/usr/local/Caskroom/kikigaki"])
        #expect(target.brewUpgradeCommand == command)
    }
}

@Suite struct UpdateCheckLogicTests {
    @Test func 開発ビルドでは取得処理を呼ばない() async throws {
        var fetched = false
        let result = try await UpdateCheckLogic.check(currentVersion: "0.0.0-development") {
            fetched = true
            return (200, latestBody(tag: "v1.3.0"))
        }
        #expect(result == .developmentBuild(currentVersion: "0.0.0-development"))
        #expect(!fetched)
    }

    @Test func 新しいタグならhtml_urlをリリースページにする() async throws {
        let result = try await UpdateCheckLogic.check(currentVersion: "1.2.3") { (200, latestBody(tag: "v1.3.0")) }
        #expect(result == .updateAvailable(
            current: SemanticVersion(major: 1, minor: 2, patch: 3),
            latest: SemanticVersion(major: 1, minor: 3, patch: 0),
            releasePageURL: releasePage))
    }

    @Test func 同じか古いタグなら最新とする() async throws {
        for current in ["1.3.0", "1.10.0"] {
            let result = try await UpdateCheckLogic.check(currentVersion: current) { (200, latestBody(tag: "v1.3.0")) }
            let expected = try #require(SemanticVersion(current))
            #expect(result == .upToDate(current: expected))
        }
    }

    @Test func assetsキーの無い応答も読める() async throws {
        let body = Data(#"{"tag_name": "v1.3.0", "html_url": "\#(releasePage.absoluteString)"}"#.utf8)
        let result = try await UpdateCheckLogic.check(currentVersion: "1.2.3") { (200, body) }
        #expect(result == .updateAvailable(
            current: SemanticVersion(major: 1, minor: 2, patch: 3),
            latest: SemanticVersion(major: 1, minor: 3, patch: 0),
            releasePageURL: releasePage))
    }

    @Test func tag_nameの無い応答は失敗にする() async {
        let body = Data(#"{"html_url": "\#(releasePage.absoluteString)", "assets": []}"#.utf8)
        await #expect(throws: DecodingError.self) {
            try await UpdateCheckLogic.check(currentVersion: "1.2.3") { (200, body) }
        }
    }

    @Test func 二百以外はHTTPステータス付きのAPI失敗にする() async {
        await #expect(throws: UpdateCheckError.apiFailed(statusCode: 403)) {
            try await UpdateCheckLogic.check(currentVersion: "1.2.3") { (403, Data()) }
        }
    }

    @Test func 解釈できないタグは失敗にする() async {
        await #expect(throws: UpdateCheckError.invalidTag("nightly")) {
            try await UpdateCheckLogic.check(currentVersion: "1.2.3") { (200, latestBody(tag: "nightly")) }
        }
    }

    @Test func 取得処理のエラーはそのまま伝える() async {
        await #expect(throws: NetworkDown.self) {
            try await UpdateCheckLogic.check(currentVersion: "1.2.3") { throw NetworkDown() }
        }
    }

    @Test func エラー文() {
        #expect(UpdateCheckError.apiFailed(statusCode: 403).localizedDescription == "GitHub API の呼び出しに失敗しました (HTTP 403)")
        #expect(UpdateCheckError.invalidTag("nightly").localizedDescription == "リリースタグを解釈できませんでした: nightly")
    }
}

@Suite struct UpdateAlertContentTests {
    private let available = UpdateCheckResult.updateAvailable(
        current: SemanticVersion(major: 1, minor: 2, patch: 3),
        latest: SemanticVersion(major: 1, minor: 3, patch: 0),
        releasePageURL: releasePage)
    private let lead = "Homebrew でインストールされているため、以下のコマンドで更新してください。\n\n\(command)\n\n"

    @Test func 開発ビルドは元の文字列をそのまま出す() {
        let content = UpdateAlertContent.forResult(
            .developmentBuild(currentVersion: "0.0.0-development"), target: target,
            isInstalledViaHomebrew: true, quitBlocker: .inProgress)
        #expect(content == UpdateAlertContent(
            title: "開発ビルドです", message: "開発ビルド(0.0.0-development)ではアップデート確認をスキップします。",
            style: .informational, primaryButton: nil))
    }

    @Test func 本文の現在のバージョンはSemVerとして読んだ表記にする() async throws {
        let upToDate = try await UpdateCheckLogic.check(currentVersion: "v1.3.0") { (200, latestBody(tag: "v1.3.0")) }
        #expect(UpdateAlertContent.forResult(upToDate, target: target, isInstalledViaHomebrew: true, quitBlocker: nil)
            == UpdateAlertContent(title: "最新版です", message: "KIKIGAKI v1.3.0 は最新です。", style: .informational, primaryButton: nil))

        let newer = try await UpdateCheckLogic.check(currentVersion: "v1.2.3") { (200, latestBody(tag: "v1.3.0")) }
        let content = UpdateAlertContent.forResult(newer, target: target, isInstalledViaHomebrew: false, quitBlocker: .inProgress)
        #expect(content == UpdateAlertContent(
            title: "v1.3.0 が利用可能です",
            message: "現在のバージョン: 1.2.3\nリリースページから新しいバージョンを入手できます。",
            style: .informational,
            primaryButton: .init(title: "リリースページを開く", action: .openURL(releasePage))))
    }

    @Test func Homebrewで終了させない理由が無ければコピーして終了する() {
        let content = UpdateAlertContent.forResult(available, target: target, isInstalledViaHomebrew: true, quitBlocker: nil)
        #expect(content == UpdateAlertContent(
            title: "v1.3.0 が利用可能です",
            message: lead + "コピーすると KIKIGAKI は終了します(更新完了後に自動で起動します)。",
            style: .informational,
            primaryButton: .init(title: "コマンドをコピーして終了", action: .copyCommandAndQuit(command: command))))
    }

    @Test func Homebrewで録音中ならコピーしても終了しない() {
        let content = UpdateAlertContent.forResult(available, target: target, isInstalledViaHomebrew: true, quitBlocker: .inProgress)
        #expect(content == UpdateAlertContent(
            title: "v1.3.0 が利用可能です",
            message: lead + "録音中のため KIKIGAKI は終了しません。録音を終えてから KIKIGAKI を終了し、コマンドを実行してください。",
            style: .informational,
            primaryButton: .init(title: "コマンドをコピー", action: .copyCommand(command: command))))
    }

    @Test func Homebrewで未保存の書き起こしがあればコピーしても終了しない() {
        let content = UpdateAlertContent.forResult(available, target: target, isInstalledViaHomebrew: true, quitBlocker: .unsavedMeeting)
        #expect(content == UpdateAlertContent(
            title: "v1.3.0 が利用可能です",
            message: lead + "保存できていない書き起こしがあるため KIKIGAKI は終了しません。保存してから KIKIGAKI を終了し、コマンドを実行してください。",
            style: .informational,
            primaryButton: .init(title: "コマンドをコピー", action: .copyCommand(command: command))))
    }

    @Test func 失敗は警告スタイルでリリース一覧へ案内する() {
        let content = UpdateAlertContent.forFailure(errorDescription: "GitHub API の呼び出しに失敗しました (HTTP 500)", target: target)
        #expect(content == UpdateAlertContent(
            title: "アップデートを確認できませんでした",
            message: "GitHub API の呼び出しに失敗しました (HTTP 500)\n\nリリースページで最新のバージョンを確認できます。",
            style: .warning,
            primaryButton: .init(title: "リリースページを開く",
                                 action: .openURL(URL(string: "https://github.com/tadashi-aikawa/kikigaki/releases")!))))
        #expect(UpdateAlertContent.closeButtonTitle == "閉じる")
    }
}

@Suite struct UpdateQuitBlockerTests {
    @Test func 待機中で残すものが無いときだけ終了させる() {
        #expect(UpdateQuitBlocker.current(state: .idle, reviewingFile: false, loadingAudioFile: false, hasUnsavedMeeting: false) == nil)
        for state in [RecordingState.preparing, .recording, .paused, .finishing] {
            #expect(UpdateQuitBlocker.current(state: state, reviewingFile: false, loadingAudioFile: false, hasUnsavedMeeting: false)
                == .inProgress)
        }
    }

    @Test func 音声ファイルの変換中と仕上げ中は待機中でも進行中とみなす() {
        #expect(UpdateQuitBlocker.current(state: .idle, reviewingFile: false, loadingAudioFile: true, hasUnsavedMeeting: false)
            == .inProgress)
        #expect(UpdateQuitBlocker.current(state: .idle, reviewingFile: true, loadingAudioFile: false, hasUnsavedMeeting: false)
            == .inProgress)
    }

    @Test func 保存に失敗した会議が残っていれば未保存とする() {
        #expect(UpdateQuitBlocker.current(state: .idle, reviewingFile: false, loadingAudioFile: false, hasUnsavedMeeting: true)
            == .unsavedMeeting)
        #expect(UpdateQuitBlocker.current(state: .idle, reviewingFile: true, loadingAudioFile: false, hasUnsavedMeeting: true)
            == .unsavedMeeting)
    }

    @Test func 終了のボタンを押した時点で理由があれば終了せずに理由を知らせる() {
        let quit = UpdateAlertContent.Action.copyCommandAndQuit(command: command)
        #expect(quit.afterCopy(blocker: nil, target: target) == .quit)
        #expect(quit.afterCopy(blocker: .inProgress, target: target) == .notifyNotQuit(UpdateAlertContent(
            title: "KIKIGAKI は終了していません",
            message: "録音中のため KIKIGAKI は終了しません。録音を終えてから KIKIGAKI を終了し、コマンドを実行してください。",
            style: .informational, primaryButton: nil)))
        #expect(quit.afterCopy(blocker: .unsavedMeeting, target: target) == .notifyNotQuit(UpdateAlertContent(
            title: "KIKIGAKI は終了していません",
            message: "保存できていない書き起こしがあるため KIKIGAKI は終了しません。保存してから KIKIGAKI を終了し、コマンドを実行してください。",
            style: .informational, primaryButton: nil)))
    }

    @Test func コマンドをコピーだけのボタンは理由によらず終了も通知もしない() {
        for blocker in [nil, UpdateQuitBlocker.inProgress, .unsavedMeeting] {
            #expect(UpdateAlertContent.Action.copyCommand(command: command).afterCopy(blocker: blocker, target: target) == .keepRunning)
        }
    }
}

@Suite struct ConfigTemplateTests {
    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kikigaki-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func 雛形はファイルが無いときと同じ既定の設定になる() throws {
        #expect(try ConfigLoader.parse(toml: DefaultConfigTemplate.text) == KikigakiConfig())
        #expect(DefaultConfigTemplate.text.hasPrefix("#:schema /Applications/KIKIGAKI.app/Contents/Resources/config.schema.json\n"))
    }

    @Test func 無ければ親ディレクトリごと雛形を作り既存のファイルは触らない() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nested/config.toml")
        try ConfigLoader.ensureFileExists(at: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == DefaultConfigTemplate.text)
        #expect(try ConfigLoader.load(from: url) == ConfigLoader.load(from: dir.appendingPathComponent("missing.toml")))

        try "saveRecording = true\n".write(to: url, atomically: true, encoding: .utf8)
        try ConfigLoader.ensureFileExists(at: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "saveRecording = true\n")
    }

    @Test func 確かめた後に別のプロセスが作ったファイルは上書きせずそのまま使う() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.toml")
        try "saveRecording = true\n".write(to: url, atomically: true, encoding: .utf8)
        try ConfigLoader.writeTemplateWithoutOverwriting(at: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "saveRecording = true\n")

        // 既存のリンク先へも書かない
        let linked = dir.appendingPathComponent("linked.toml")
        let target = dir.appendingPathComponent("dotfiles.toml")
        try "outputDir = \"~/Notes\"\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
        try ConfigLoader.writeTemplateWithoutOverwriting(at: linked)
        #expect(try String(contentsOf: target, encoding: .utf8) == "outputDir = \"~/Notes\"\n")
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test func 書き切った雛形だけを置き一時ファイルを残さない() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.toml")
        try ConfigLoader.writeTemplateWithoutOverwriting(at: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == DefaultConfigTemplate.text)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["config.toml"])
    }

    private func leftovers(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".writing-") }
    }

    @Test func リンク先が無いシンボリックリンクは作らずエラーにする() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("config.toml")
        let target = dir.appendingPathComponent("dotfiles/config.toml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: ConfigFileError.brokenSymlink(path: link.path)) { try ConfigLoader.ensureFileExists(at: link) }
        // 確かめた後にリンクが作られた場合も同じエラーにし、リンク先を作らない
        #expect(throws: ConfigFileError.brokenSymlink(path: link.path)) { try ConfigLoader.writeTemplateWithoutOverwriting(at: link) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try leftovers(in: dir).isEmpty)
        #expect(ConfigFileError.brokenSymlink(path: "/x").localizedDescription == "設定ファイルのシンボリックリンクのリンク先がありません: /x")
    }
}
