import Foundation
import Testing
@testable import KikigakiCore

/// 画像レーンの置き場・畳み方・題。表示専用で、行の並びから毎回導く。
@Suite struct ScreenLaneTests {
    private let start = Date(timeIntervalSince1970: 0)
    private func image(_ at: Double, _ name: String? = nil, label: String = "EV3895 · Keynote「提案資料」") -> Utterance {
        try! Utterance(screenLabel: label, imagePath: "/tmp/会議.captures/\(name ?? String(Int(at))).webp", at: at,
                       postedAt: start.addingTimeInterval(at))
    }
    private func event(_ at: Double, _ value: Utterance.ScreenEvent = .stopped) -> Utterance {
        try! Utterance(screenEvent: value, at: at, postedAt: start.addingTimeInterval(at))
    }
    private func voice(_ start: Double, _ end: Double, speaker: Int = 0) -> Utterance {
        Utterance(speaker: speaker, start: start, end: end, text: "発言\(Int(start))")
    }
    private func typed(_ at: Double) -> Utterance {
        try! Utterance(typedText: "メモ", at: at, postedAt: start.addingTimeInterval(at))
    }

    @Test func 観測した時点に話していた発言の横へ置き_誰も話していなければ次の発言へ置く() {
        // 0: 声 10〜20 / 1: 画面 15 (話している最中) / 2: 画面 20 (言い終わりの瞬間) / 3: 画面 25 (沈黙) / 4: 声 30〜40
        let rows = [voice(10, 20), image(15), image(20), image(25), voice(30, 40)]
        #expect(ScreenLane.assign(rows) == .init(beside: [0: [1, 2], 4: [3]]))
    }

    @Test func 会議の頭の画面は最初の発言へ_後ろに発言が無い画面は末尾へ置く() {
        let rows = [image(0), voice(5, 8), image(9), event(10)]
        #expect(ScreenLane.assign(rows) == .init(beside: [1: [0]], trailing: [2, 3]))
        // 発言がまだ無い会議では全部が末尾。
        #expect(ScreenLane.assign([image(0), image(3)]) == .init(trailing: [0, 1]))
    }

    @Test func 次の発言が届くと末尾からその発言の横へ移る() {
        var rows = [voice(0, 5), image(7)]
        #expect(ScreenLane.assign(rows).trailing == [1])
        rows.append(voice(9, 12))
        #expect(ScreenLane.assign(rows) == .init(beside: [2: [1]]))
    }

    @Test func 手入力の行は割り当て先にしない() {
        let rows = [voice(0, 5), image(6), typed(6), voice(10, 12)]
        #expect(ScreenLane.assign(rows) == .init(beside: [3: [1]]))
    }

    @Test func 同時刻の画面と発言の境目() {
        // 前の発言の終わりと次の発言の始まりが同じ時刻なら、話し始めた次の発言へ。
        #expect(ScreenLane.assign([voice(0, 10), voice(10, 20, speaker: 1), image(10)]) == .init(beside: [1: [2]]))
        // 発言の始まりちょうどの画面は、その発言へ。
        #expect(ScreenLane.assign([image(5), voice(5, 8)]) == .init(beside: [1: [0]]))
        // 発言の終わりちょうどの画面は、その発言へ。後ろに発言が無くても末尾にしない。
        #expect(ScreenLane.assign([voice(0, 5), image(5)]) == .init(beside: [0: [1]]))
    }

    @Test func 同時刻の画面どうしは並びを保って同じ発言へ置く() {
        #expect(ScreenLane.assign([voice(0, 10), image(5, "a"), image(5, "b")]) == .init(beside: [0: [1, 2]]))
        #expect(ScreenLane.assign([voice(0, 4), image(6, "a"), image(6, "b"), voice(8, 9)]) == .init(beside: [3: [1, 2]]))
        #expect(ScreenLane.assign([voice(0, 4), image(6, "a"), event(6)]) == .init(trailing: [1, 2]))
    }

    @Test func 区間が重なる発言では後から話し始めた方へ置く() {
        // 0: 10〜30 / 1: 15〜18 / 2: 25〜40。画面22は0だけ、画面26は0と2に含まれ、後から始めた2を採る。
        let rows = [voice(10, 30), voice(15, 18, speaker: 1), image(22), voice(25, 40, speaker: 2), image(26)]
        #expect(ScreenLane.assign(rows) == .init(beside: [0: [2], 3: [4]]))
    }

    @Test func 話者の付け替えや併合で行が変わっても並びから導き直す() {
        let before = [voice(0, 4), image(5), voice(6, 9, speaker: 1), image(10), voice(11, 14)]
        #expect(ScreenLane.assign(before) == .init(beside: [2: [1], 4: [3]]))
        // 0と2が1つの行へ併合され、区間が0〜9になった。
        let merged = [voice(0, 9), image(5), image(10), voice(11, 14)]
        #expect(ScreenLane.assign(merged) == .init(beside: [0: [1], 3: [2]]))
    }

