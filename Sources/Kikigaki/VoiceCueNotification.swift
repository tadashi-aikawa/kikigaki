import Foundation
import UserNotifications

/// 音と通知の共通イベント。通知センターを使わず文面を検証できる。
/// `phrase` は括弧に添える合図の表記。グローバルキーではキーの表記を入れる。
enum VoiceCueFeedback: Equatable {
    case accepted(destination: String, phrase: String, appendix: Bool)
    /// 宛先なしは、録音外でグローバルキーを押したときだけ
    case failed(destination: String?, reason: String)

    var accepted: Bool {
        if case .accepted = self { return true }
        return false
    }
    var body: String {
        switch self {
        case let .accepted(destination, phrase, appendix):
            return "\(destination)へ\(appendix ? "追記を送りました" : "送りました")（\(phrase)）"
        case let .failed(destination?, reason):
            return "\(destination)へ送れませんでした。\(reason)"
        case let .failed(nil, reason):
            return "送れませんでした。\(reason)"
        }
    }
}

/// バンドル外ではcurrent()自体が例外を投げるため、生成前に実行環境を判定する。
@MainActor
final class VoiceCueNotification: NSObject, UNUserNotificationCenterDelegate {
    static func supported(bundleIdentifier: String?, replay: Bool) -> Bool {
        bundleIdentifier?.isEmpty == false && !replay
    }
    private let center: UNUserNotificationCenter
    private var delivery: Task<Void, Never>?
    var onClick: (() -> Void)?

    init?(bundleIdentifier: String? = Bundle.main.bundleIdentifier,
          replay: Bool = CommandLine.arguments.contains("--replay")) {
        guard Self.supported(bundleIdentifier: bundleIdentifier, replay: replay) else { return nil }
        center = .current()
        super.init()
        center.delegate = self
    }

    func post(_ feedback: VoiceCueFeedback, title: String = "KIKIGAKI · 声の合図") {
        post(title: title, body: feedback.body)
    }

    /// AIの返事の通知もここから出す。押したときに窓を前に出す動きを共有するため
    func post(title: String, body: String) {
        let previous = delivery
        // 初回の許可待ち中に失敗が届いても、受付→失敗の順を保つ。
        delivery = Task { [center] in
            await previous?.value
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            case .authorized, .provisional: break
            default: return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = nil
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { completionHandler(); return }
        Task { @MainActor [weak self] in
            self?.onClick?()
            completionHandler()
        }
    }
}
