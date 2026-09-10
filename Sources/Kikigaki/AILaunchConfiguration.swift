import Foundation
import KikigakiCore
import KikigakiAIIO

struct AILaunchConfiguration {
    let executable: URL
    let arguments: [String]
    @MainActor init(config: ResolvedAIConfig, helper: URL, controller: AIConversationController,
                    codexConfigURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")) throws {
        guard let token = controller.sessionToken(slot: config.slot) else { throw AIError.invalid("AI launch configuration") }
        try self.init(config: config, helper: helper, outputDirectory: controller.outputDirectory,
                      meetingID: controller.meetingID, sessionURL: controller.sessionURL(slot: config.slot),
                      generation: controller.generation(slot: config.slot), token: token,
                      codexConfigURL: codexConfigURL)
    }

    /// 会議のcontrollerを持たない起動にも同じ引数を組ませる。準備済みセッションは
    /// まだどの会議のものでもないので、仮の会議IDで作った置き場を使う。
    /// - Parameter contextWide: Codexの書き込み許可を保存先の `.kikigaki-context` 全体にする。
    ///   準備済みセッションは紐づけ先の会議が決まっておらず、起動引数は後から変えられないため。
    init(config: ResolvedAIConfig, helper: URL, outputDirectory: URL, meetingID: UUID,
         sessionURL: URL, generation: Int, token: String, contextWide: Bool = false,
         codexConfigURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")) throws {
        executable = try AIProcessRunner.executable(config.command ?? config.cli.rawValue)
        _ = try AIProcessRunner.executable(helper.path)
        let defaultCWD = ResolvedAIConfig(config: AIConfig(), home: FileManager.default.homeDirectoryForCurrentUser).cwd
        if config.cwd == defaultCWD { try FileManager.default.createDirectory(at: config.cwd, withIntermediateDirectories: true) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: config.cwd.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw AIError.invalid("AI launch configuration") }
        let notify = [helper.path, "notify", "--provider", config.cli.rawValue, "--session", sessionURL.path, "--token", token]
        var args: [String] = []
        if let model = config.model { args += [config.cli == .codex ? "-m" : "--model", model] }
        // 専用キーの effort をCLIごとの引数へ翻訳する。extraArgs との二重指定は設定検証で拒否済み。
        args += config.effortArguments
        if config.cli == .codex {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
            args += ["-c", "notify=" + String(decoding: try encoder.encode(notify), as: UTF8.self)]
            // 更新プロンプトで会議への依頼が止まらないよう、この起動だけ確認を抑止する。
            args += ["-c", "check_for_update_on_startup=false"]
            // Codexの workspace-write サンドボックスは cwd と writable_roots 以外へ書けない。同梱CLIが返送を
            // 保存する会議の `ai/` を許可先へ足す(実測: 保存先が ~/Documents だと unsafe_file で返送に失敗した)。
            // `-c` は同じキーを置き換えるため、利用者の設定にある許可先を先に写して失わない。
            // 準備済みセッションはどの会議へ紐づくかまだ決まっておらず、起動後に引数を変えられない。
            // 保存先は設定で固定なので、その中の `.kikigaki-context` 全体を許可先にする。
            // 会議ごとの枝より広いが、同じ利用者の保存先の中に閉じる。
            let context = outputDirectory.appendingPathComponent(".kikigaki-context")
            let aiDirectory = contextWide ? context.path
                : context.appendingPathComponent(meetingID.uuidString).appendingPathComponent("ai").path
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
            // 設定ファイルはsession recordの隣へ置く。プロファイルを分けた会議では枝の中になる。
            let components: [String] = sessionURL.deletingLastPathComponent().pathComponents
            let parts = Array(components.drop(while: { $0 != ".kikigaki-context" })) + ["\(generation).settings.json"]
            let files = AIFileStore(root: outputDirectory)
            try files.write(JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), to: parts)
            args += ["--settings", parts.reduce(outputDirectory) { $0.appendingPathComponent($1) }.path]
        }
        arguments = args + config.extraArgs
    }
}
