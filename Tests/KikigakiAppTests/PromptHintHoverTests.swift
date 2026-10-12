import Foundation
import Testing

/// 実カーソルを動かすため、他のUIテストと同時には実行しない。
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KIKIGAKI_PROMPT_HINT_HOVER"] == "1"))
struct PromptHintHoverTests {
    @Test func 四か所の標準ツールチップを非アクティブでも全文表示する() async throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/Kikigaki")
        for baseline in [true, false] {
            let process = Process()
            process.executableURL = binary
            var environment = ProcessInfo.processInfo.environment
            environment["KIKIGAKI_PROMPT_HINT_HOVER_OUTPUT"] = root.path
            environment["KIKIGAKI_PROMPT_HINT_HOVER_BASELINE"] = baseline ? "1" : "0"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            for _ in 0..<3000 {
                if !process.isRunning { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!process.isRunning, "実カーソル検証は60秒以内に終了する")
            let report = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            print(report)
            try #require(process.terminationStatus == 0, "\(report)")
            let lines = report.components(separatedBy: "\n")
            for name in ["start-automatic", "start-manual", "manual", "automatic"] {
                let prefix = baseline ? "NO-HOVER" : "HOVER"
                #expect(lines.contains { $0.hasPrefix("\(prefix) \(name) active=false key=false") })
            }
        }
    }
}
