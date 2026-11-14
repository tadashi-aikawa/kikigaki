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
