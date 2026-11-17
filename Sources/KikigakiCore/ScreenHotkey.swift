import Foundation

/// グローバルキーで画面の記録を切り替えたときの行き先。仕様は [画面の記録](docs/screen-capture.md) の「グローバルキー」
///
/// 撮っている・撮り始めるのを待っているなら止める。それ以外なら、次の順で最初につながっているディスプレイで入れ直す。
/// 1. この会議で最後に撮影を始められたディスプレイ。番号と名前が同じもの、無ければ名前が同じもの
///    - 理由: 番号はつなぎ直しで変わりうる。開始シートの前回値も名前で覚えている
///    - 番号だけ同じで名前が違うものは使わない。つなぎ直しで番号が別のディスプレイへ振られていることがある
/// 2. 開始シートで最後にディスプレイを選んで始めたときの名前
/// 3. メインのディスプレイ
/// 4. つながっている最初のディスプレイ
/// グローバルキーで「いま撮る」を押したときに撮れない理由。仕様は [画面の記録](docs/screen-capture.md) の「グローバルキー」
///
/// 撮れるのはフッターのメニューに「いま撮る」が出ている場面と同じ。それ以外は理由を返し、呼び出し側が `Basso` と通知で断る。
/// - 理由: ウィンドウが見えないまま押すので、押して何も起きない、を作らない
public enum ScreenCaptureNowRefusal: Equatable, Sendable {
    /// 録音中でない。一時停止中・停止後・停止処理中も含む
    case notRecording
    /// 画面を撮らない会議。音声ファイルの書き起こしとreplay
    case noScreenCapture
    /// 「撮らない」を選んでいる
    case off
    /// 撮れなくなった後
    case unavailable
    /// 撮り始めるのを待っている。対象の替え・再開・撮れなくなった後の選び直しで、ストリームを準備している間
    case starting

    /// 撮れるならnil。
    /// - ready: 撮影側に、いまの対象の撮影に要るものが揃っているか
    public static func check<Target>(recording: Bool, screenCapture: Bool, target: ScreenTarget<Target>,
                                     ready: Bool) -> Self? {
        guard recording else { return .notRecording }
        guard screenCapture else { return .noScreenCapture }
        if target.isStarting { return .starting }
        switch target.display {
        case .off: return .off
        case .failed: return .unavailable
        case .on: return target.canCaptureNow(recording: true) && ready ? nil : .starting
        }
    }

    public var reason: String {
        switch self {
        case .notRecording: return "録音中だけ撮れます"
        case .noScreenCapture: return "この会議では画面を記録しません"
        case .off: return "画面の記録を停止しています"
        case .unavailable: return "画面を記録できていません"
        case .starting: return "画面の記録を始めるのを待っています"
        }
    }
}

public enum ScreenHotkeyChoice: Equatable, Sendable {
    case stop
    /// つながっているディスプレイの添字
    case start(index: Int)
    /// つながっているディスプレイが無い
    case noDisplay

    public struct Display: Equatable, Sendable {
        public let id: UInt32
        public let name: String
        public init(id: UInt32, name: String) { self.id = id; self.name = name }
    }

    public static func choose(engaged: Bool, lastCaptured: Display?, sheetName: String?,
                              connected: [Display], mainID: UInt32?) -> Self {
        if engaged { return .stop }
        let index = lastCaptured.flatMap { last in
                connected.firstIndex(of: last) ?? connected.firstIndex { $0.name == last.name }
            }
            ?? sheetName.flatMap { name in name.isEmpty ? nil : connected.firstIndex { $0.name == name } }
            ?? mainID.flatMap { id in connected.firstIndex { $0.id == id } }
            ?? (connected.isEmpty ? nil : 0)
        return index.map { .start(index: $0) } ?? .noDisplay
    }
}
