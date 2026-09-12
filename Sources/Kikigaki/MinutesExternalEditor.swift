import AppKit

enum MinutesEditorError: LocalizedError {
    case missing, failed(String)
    var errorDescription: String? {
        switch self {
        case .missing: return "対象ファイルがありません。保存されてから開いてください"
        case .failed(let message): return message
        }
    }
}

/// AI起動とは別の、人がボタンを押したファイル1件だけの導線。
struct MinutesExternalEditor {
    typealias Run = @Sendable ([String]) async throws -> AIProcessOutput
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func command(path: String, executable: String) throws -> String {
        guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MinutesEditorError.failed("制御文字を含むパスは開けません")
        }
        return shellQuote(executable) + " -- " + shellQuote(path)
    }
    static func obsidianURL(path: String) -> URL {
        var components = URLComponents(); components.scheme = "obsidian"; components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url!
    }
    static func existingFile(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path)
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { throw MinutesEditorError.missing }
        return url
    }
    static func openNeovim(path: String, herdrCommand: String? = nil) async throws {
        let file = try existingFile(path)
        let executable = try AIProcessRunner.executable("nvim")
        let herdr = try AIProcessRunner.executable(herdrCommand ?? "herdr")
        try await launch(path: file.path, executable: executable.path, run: {
            try await AIProcessRunner().run(herdr, $0)
        })
        _ = await MainActor.run {
            // herdrは端末内のアプリ。既存のparliamentと同じくGhosttyを前面化する。
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").first?.activate()
        }
    }
    static func launch(path: String, executable: String, run: Run) async throws {
        struct Reply<T: Decodable>: Decodable { let result: T }
        struct Workspace: Decodable { let workspace_id: String; let focused: Bool }
        struct Workspaces: Decodable { let workspaces: [Workspace] }
        struct Pane: Decodable { let pane_id: String }
        struct Created: Decodable { let root_pane: Pane }
        let command = try command(path: path, executable: executable)
        let list = try await run(["workspace", "list"])
        guard list.status == 0,
              let spaces = try? JSONDecoder().decode(Reply<Workspaces>.self, from: list.stdout),
              spaces.result.workspaces.filter(\.focused).count == 1,
              let workspace = spaces.result.workspaces.first(where: \.focused) else {
            throw MinutesEditorError.failed("herdrのワークスペースを選択してから開いてください")
        }
        let tab = try await run(["tab", "create", "--workspace", workspace.workspace_id,
            "--cwd", URL(fileURLWithPath: path).deletingLastPathComponent().path, "--label", "議事録", "--focus"])
        guard tab.status == 0, let created = try? JSONDecoder().decode(Reply<Created>.self, from: tab.stdout) else {
            throw MinutesEditorError.failed("herdrのタブを作成できません")
        }
        let started = try await run(["pane", "run", created.result.root_pane.pane_id, command])
        guard started.status == 0 else {
            throw MinutesEditorError.failed("Neovimを起動できません。作成済みのherdrタブを確認してください")
        }
    }
}
