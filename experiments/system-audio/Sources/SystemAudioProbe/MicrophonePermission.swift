import AVFoundation
import Foundation

enum MicrophoneDecision: Equatable {
    case wait, record, denied, restricted, timeout

    static func decide(_ status: AVAuthorizationStatus, elapsed: Double) -> Self {
        switch status {
        case .authorized: return .record
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return elapsed >= 60 ? .timeout : .wait
        @unknown default: return .restricted
        }
    }
}

func ensureMicrophonePermission() throws {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    log("microphone authorization=\(status.rawValue)")
    let start = ProcessInfo.processInfo.systemUptime
    if status == .notDetermined {
        log("マイク許可を要求します。最大60秒待ち、許可後はそのまま録音へ進みます。")
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }
    while true {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        switch MicrophoneDecision.decide(status, elapsed: elapsed) {
        case .record:
            log("microphone authorized waitSeconds=\(elapsed)")
            return
        case .wait: RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        case .denied: throw ProbeError("マイクの許可が拒否されました。録音せず終了します")
        case .restricted: throw ProbeError("マイクの使用が制限されています。録音せず終了します")
        case .timeout: throw ProbeError("マイク許可を60秒待ちました。時間切れのため録音せず終了します")
        }
    }
}
