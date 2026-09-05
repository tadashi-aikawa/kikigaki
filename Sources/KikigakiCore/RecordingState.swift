import Foundation

/// 録音の状態。メニュー・ショートカット・ウィンドウの表示はすべてこの値から導く
public enum RecordingState: Equatable, Sendable {
    /// 待機中(前の会議の結果を表示していることはある)
    case idle
    /// エンジンを準備中(開始操作の直後)
    case preparing
    case recording
    case paused
    /// 停止処理中(最終判定と保存)
    case finishing

    /// 「開始 / 停止」メニュー項目の表題
    public var startStopTitle: String {
        switch self {
        case .idle: return "録音を開始"
        case .preparing: return "準備中..."
        case .recording, .paused: return "録音を停止"
        case .finishing: return "保存中..."
        }
    }

    /// 「一時停止 / 再開」メニュー項目の表題
    public var pauseResumeTitle: String {
        self == .paused ? "再開" : "一時停止"
    }

    public var canStart: Bool { self == .idle }
    public var canStop: Bool { self == .recording || self == .paused }
    public var canPauseOrResume: Bool { canStop }

    /// メニューバーに出す短い状態表示
    public var statusLabel: String {
        switch self {
        case .idle: return "待機中"
        case .preparing: return "準備中"
        case .recording: return "録音中"
        case .paused: return "一時停止中"
        case .finishing: return "保存中"
        }
    }
}
