import Foundation
import KikigakiCore

enum AIConfirmationWait {
    /// 完了は音声位置の確定で決める。時計は待ちの上限だけに使い、一時停止中も進む。
    @MainActor static func capture(maximumWait: TimeInterval = 3,
        latest: () async throws -> AICapture, progress: (Int) -> Void) async throws -> AICapture {
        guard maximumWait.isFinite, maximumWait >= 0 else { throw AIError.invalid("confirmation timeout") }
        let deadline = ProcessInfo.processInfo.systemUptime + maximumWait
        repeat {
            try Task.checkCancellation()
            let value = try await latest()
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if !value.needsConfirmation || remaining <= 0 { return value }
            progress(max(1, Int(ceil(remaining))))
            try await Task.sleep(for: .seconds(min(0.1, remaining)))
        } while true
    }
}
