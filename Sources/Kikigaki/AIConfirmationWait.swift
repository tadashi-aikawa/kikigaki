import Foundation
import KikigakiCore

enum AIConfirmationWait {
    /// 完了は音声位置の確定で決める。時計は待ちの上限だけに使い、一時停止中も進む。
    @MainActor static func capture(maximumWait: TimeInterval = 3, waitForFinalResults: Bool = true,
        latest: () async throws -> AICapture, progress: (Int) -> Void) async throws -> AICapture {
        guard maximumWait.isFinite, maximumWait >= 0 else { throw AIError.invalid("confirmation timeout") }
        let deadline = ProcessInfo.processInfo.systemUptime + maximumWait
        repeat {
            try Task.checkCancellation()
            let value = try await latest()
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            // 速報を送る会議では文字の確定を待たず、音声の取り込みだけ待つ。
            let waiting = waitForFinalResults ? value.needsConfirmation : value.needsAudioProcessing
            if !waiting || remaining <= 0 { return value }
            progress(max(1, Int(ceil(remaining))))
            try await Task.sleep(for: .seconds(min(0.1, remaining)))
        } while true
    }
}
