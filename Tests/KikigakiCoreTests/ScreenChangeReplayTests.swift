import Foundation
import Testing
@testable import KikigakiCore

/// 試作 `experiments/screen-capture` の判定器と、本体の `ScreenChangeDetector` が同じ観測の列で同じ決定を出すことを固定する。
///
/// 観測の列と期待の決定は、試作の `export-replay` が書き出した `Fixtures/screen-replay-*.json`。
/// - 縮小画像は幅128の輝度だけを持つ。画像そのものは持たない
/// - 期待の決定は、試作の判定器に推す組の値で当てた結果。本体の既定値と同じ値
/// - 当て方は試作の `sweep` と同じ。記録の開始から0.25秒ごとに時間を進め、決めたらその時刻に保存の成功を返す
/// - リポジトリに置くのは合成の筋書きだけ。実画面の記録は利用者の画面の縮小画像を含むので置かない
///   - 実画面の記録は、手元で書き出したファイルを環境変数 `KIKIGAKI_SCREEN_REPLAY_FIXTURE` で渡すと当てる。渡さなければ飛ばす
///
/// 書き出し直す手順と手元で流す手順は [独立試作のREADME](experiments/screen-capture/README.md) の「本体の判定器と突き合わせる」
@Suite struct ScreenChangeReplayTests {
    /// 手元の観測の列。リポジトリの外に置いたファイルの絶対パス。
    static let localFixture = ProcessInfo.processInfo.environment["KIKIGAKI_SCREEN_REPLAY_FIXTURE"]

    struct Fixture: Decodable {
        struct Line: Decodable { var k: String; var t: Double; var i: Int? }
        struct Expected: Decodable, Equatable { var frame: Int; var reason: String; var decidedAt: Double }
        var source: String
        var top: Double
        var width: Int
        var height: Int
        var lines: [Line]
        var luma: String
        var decisions: [Expected]
        /// 決定の `failEvery` 回に1回を保存の失敗として返したときの、試作の決定。失敗した決定も含む。
        var failEvery: Int?
        var decisionsWithFailures: [Expected]?
    }

    /// 保存の結果の返し方。本体は符号化と書き込みの分だけ遅れて返し、失敗も一時停止も挟まる。
    struct Delivery {
        /// 直近の画面の最後に見た時刻と、外すマスを戻す時刻の起点。
        enum Origin { case success, decision }
        /// 保存を決めてから結果を返すまでの秒数。0なら試作と同じく決めた直後に返す。
        var delay = 0.0
        /// 決定のこの回数に1回を、保存の失敗として返す。0なら失敗させない。
        var failEvery = 0
        /// 本体と同じく、保存を決めた時刻。
        var origin = Origin.decision
        /// この区間は一時停止として観測も判定もしない。区間の後で `restart` する。結果は一時停止の間も返る。
        var pause: Range<Double>?
    }

