import Darwin
import Foundation
import KikigakiCore

@main struct KikigakiCLI {
    static func main() {
        if CommandLine.arguments.dropFirst() == ["--help"] {
            print("kikigaki-cli accept|reply|notify --session <path> --token <token> [--request <UUID>] [--kind answered|needs_input|failed] [--reason <code>] [--provider codex|claude] [payload-json]")
            print("kikigaki-cli minutes --session <session_path> --request <request_id> --token <request_token> --path <absolute.md>")
            print("kikigaki-cli progress --session <session_path> --request <request_id> --token <request_token> --editing [--total <1-999>]")
            print("kikigaki-cli skill install|uninstall")
            return
        }
        if CommandLine.arguments.dropFirst().first == "skill" { runSkill(); return }
        do {
            let command = try ReturnCommand(Array(CommandLine.arguments.dropFirst()))
            let id = try command.execute(input: {
                var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
                let limit = command.action == "reply" ? AILimits.bodyBytes : AILimits.eventBytes
                while true {
                    let size = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                    if size < 0, errno == EINTR { continue }
                    guard size >= 0 else { throw AIError.unsafeFile }
                    if size == 0 { return data }
                    guard size <= limit - data.count else { throw AIError.tooLarge }
                    data.append(contentsOf: buffer.prefix(size))
                }
            })
            let reply = try JSONEncoder().encode(["event_id": id])
            FileHandle.standardOutput.write(reply + Data([10]))
        } catch {
            // 引数・本文・パス・トークンを例外の説明文から漏らさない。
            let reason: String
            switch error {
            case MinutesCommandError.invalidPath: reason = "invalid_path"
            case AIError.tooLarge: reason = "size_limit"
            case AIError.conflict: reason = "conflict"
            case AIError.mismatch: reason = "mismatch"
            case AIError.unsafeFile: reason = "unsafe_file"
            default: reason = "invalid_input_or_unavailable_file"
            }
            FileHandle.standardError.write(Data(("kikigaki-cli: " + reason + "\n").utf8))
            exit(1)
        }
    }

    /// 返送系と違い利用者が端末で打つコマンドなので、結果は人が読む文で出す。
    static func runSkill() {
        do {
            let command = try SkillCommand(Array(CommandLine.arguments.dropFirst()))
            let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            let source = try SkillCommand.bundledSkill(executable: executable)
            // 案内に書く ~ と同じ場所を指すよう、シェルと同じくHOMEを優先する。
            let home = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
                ?? FileManager.default.homeDirectoryForCurrentUser
            let results = try command.execute(home: home, source: source)
            for (path, outcome) in results { print("\(path): \(SkillCommand.message(outcome))") }
            if command.action == .install, results.contains(where: { $0.outcome == .skipped }) {
                print("同梱版へ切り替える場合は、そのファイルを削除してから再実行してください。")
            }
        } catch SkillCommand.Failure.arguments {
            FileHandle.standardError.write(Data("kikigaki-cli: usage: kikigaki-cli skill install|uninstall\n".utf8))
            exit(1)
        } catch SkillCommand.Failure.bundledSkillNotFound {
            FileHandle.standardError.write(Data("kikigaki-cli: KIKIGAKI.app/Contents/Helpers の kikigaki-cli から実行してください\n".utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("kikigaki-cli: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
