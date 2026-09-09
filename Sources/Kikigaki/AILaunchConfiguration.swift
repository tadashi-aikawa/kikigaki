import Foundation
import KikigakiCore
import KikigakiAIIO

struct AILaunchConfiguration {
    let executable: URL
    let arguments: [String]
    @MainActor init(config: ResolvedAIConfig, helper: URL, controller: AIConversationController,
                    codexConfigURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")) throws {
        executable = try AIProcessRunner.executable(config.command ?? config.cli.rawValue)
        _ = try AIProcessRunner.executable(helper.path)
        let defaultCWD = ResolvedAIConfig(config: AIConfig(), home: FileManager.default.homeDirectoryForCurrentUser).cwd
        if config.cwd == defaultCWD { try FileManager.default.createDirectory(at: config.cwd, withIntermediateDirectories: true) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: config.cwd.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let token = controller.sessionToken else { throw AIError.invalid("AI launch configuration") }
        let notify = [helper.path, "notify", "--provider", config.cli.rawValue, "--session", controller.sessionURL.path, "--token", token]
        var args: [String] = []
        if let model = config.model { args += [config.cli == .codex ? "-m" : "--model", model] }
        // 専用キーの effort をCLIごとの引数へ翻訳する。extraArgs との二重指定は設定検証で拒否済み。
        args += config.effortArguments
        if config.cli == .codex {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
            args += ["-c", "notify=" + String(decoding: try encoder.encode(notify), as: UTF8.self)]
            // Codexの workspace-write サンドボックスは cwd と writable_roots 以外へ書けない。同梱CLIが返送を
            // 保存する会議の `ai/` を許可先へ足す(実測: 保存先が ~/Documents だと unsafe_file で返送に失敗した)。
            // `-c` は同じキーを置き換えるため、利用者の設定にある許可先を先に写して失わない。
            let aiDirectory = controller.sessionURL.deletingLastPathComponent().deletingLastPathComponent().path
            var roots = CodexUserConfig.writableRoots(at: codexConfigURL)
            if !roots.contains(aiDirectory) { roots.append(aiDirectory) }
            args += ["-c", "sandbox_workspace_write.writable_roots=" + String(decoding: try encoder.encode(roots), as: UTF8.self)]
        } else {
            // allow規則の構文として解釈される文字を含む配置先は、権限を広げず拒否する。
            guard !helper.path.contains(where: { "*?()\n\r".contains($0) }) else { throw AIError.invalid("helper permission path") }
            let settings: [String: Any] = [
                "permissions": ["allow": ["Bash(\(helper.path) *)"]],
                "hooks": ["Stop": [["hooks": [["type": "command", "command": AIShell.command(notify), "timeout": 10]]]]]
            ]
            let name = "\(controller.generation).settings.json"
            let base = [".kikigaki-context", controller.meetingID.uuidString, "ai", "sessions"]
            let files = AIFileStore(root: controller.outputDirectory)
            try files.write(JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), to: base + [name])
            args += ["--settings", (base + [name]).reduce(controller.outputDirectory) { $0.appendingPathComponent($1) }.path]
        }
        arguments = args + config.extraArgs
    }
}
