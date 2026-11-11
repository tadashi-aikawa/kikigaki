import Foundation
import Testing
@testable import KikigakiCore

/// 画像レーンの「+N枚」「畳む」の伸び縮み。仕様は docs/screen-capture.md の「1つの発言に何枚もあるとき」
@Suite struct ScreenLaneTransitionTests {
    private func shown(_ keys: [String]) -> [(key: String, visible: Double)] { keys.map { ($0, 1) } }

    @Test func 開くと間の画像だけが0から伸び_ボタンと前後の画像は残る() {
        let entries = ScreenLaneTransition.merge(current: shown(["A", "fold|B", "D"]), next: ["A", "fold|B", "B", "C", "D"])
        #expect(entries.map(\.key) == ["A", "fold|B", "B", "C", "D"])
        #expect(entries.map(\.from) == [1, 1, 0, 0, 1])
        #expect(entries.map(\.to) == [1, 1, 1, 1, 1])
        #expect(entries.map(\.next) == [0, 1, 2, 3, 4])
    }

    @Test func 畳むと間の画像が縮んで消え_手前の枚数の行とまとまる畳むも縮む() {
        // 画像A → +2枚(B,C) → 畳む(D) → D → E を、D も畳んで A → +3枚 → E にする。
        let entries = ScreenLaneTransition.merge(current: shown(["A", "fold|B", "fold|D", "D", "E"]), next: ["A", "fold|B", "E"])
        #expect(entries.map(\.key) == ["A", "fold|B", "fold|D", "D", "E"])
        #expect(entries.map(\.to) == [1, 1, 0, 0, 1])
        #expect(entries.map(\.next) == [0, 1, nil, nil, 2])
    }

    @Test func 途中で反対の操作をするとその時点の割合から動かし直す() {
        let current: [(key: String, visible: Double)] = [("A", 1), ("fold|B", 1), ("B", 0.4), ("C", 0.4), ("D", 1)]
        let entries = ScreenLaneTransition.merge(current: current, next: ["A", "fold|B", "D"])
        #expect(entries.map(\.from) == [1, 1, 0.4, 0.4, 1])
        #expect(entries.map(\.to) == [1, 1, 0, 0, 1])
        // さらに開き直す。縮みかけの0.1から伸びる。
        let again = ScreenLaneTransition.merge(current: [("A", 1), ("fold|B", 1), ("B", 0.1), ("C", 0.1), ("D", 1)],
                                               next: ["A", "fold|B", "B", "C", "D"])
        #expect(again.map(\.from) == [1, 1, 0.1, 0.1, 1])
        #expect(again.allSatisfy { $0.to == 1 })
    }

    @Test func 進み具合は0秒2で1に達し_終わりへ向けて緩める() {
        #expect(ScreenLaneTransition.duration == 0.2)
        #expect(ScreenLaneTransition.progress(elapsed: 0) == 0)
        #expect(ScreenLaneTransition.progress(elapsed: 0.2) == 1)
        #expect(ScreenLaneTransition.progress(elapsed: 5) == 1)
        #expect(ScreenLaneTransition.progress(elapsed: -1) == 0)
        let half = ScreenLaneTransition.progress(elapsed: 0.1)
        #expect(half > 0.5 && half < 1)
        #expect(ScreenLaneTransition.progress(elapsed: 1, duration: 0) == 1)
        let entry = ScreenLaneTransition.Entry(key: "B", from: 0.4, to: 0, current: 2, next: nil)
        #expect(abs(ScreenLaneTransition.visible(entry, progress: 0.5) - 0.2) < 1e-9)
    }

    @Test func 中身の高さは見えている割合で枠と間隔を詰め_すべて1なら足しただけ() {
        let gaps = [0.0, 12, 12]
        let full = ScreenLaneTransition.layout(heights: [100, 22, 100], visibles: [1, 1, 1], gaps: gaps)
        #expect(full.origins == [0, 112, 146])
        #expect(full.total == 246)
        let hidden = ScreenLaneTransition.layout(heights: [100, 22, 100], visibles: [1, 1, 0], gaps: gaps)
        #expect(hidden.total == 134)
        let half = ScreenLaneTransition.layout(heights: [100, 22, 100], visibles: [1, 1, 0.5], gaps: gaps)
        #expect(half.origins[2] == 140)
        #expect(half.total == 190)
        #expect(ScreenLaneTransition.layout(heights: [], visibles: [], gaps: []).total == 0)
    }

    @Test func トレイの中は頭と末尾の行の前後を詰め_画像どうしと外は同じ間隔() {
        typealias Part = ScreenLaneTransition.Part
        func gap(_ part: Part, after previous: Part) -> Double { ScreenLaneTransition.gap(before: part, after: previous, spacing: 12) }
        #expect(gap(.trayHead, after: .block) == 12)
        #expect(gap(.trayItem, after: .trayHead) == 2)
        #expect(gap(.trayItem, after: .trayItem) == 12)
        #expect(gap(.trayEnd, after: .trayItem) == 2)
        #expect(gap(.block, after: .trayEnd) == 12)
        #expect(gap(.block, after: .trayHead) == 12)
        // 開いたトレイ: 頭28 → 2 → 画像100 → 12 → 画像100 → 2 → 末尾28。外の画像まで12。
        let parts: [Part] = [.block, .trayHead, .trayItem, .trayItem, .trayEnd, .block]
        let gaps = parts.indices.map { $0 == 0 ? 0 : gap(parts[$0], after: parts[$0 - 1]) }
        let open = ScreenLaneTransition.layout(heights: [80, 28, 100, 100, 28, 80], visibles: [1, 1, 1, 1, 1, 1], gaps: gaps)
        #expect(open.origins == [0, 92, 122, 234, 336, 376])
        // 畳む途中: 中の画像と末尾の行が半分。トレイの下端は頭から半分の位置まで縮む。
        let half = ScreenLaneTransition.layout(heights: [80, 28, 100, 100, 28, 80], visibles: [1, 1, 0.5, 0.5, 0.5, 1], gaps: gaps)
        // 92 + 28 + (2 + 100 + 12 + 100 + 2 + 28) / 2 + 12
        let expected: Double = 254
        #expect(half.origins[5] == expected)
    }
}
