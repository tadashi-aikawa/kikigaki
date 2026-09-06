import Darwin
import Foundation

struct AIProcessOutput: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

enum AIProcessError: Error {
    case executableNotFound(String), timeout, outputLimit, commandFailed(Int32), invalidResponse
}

/// Processを所有するworkerだけが終了させる。会話・トークン入りargvはログに出さない。
struct AIProcessRunner: Sendable {
    static func environment(_ source: [String: String]) -> [String: String] {
        source.filter { !$0.key.hasPrefix("HERDR_") }
    }

    static func executable(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let fm = FileManager.default
        if name.hasPrefix("/"), fm.isExecutableFile(atPath: name) { return URL(fileURLWithPath: name) }
        if !name.contains("/") {
            for directory in (environment["PATH"] ?? "").split(separator: ":") where directory.hasPrefix("/") {
                let url = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: url.path) { return url }
            }
        }
        throw AIProcessError.executableNotFound(name)
    }

    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 15,
             environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> AIProcessOutput {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let process = Process(), out = Pipe(), err = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = Self.environment(environment)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = out; process.standardError = err
            try process.run()
            out.fileHandleForWriting.closeFile(); err.fileHandleForWriting.closeFile()
            defer { out.fileHandleForReading.closeFile(); err.fileHandleForReading.closeFile() }
            let fds = [out.fileHandleForReading.fileDescriptor, err.fileHandleForReading.fileDescriptor]
            for fd in fds { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
            var data = [Data(), Data()]
            var buffer = [UInt8](repeating: 0, count: 8192)
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var failure: Error?
            var killAt: TimeInterval?
            while true {
                let ended = !process.isRunning
                for index in 0...1 {
                    while true {
                        let count = read(fds[index], &buffer, buffer.count)
                        if count <= 0 { break }
                        if data[index].count + count <= 1_048_576 { data[index].append(contentsOf: buffer.prefix(count)) }
                        else { failure = AIProcessError.outputLimit; break }
                    }
                }
                if ended { break }
                let now = ProcessInfo.processInfo.systemUptime
                if Task.isCancelled { failure = CancellationError() }
                if now >= deadline { failure = AIProcessError.timeout }
                if failure != nil, killAt == nil {
                    process.terminate(); killAt = now + 0.25
                }
                if let killAt, now >= killAt { kill(process.processIdentifier, SIGKILL) }
                usleep(10_000)
            }
            process.waitUntilExit()
            if let failure { throw failure }
            return AIProcessOutput(status: process.terminationStatus, stdout: data[0], stderr: data[1])
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}

/// pane runとClaude command hookだけがシェル文字列を要求する。
/// 各引数をsingle quoteし、本文は常に別のagent prompt引数へ渡す。
enum AIShell {
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func command(_ arguments: [String]) -> String { arguments.map(quote).joined(separator: " ") }
}
