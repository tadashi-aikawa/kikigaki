import Darwin
import Foundation

struct AIProcessOutput: Sendable { let status: Int32; let stdout: Data; let stderr: Data }
enum AIProcessError: Error, Equatable {
    case executableNotFound(String), invalidInput, timeout, outputLimit, io, invalidResponse
}

/// 両pipeを有限回ずつ読み、出力継続中も期限と取消を観測する。
struct AIProcessRunner: Sendable {
    static func environment(_ values: [String: String]) -> [String: String] {
        values.filter { !$0.key.hasPrefix("HERDR_") }
    }
    static func executable(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let candidates: [String]
        if name.hasPrefix("/") { candidates = [name] }
        else if !name.isEmpty && !name.contains("/") {
            candidates = (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { String($0) + "/" + name }
        } else { candidates = [] }
        for path in candidates where !path.contains("\0") {
            var info = stat()
            if stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, access(path, X_OK) == 0 { return URL(fileURLWithPath: path) }
        }
        throw AIProcessError.executableNotFound(name)
    }
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 15,
             environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> AIProcessOutput {
        guard executable.isFileURL, executable.path.hasPrefix("/"), timeout.isFinite, timeout > 0,
              !arguments.contains(where: { $0.contains("\0") }) else { throw AIProcessError.invalidInput }
        let worker = Task.detached(priority: .utility) { try Self.execute(executable, arguments, timeout, Self.environment(environment)) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    private static func execute(_ executable: URL, _ arguments: [String], _ timeout: TimeInterval,
                                _ environment: [String: String]) throws -> AIProcessOutput {
        try Task.checkCancellation()
        let output = Pipe(), errors = Pipe(), child = Process()
        let handles = [output.fileHandleForReading, errors.fileHandleForReading]
        defer { handles.forEach { $0.closeFile() }; output.fileHandleForWriting.closeFile(); errors.fileHandleForWriting.closeFile() }
        for handle in handles {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw AIProcessError.io }
        }
        child.executableURL = executable; child.arguments = arguments; child.environment = environment
        child.standardInput = FileHandle.nullDevice; child.standardOutput = output; child.standardError = errors
        try child.run()
        output.fileHandleForWriting.closeFile(); errors.fileHandleForWriting.closeFile()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var bytes = [Data(), Data()], failure: Error?, terminateAt: TimeInterval?, killed = false
        var eof = [false, false], buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let ended = !child.isRunning
            var obtained = false
            for index in handles.indices where !eof[index] {
                for _ in 0..<8 {
                    let count = read(handles[index].fileDescriptor, &buffer, buffer.count)
                    if count == 0 { eof[index] = true; break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        if errno != EAGAIN && errno != EWOULDBLOCK { failure = failure ?? AIProcessError.io }
                        break
                    }
                    obtained = true
                    if bytes[index].count + count <= 1_048_576 { bytes[index].append(contentsOf: buffer.prefix(count)) }
                    else { failure = failure ?? AIProcessError.outputLimit; break }
                }
            }
            // 子が終了した後は、孫に残ったpipeのEOFを待ち続けない。
            if ended && (!obtained || failure != nil) { break }
            let now = ProcessInfo.processInfo.systemUptime
            if failure == nil, Task.isCancelled { failure = CancellationError() }
            if failure == nil, now >= deadline { failure = AIProcessError.timeout }
            if !ended, failure != nil {
                if terminateAt == nil { child.terminate(); terminateAt = now + 0.25 }
                if !killed, let terminateAt, now >= terminateAt, child.isRunning {
                    _ = kill(child.processIdentifier, SIGKILL); killed = true
                }
            }
            usleep(5_000)
        }
        child.waitUntilExit()
        if let failure { throw failure }
        return AIProcessOutput(status: child.terminationStatus, stdout: bytes[0], stderr: bytes[1])
    }
}
enum AIShell {
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func command(_ arguments: [String]) -> String { arguments.map(quote).joined(separator: " ") }
}
