import Darwin
import Foundation
import KikigakiCore

@main struct KikigakiCLI {
    static func main() {
        if CommandLine.arguments.dropFirst() == ["--help"] {
            print("kikigaki-cli accept|reply|notify --session <path> --token <token> [--request <UUID>] [--kind answered|needs_input|failed] [--reason <code>] [--provider codex|claude] [payload-json]")
            print("kikigaki-cli minutes --session <session_path> --request <request_id> --token <request_token> --path <absolute.md>")
            return
        }
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
}