    static func load(_ name: String) throws -> Fixture {
        try load(url: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json"))
    }

    static func load(url: URL) throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// 試作の `Simulation.run` と同じ順で当てる。受付の番号は決めた順に振る。返すのは失敗した決定も含む全部の決定。
    /// - delivery: 既定は試作と同じく、決めた直後にその時刻で成功を返す
    static func replay(_ fixture: Fixture, _ delivery: Delivery = Delivery()) throws -> [Fixture.Expected] {
        guard let packed = Data(base64Encoded: fixture.luma) else { throw CocoaError(.coderReadCorrupt) }
        let luma = [UInt8](try (packed as NSData).decompressed(using: .lzma) as Data)
        let size = fixture.width * fixture.height
        var parameters = ScreenChangeParameters()
        parameters.excludedTopFraction = fixture.top
        var detector = ScreenChangeDetector(parameters: parameters)
        var decisions: [Fixture.Expected] = []
        var waiting: [(frame: Int, due: Double, fail: Bool)] = []
        // 結果を返す時刻が来た決定から、決めた順に返す。
        func deliver(upTo time: Double) {
            while let first = waiting.first, first.due <= time {
                waiting.removeFirst()
                if first.fail { detector.saveFailed(frame: first.frame, at: first.due) }
                else { detector.saveSucceeded(frame: first.frame, at: delivery.origin == .success ? first.due : nil) }
            }
        }
        func settle(_ decision: ScreenChangeDetector.Decision?, at time: Double) {
            guard let decision else { return }
            detector.accepted(frame: decision.frame, order: decisions.count)
            decisions.append(.init(frame: decision.frame, reason: "\(decision.reason)", decidedAt: time))
            let fail = delivery.failEvery > 0 && decisions.count % delivery.failEvery == 0
            waiting.append((decision.frame, time + delivery.delay, fail))
            deliver(upTo: time)
        }
        var resumed = delivery.pause == nil
        /// 一時停止の間はfalse。区間の後の最初の時刻で再開する。
        func active(_ time: Double) -> Bool {
            deliver(upTo: time)
            guard let pause = delivery.pause else { return true }
            if pause.contains(time) { return false }
            if time >= pause.upperBound, !resumed { resumed = true; detector.restart() }
            return true
        }
        var nextTick = 0.25
        func advance(to time: Double) {
            while nextTick < time {
                if active(nextTick) { settle(detector.tick(at: nextTick), at: nextTick) }
                nextTick += 0.25
            }
        }
        var offset = 0
        for line in fixture.lines {
            advance(to: line.t)
            switch line.k {
            case "f":
                let thumbnail = ScreenThumbnail(width: fixture.width, height: fixture.height, luma: Array(luma[offset..<offset + size]))
                offset += size
                if active(line.t) { settle(detector.observe(frame: line.i ?? 0, at: line.t, thumbnail: thumbnail), at: line.t) }
            case "i": if active(line.t) { settle(detector.tick(at: line.t), at: line.t) }
            case "u": detector.reset()
            default: break
            }
        }
        #expect(offset == luma.count)
        return decisions
    }

    /// 2つの決定の列で、フレームの番号が食い違う数。片方にだけある決定を数える。
    static func mismatch(_ a: [Fixture.Expected], _ b: [Fixture.Expected]) -> Int {
        var rest = b.map(\.frame)
        var unmatched = 0
        for frame in a.map(\.frame) {
            if let index = rest.firstIndex(of: frame) { rest.remove(at: index) } else { unmatched += 1 }
        }
        return unmatched + rest.count
    }

    static func expectSameDecisions(_ fixture: Fixture) throws {
        let actual = try replay(fixture)
        #expect(actual.count == fixture.decisions.count)
        for (got, want) in zip(actual, fixture.decisions) {
            #expect(got.frame == want.frame && got.reason == want.reason && abs(got.decidedAt - want.decidedAt) < 1e-9, "\(got) != \(want)")
        }
    }

    /// 合成の観測の列。
    /// - mixed: `mix-1080m1/phase0`。外すマスが動く画像の全体を覆わない漏れが出る
    /// - mixed-phase1: `mix-1080/phase1`。結果を遅らせると、起点を書けた時刻にした形では試作から食い違う
    /// - anim: `anim-1080/phase0`。描き込んだポインタ・止まる動く画像・通知
    /// - wake: `wake-1080/phase0`。動く画像のスライドを映したまま始める。止まっていた動く画像が動き出す
    /// - note: `note-1080/phase0`。動く画像の隣に、静止した注記が足される
    static let fixtures = ["screen-replay-mixed", "screen-replay-mixed-phase1", "screen-replay-anim", "screen-replay-wake", "screen-replay-note"]

    @Test(arguments: fixtures)
    func 試作と同じ観測の列で同じ時刻に同じ理由で保存を決める(name: String) throws {
        try Self.expectSameDecisions(try Self.load(name))
    }

    /// 合成の `wake` と `note` の、いまの振る舞いを固定する。区間は `SynthMotion.swift` の冒頭。
    /// - wake の開始から映す0〜40秒は3枚。開始の1枚、動く画像だけが違う強制の1枚、図が替わった1枚。受け入れた限界
    /// - wake の動き出した60〜100秒は、強制の1枚だけ。受け入れた限界
    /// - note の注記が出る5〜60秒と85〜130秒は、どちらも注記の入った1枚を撮る
    @Test func 動く画像のスライドで始める場面と注記が足される場面のいまの枚数() throws {
        let wake = try Self.replay(try Self.load("screen-replay-wake"))
        #expect(wake.filter { $0.decidedAt < 40 }.count == 3, "\(wake)")
        #expect(wake.filter { (60..<100).contains($0.decidedAt) }.map(\.reason) == ["moving"], "\(wake)")
        let note = try Self.replay(try Self.load("screen-replay-note"))
        #expect(note.contains { (5..<60).contains($0.decidedAt) }, "\(note)")
        #expect(note.contains { (85..<130).contains($0.decidedAt) }, "\(note)")
    }

    /// 決定の3回に1回を失敗として返す。続けて失敗する場面も含め、試作と同じ時刻に同じ理由で決め直す。
    @Test(arguments: fixtures)
    func 保存の失敗を混ぜても試作と同じ時刻に同じ理由で決め直す(name: String) throws {
        let fixture = try Self.load(name)
        let expected = try #require(fixture.decisionsWithFailures)
        let actual = try Self.replay(fixture, Delivery(failEvery: try #require(fixture.failEvery)))
        #expect(actual.count == expected.count)
        for (got, want) in zip(actual, expected) {
            #expect(got.frame == want.frame && got.reason == want.reason && abs(got.decidedAt - want.decidedAt) < 1e-9, "\(got) != \(want)")
        }
    }

    /// 保存の結果を遅らせて返し、失敗と一時停止を挟む。本体の時刻の扱いで、試作の決定から大きく崩れないことを見る。
    /// - 遅れ: 実画面では符号化と書き込みで0.1秒前後。余裕を見て1秒まで
    /// - 一時停止: 100〜130秒。一時停止の前の決定は試作と同じ。再開の後は、一時停止の間を観測しないことと、
    ///   再開の直後の1枚を落ち着きを待たずに比べる契約で時刻がずれるので、枚数だけを見る
    @Test(arguments: fixtures)
    func 保存の完了の遅れと失敗と一時停止を挟んでも試作の決定から大きく崩れない(name: String) throws {
        let fixture = try Self.load(name)
        for delay in [0.25, 0.5, 1.0] {
            #expect(Self.mismatch(try Self.replay(fixture, Delivery(delay: delay)), fixture.decisions) == 0, "遅れ\(delay)秒")
        }
        let pause = 100.0..<130.0
        // 遅れを重ねると再試行の時刻も遅れの分だけずれるので、一時停止の前を試作と比べるのは遅れの無い組だけ。
        for delivery in [Delivery(pause: pause), Delivery(failEvery: 3, pause: pause), Delivery(delay: 0.25, failEvery: 3, pause: pause)] {
            let paused = try Self.replay(fixture, delivery)
            let expected = try delivery.failEvery > 0 ? #require(fixture.decisionsWithFailures) : fixture.decisions
            if delivery.delay == 0 {
                #expect(paused.filter { $0.decidedAt < pause.lowerBound } == expected.filter { $0.decidedAt < pause.lowerBound })
            }
            #expect(!paused.contains { pause.contains($0.decidedAt) })
            let after = paused.filter { $0.decidedAt >= pause.upperBound }.count
            let expectedAfter = expected.filter { $0.decidedAt >= pause.upperBound }.count
            #expect(abs(after - expectedAfter) <= 2, "再開の後 \(after)枚、試作 \(expectedAfter)枚")
        }
    }

    /// 手元で書き出した観測の列を全部当て、結果を返すまでの遅れと起点ごとに、試作の決定と食い違うフレームの数を出す。
    /// 渡し方: `KIKIGAKI_SCREEN_REPLAY_DIR=<書き出したJSONのディレクトリ>`
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KIKIGAKI_SCREEN_REPLAY_DIR"] != nil, "手元の観測の列のディレクトリを渡したときだけ"))
    func 手元の観測の列で保存の完了の遅れの影響を測る() throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KIKIGAKI_SCREEN_REPLAY_DIR"]))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let cases: [(String, Delivery)] = [0.25, 0.5, 1.0, 2.0].flatMap { delay in
            [("成功\(delay)秒", Delivery(delay: delay, origin: .success)), ("決定\(delay)秒", Delivery(delay: delay, origin: .decision))]
        }
        var totals = [Int](repeating: 0, count: cases.count)
        var saves = 0
        for file in files {
            let fixture = try Self.load(url: file)
            saves += fixture.decisions.count
            var row = "\(file.deletingPathExtension().lastPathComponent) 試作\(fixture.decisions.count)枚"
            for (index, (name, delivery)) in cases.enumerated() {
                let diff = Self.mismatch(try Self.replay(fixture, delivery), fixture.decisions)
                totals[index] += diff
                row += " \(name)=\(diff)"
            }
            print("[遅れ] " + row)
        }
        print("[遅れ] 計 試作\(saves)枚 " + zip(cases, totals).map { "\($0.0)=\($1)" }.joined(separator: " "))
    }

    @Test(.enabled(if: localFixture != nil, "KIKIGAKI_SCREEN_REPLAY_FIXTURE で手元の観測の列を渡したときだけ"))
    func 手元の観測の列でも試作と同じ時刻に同じ理由で保存を決める() throws {
        try Self.expectSameDecisions(try Self.load(url: URL(fileURLWithPath: try #require(Self.localFixture))))
    }

    /// 実画面の記録 real-obs-01。13ページのスライドは右下の画像が動き続け、左下の画像が約3.5秒ごとに入れ替わる。
    /// 区間は検証記録 docs/records/screen-motion-alternation.md の「場面の区間と正解」
    @Test(.enabled(if: localFixture != nil, "KIKIGAKI_SCREEN_REPLAY_FIXTURE で手元の観測の列を渡したときだけ"))
    func 実画面の記録で12枚を撮り_13ページの2回の区間はどちらも1から2枚() throws {
        let fixture = try Self.load(url: URL(fileURLWithPath: try #require(Self.localFixture)))
        // 区間はreal-obs-01の観測の番号なので、ほかの記録では見ない。
        guard fixture.source == "real-obs-01" else { return }
        let decisions = try Self.replay(fixture)
        #expect(decisions.count == 12)
        let frames = decisions.map(\.frame)
        // 13ページの1回目は観測14〜90、2回目は観測103〜158。
        let first = frames.filter { (14...90).contains($0) }.count, second = frames.filter { (103...158).contains($0) }.count
        #expect((1...2).contains(first) && (1...2).contains(second))
        // 全画面の動画(観測183〜245)は、動き続けて撮った1枚だけ。
        #expect(decisions.filter { (183...245).contains($0.frame) }.map(\.reason) == ["moving"])
    }
}