    @Test func 二枚までは全部出し_三枚以上は最初と最後を出して間を畳む() {
        let rows = [image(1), image(2), image(3), image(4)]
        #expect(ScreenLane.slots([0], utterances: rows, expanded: []) == [.screen(0)])
        #expect(ScreenLane.slots([0, 1], utterances: rows, expanded: []) == [.screen(0), .screen(1)])
        #expect(ScreenLane.slots([0, 1, 2], utterances: rows, expanded: []) == [.screen(0), .folded([1]), .screen(2)])
        #expect(ScreenLane.slots([0, 1, 2, 3], utterances: rows, expanded: []) == [.screen(0), .folded([1, 2]), .screen(3)])
    }

    @Test func 開いた画像はパスで覚え_後から最後の画像が増えても開いたまま保つ() {
        var rows = [image(1), image(2), image(3)]
        let expanded: Set<String> = ["/tmp/会議.captures/2.webp"]
        // 開いた連なりの頭と末尾に「畳む」を置く。頭は「+N枚」があった位置。
        #expect(ScreenLane.slots([0, 1, 2], utterances: rows, expanded: expanded)
                == [.screen(0), .expanded([1]), .screen(1), .expandedEnd([1]), .screen(2)])
        // 3枚目が最後でなくなると畳む対象に入るが、開いていない分だけ新しく畳む。
        rows.append(image(4))
        #expect(ScreenLane.slots([0, 1, 2, 3], utterances: rows, expanded: expanded)
                == [.screen(0), .expanded([1]), .screen(1), .expandedEnd([1]), .folded([2]), .screen(3)])
    }

    @Test func 開いた連なりは畳むを頭と末尾に付けて並べ_開いた覚えを消すと元の枚数の行に戻る() {
        let rows = [image(1), image(2), image(3), image(4), image(5)]
        let all: Set<String> = ["/tmp/会議.captures/2.webp", "/tmp/会議.captures/3.webp", "/tmp/会議.captures/4.webp"]
        #expect(ScreenLane.slots(Array(rows.indices), utterances: rows, expanded: all)
                == [.screen(0), .expanded([1, 2, 3]), .screen(1), .screen(2), .screen(3), .expandedEnd([1, 2, 3]), .screen(4)])
        #expect(ScreenLane.slots(Array(rows.indices), utterances: rows, expanded: all.subtracting(all))
                == [.screen(0), .folded([1, 2, 3]), .screen(4)])
        // 開いた後に間へ届いた画像は、開いた連なりとは別に畳む。
        let partial: Set<String> = ["/tmp/会議.captures/2.webp", "/tmp/会議.captures/4.webp"]
        #expect(ScreenLane.slots(Array(rows.indices), utterances: rows, expanded: partial)
                == [.screen(0), .expanded([1]), .screen(1), .expandedEnd([1]), .folded([2]),
                    .expanded([3]), .screen(3), .expandedEnd([3]), .screen(4)])
    }

    @Test func イベントの行は畳まず_挟まれた画像は前後で別の連なりに畳む() {
        let rows = [image(1), image(2), event(3), event(4, .resumed), image(5), image(6), image(7)]
        #expect(ScreenLane.slots(Array(rows.indices), utterances: rows, expanded: [])
                == [.screen(0), .folded([1]), .screen(2), .screen(3), .folded([4, 5]), .screen(6)])
        // 画像の無い発言ではイベントの行だけを出す。
        #expect(ScreenLane.slots([2, 3], utterances: rows, expanded: []) == [.screen(2), .screen(3)])
    }

    @Test func 全画像に共通のディスプレイ名をサムネイルの題から省く() {
        let labels = ["EV3895 · Keynote「提案資料」", "EV3895", "EV3895 · Safari"]
        let display = ScreenLane.sharedDisplayName(labels)
        #expect(display == "EV3895")
        #expect(labels.map { ScreenLane.caption($0, sharedDisplay: display) } == ["Keynote「提案資料」", "", "Safari"])
    }

    @Test func ディスプレイ名と確かめられなければ省かない() {
        // 区切りを持つ見出しが無ければ、先頭がディスプレイ名かウィンドウの題か分からない。
        #expect(ScreenLane.sharedDisplayName(["Keynote「提案資料」", "Keynote「提案資料」"]) == nil)
        #expect(ScreenLane.sharedDisplayName(["EV3895 · Keynote", "内蔵 · Safari"]) == nil)
        #expect(ScreenLane.sharedDisplayName([]) == nil)
        #expect(ScreenLane.caption("EV3895 · Keynote", sharedDisplay: nil) == "EV3895 · Keynote")
    }

    @Test func ディスプレイが1つの会議は全部の題からディスプレイ名を省く() {
        #expect(ScreenLane.captions(["EV3895 · Keynote「提案資料」", "EV3895", "EV3895 · Safari"]) == ["Keynote「提案資料」", "", "Safari"])
        #expect(ScreenLane.captions(["Keynote「提案資料」"]) == ["Keynote「提案資料」"])
        #expect(ScreenLane.captions([]) == [])
    }

    @Test func 録音中に替えた会議は直前と同じディスプレイの名前だけを省き_替えた直後の1枚に名前を残す() {
        let labels = ["EV3895 · Keynote", "EV3895 · Safari", "内蔵 · Keynote", "内蔵", "EV3895 · Keynote"]
        #expect(ScreenLane.captions(labels) == ["EV3895 · Keynote", "Safari", "内蔵 · Keynote", "", "EV3895 · Keynote"])
    }
}
