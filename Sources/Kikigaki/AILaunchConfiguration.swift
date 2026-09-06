import Foundation
import KikigakiCore

struct AILaunchConfiguration {
    let executable: URL
    let arguments: [String]
    @MainActor init(config: ResolvedAIConfig, helper: URL, controller: AIConversationController) throws {
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
        if config.cli == .codex {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
            args += ["-c", "notify=" + String(decoding: try encoder.encode(notify), as: UTF8.self)]
        } else {
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
