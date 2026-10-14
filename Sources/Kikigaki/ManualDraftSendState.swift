/// 声の合図とフッターの送信ボタンが共有する、現在の手動宛先の送信可否。
enum ManualDraftSendState: Equatable {
    case ready(appendix: Bool)
    case unavailable(String)

    var canSend: Bool {
        if case .ready = self { return true }
        return false
    }
    var toolTip: String {
        switch self {
        case .ready(appendix: false): return "下書きで今すぐ送る"
        case .ready(appendix: true): return "下書きで実行中の依頼へ追記して送る"
        case let .unavailable(reason): return reason
        }
    }
}
