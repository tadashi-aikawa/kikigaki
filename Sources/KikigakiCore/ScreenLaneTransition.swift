import Foundation

/// 画像レーンの「+N枚」と「畳む」で、枠を伸び縮みさせる計算。描画は `ScreenLaneView`、時刻の進め方は書き起こしウィンドウが持つ。
/// 仕様は [画面の記録](docs/screen-capture.md) の「1つの発言に何枚もあるとき」
///
/// - 枠ごとに見えている割合(0〜1)を持つ。増える枠は0から1へ、消える枠は1から0へ動かし、残る枠は1のまま
/// - 途中で次の並びが来たら、その時点の割合から次の並びへ向けて動かし直す。連打しても、最後の並びで終わる
/// - 枠は鍵で突き合わせる。並びの順を保ったまま、残る枠が最も多くなる対応を取る
public enum ScreenLaneTransition {
    /// 伸び縮みにかける時間(秒)。
    public static let duration = 0.2

    /// 動かしている間の1枠。
    public struct Entry: Equatable, Sendable {
        public var key: String
        /// 動かし始めた時点の見えている割合。
        public var from: Double
        /// 動かし終えた時点の割合。次の並びに無い枠は0。
        public var to: Double
        /// 今の並びでの添字。新しく増える枠はnil。
        public var current: Int?
        /// 次の並びでの添字。消える枠はnil。
        public var next: Int?

        public init(key: String, from: Double, to: Double, current: Int?, next: Int?) {
            self.key = key; self.from = from; self.to = to; self.current = current; self.next = next
        }
    }

    /// 今の並び(鍵と見えている割合)と次の並びを突き合わせ、動かしている間の並びを返す。
    /// 2つの残る枠の間では、消える枠を先に、増える枠を後に置く。
    public static func merge(current: [(key: String, visible: Double)], next: [String]) -> [Entry] {
        let n = current.count, m = next.count
        // 最長共通部分列。レーンの枠は多くても数十なので、表で解く。
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] = current[i].key == next[j]
                        ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var result: [Entry] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, current[i].key == next[j] {
                result.append(Entry(key: next[j], from: current[i].visible, to: 1, current: i, next: j))
                i += 1; j += 1
            } else if i < n, j == m || table[i + 1][j] >= table[i][j + 1] {
                result.append(Entry(key: current[i].key, from: current[i].visible, to: 0, current: i, next: nil))
                i += 1
            } else {
                result.append(Entry(key: next[j], from: 0, to: 1, current: nil, next: j))
                j += 1
            }
        }
        return result
    }

    /// 経過時間から進み具合(0〜1)。終わりへ向けて緩める。
    public static func progress(elapsed: Double, duration: Double = duration) -> Double {
        guard duration > 0 else { return 1 }
        let linear = min(1, max(0, elapsed / duration))
        return 1 - pow(1 - linear, 3)
    }

    /// 進み具合での見えている割合。
    public static func visible(_ entry: Entry, progress: Double) -> Double {
        entry.from + (entry.to - entry.from) * min(1, max(0, progress))
    }

    /// 枠の上端と、レーンの中身の高さ。枠は高さに割合を掛けた分だけ場所を取り、前の枠との間隔も割合を掛けて詰める。
    /// 割合がすべて1なら、高さと間隔を足しただけの値になる。
    /// - gaps: 各枠の前の間隔。先頭の枠の値は使わない。`gap(before:after:)` で決める
    public static func layout(heights: [Double], visibles: [Double], gaps: [Double]) -> (origins: [Double], total: Double) {
        var origins: [Double] = []
        var y = 0.0
        var seen = false
        for (index, (height, visible)) in zip(heights, visibles).enumerated() {
            if seen { y += (index < gaps.count ? gaps[index] : 0) * visible }
            origins.append(y)
            y += height * visible
            if visible > 0 { seen = true }
        }
        return (origins, max(0, y))
    }

    /// 枠の種類。間隔を決めるのに使う。
    /// トレイは、畳んだ画像の連なりを載せる角丸の受け皿。畳んでいる間は頭の行だけ、開くと中の画像と末尾の「畳む」まで伸びる。
    public enum Part: Equatable, Sendable {
        /// トレイの外の画像・イベントの行。
        case block
        /// トレイの頭の行(「+N枚」か「畳む」)。
        case trayHead
        /// トレイの中の画像。
        case trayItem
        /// トレイの末尾の「畳む」。
        case trayEnd
    }

    /// トレイの中の間隔。頭の行と最初の画像の間、最後の画像と末尾の「畳む」の間。トレイの縁と中身の間を詰める。
    public static let trayInset = 2.0

    /// 枠の前の間隔。トレイの中では頭と末尾の行の前後を詰め、画像どうしは外と同じ間隔にする。
    public static func gap(before part: Part, after previous: Part, spacing: Double) -> Double {
        switch (previous, part) {
        case (.trayHead, .trayItem), (.trayItem, .trayEnd), (.trayHead, .trayEnd): return trayInset
        default: return spacing
        }
    }
}
