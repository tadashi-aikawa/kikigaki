import Foundation
import Testing

@Suite struct TapUpdateTests {
    @Test(arguments: ["", "clone", "push"])
    func tap更新は認証をURLへ残さず成功失敗とも一時領域を消す(_ failure: String) throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("tap update " + UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let scripts = root.appendingPathComponent("scripts"), bin = root.appendingPathComponent("bin")
        let temp = root.appendingPathComponent("tmp")
        for directory in [scripts, bin, temp, root.appendingPathComponent("dist")] {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["update_tap.sh", "render_cask.sh"] {
            try files.copyItem(at: repository.appendingPathComponent("scripts/" + name), to: scripts.appendingPathComponent(name))
        }
        try Data("archive".utf8).write(to: root.appendingPathComponent("dist/KIKIGAKI-0.0.0.zip"))
        let git = bin.appendingPathComponent("git")
        // 実際のclone・pushをせず、Gitへ渡す引数とaskpassの実行を検証する。
        try Data(#"""
        #!/usr/bin/env bash
        set -euo pipefail
        printf '%s\n' "$*" >> "$TRACE"
        [[ "$*" != *"$TAP_GITHUB_TOKEN"* ]]
        if [[ "$1" == -c ]]; then
          [[ "$2" == credential.helper= ]]
          shift 2
        fi
        case "$1" in
          clone)
            [[ "$2" == https://github.com/tadashi-aikawa/homebrew-tap.git ]]
            [[ "$GIT_TERMINAL_PROMPT" == 0 ]]
            [[ "$("$GIT_ASKPASS" "Username for '$2':")" == x-access-token ]]
            [[ "$("$GIT_ASKPASS" "Password for '$2':")" == "$TAP_GITHUB_TOKEN" ]]
            ! grep -Fq "$TAP_GITHUB_TOKEN" "$GIT_ASKPASS"
            mkdir -p "$3/.git"
            printf '[remote "origin"]\nurl = %s\n' "$2" > "$3/.git/config"
            ;;
          push) ! grep -Fq "$TAP_GITHUB_TOKEN" .git/config ;;
        esac
        if [[ "$1" == "$FAIL_AT" ]]; then exit 23; fi
        """#.utf8).write(to: git)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: git.path)
        let trace = root.appendingPathComponent("trace")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scripts.appendingPathComponent("update_tap.sh").path, "0.0.0"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = bin.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["TMPDIR"] = temp.path; env["TAP_GITHUB_TOKEN"] = "dummy"
        env["TRACE"] = trace.path; env["FAIL_AT"] = failure
        process.environment = env
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run()
        let log = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == (failure.isEmpty ? 0 : 23), "\(String(decoding: log, as: UTF8.self))")
        #expect(try files.contentsOfDirectory(atPath: temp.path).isEmpty)
        let arguments = try String(contentsOf: trace, encoding: .utf8)
        #expect(!arguments.contains("dummy"))
        #expect(arguments.contains("-c credential.helper= clone https://github.com/"))
        if failure != "clone" { #expect(arguments.contains("-c credential.helper= push")) }
    }
}
