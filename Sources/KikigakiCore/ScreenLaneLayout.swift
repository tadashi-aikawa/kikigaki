import Foundation

/// 画像レーンの幅とサムネイルの寸法。描画は `ScreenLaneView`、幅の保存は `MinutesSplitView` が受け持つ。
/// 仕様は [画面の記録](docs/screen-capture.md) の「表示」
///
/// - 幅は利用者が発言の列との境目をドラッグして変える。文字の倍率は掛けない。操作部の寸法なので
/// - 発言の列には `columnMinimum` を残す。ウィンドウの最小幅と同じで、これより狭いと本文の折り返しが増えて読めない
public enum ScreenLaneLayout {
    public static let minimumWidth = 180.0
    public static let maximumWidth = 480.0
    /// 保存した幅が無いときの幅。
    public static let defaultWidth = minimumWidth
    /// 発言の列に残す幅の下限。書き起こしウィンドウの最小幅と同じ。
    public static let columnMinimum = 420.0
    /// サムネイルの左の余白。境目をつかめる範囲もここに置く。
    public static let leadingInset = 8.0
    /// サムネイルの右の余白。スクローラーの分。
    public static let trailingInset = 20.0
    /// 画像と題の間。
    public static let captionGap = 3.0
    /// 枠と枠の間。題と次の画像を、画像と題の間より広く離す。どの題がどの画像かを間隔だけで読み分けるため。
    public static let blockSpacing = 12.0
    /// 縦長の画面の枠の高さの上限。幅に対する比。広げたレーンで縦長の画面が1枚で画面を埋めないため。
    public static let maximumAspectHeight = 1.0
    /// 縮小画像を読む大きさの刻み。サムネイルの幅をこの刻みで切り上げ、2倍の画素で読む。
    /// 刻みは既定の幅のサムネイル。幅の範囲の全体で読み直しは3段に収まり、ドラッグの途中で読み込みが走りすぎない。
    public static let decodeStep = minimumWidth - leadingInset - trailingInset

    /// 保存した幅を範囲に収める。読めない値は既定の幅。
    public static func clamp(_ preferred: Double) -> Double {
        guard preferred.isFinite else { return defaultWidth }
        return min(maximumWidth, max(minimumWidth, preferred.rounded()))
    }

    /// 会話側の幅 `pane` で出すレーンの幅。希望の幅を、発言の列に `columnMinimum` を残せる分までに抑える。
    /// 残せないほど狭ければ最小幅。ウィンドウや議事録の区切り線で会話側が狭まると、発言の列より先にレーンが譲る。
    public static func width(preferred: Double, pane: Double) -> Double {
        min(clamp(preferred), max(minimumWidth, (pane - columnMinimum).rounded(.down)))
    }

    /// 境目をドラッグした後の幅。`start` は押した時点の幅、`dx` はポインタが右へ動いた量。左へ動かすとレーンが広がる。
    public static func dragged(from start: Double, by dx: Double, pane: Double) -> Double {
        width(preferred: start - dx, pane: pane)
    }

    /// 境目をつかめる範囲。発言の列の右端からレーンの左の余白まで。画像が無い会議とレーンを出さない幅ではnil。
    /// サムネイルには掛けない。サムネイルを押すとQuick Lookで開くため。
    public static func grip(documentWidth: Double, laneWidth: Double, hasImages: Bool) -> ClosedRange<Double>? {
        guard laneWidth > 0, hasImages else { return nil }
        let boundary = documentWidth - laneWidth
        return (boundary - 4)...(boundary + leadingInset - 2)
    }

    public static func thumbnailWidth(laneWidth: Double) -> Double {
        laneWidth - leadingInset - trailingInset
    }

    /// サムネイルの枠。枠を画像の縦横比に合わせ、画像の下に余りを作らない。題は枠のすぐ下に置く。
    /// - 画面の縦横比はディスプレイごとに違う。固定の枠に収めると、横長の画面では下に余りが出て、題が次の画像のものに見える
    /// - 縦長の画面は高さを `maximumAspectHeight` で抑え、枠の中へ縦横比を保って収める
    /// - 画素の寸法が分からなければ16:9
    public static func thumbnailSize(laneWidth: Double, pixelWidth: Double?, pixelHeight: Double?) -> (width: Double, height: Double) {
        let width = thumbnailWidth(laneWidth: laneWidth)
        let ratio: Double
        if let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0, pixelWidth.isFinite, pixelHeight.isFinite {
            ratio = pixelHeight / pixelWidth
        } else {
            ratio = 9.0 / 16
        }
        return (width, max(1, (width * min(ratio, maximumAspectHeight)).rounded()))
    }

    /// 縮小画像を読む長辺の画素数。Retinaでも文字の形が分かるよう、枠の2倍で読む。
    public static func decodePixels(thumbnailWidth: Double) -> Int {
        let steps = max(1, (thumbnailWidth / decodeStep).rounded(.up))
        return Int(steps * decodeStep * 2)
    }
}
