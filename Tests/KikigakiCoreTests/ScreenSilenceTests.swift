import Foundation
import Testing
@testable import KikigakiCore

/// 無音の間の画面の保留。音量のトラックで声を決め、無音の間は最後の1枚だけを話し始めに出す。
@Suite struct ScreenSilenceTests {
    private let voice = VoiceActivity(thresholdDBFS: AudioExclusion().thresholdDBFS)

    /// 0.1秒のウィンドウの音量。区間の秒で声を指定し、ほかは無音にする。
    private func levels(until end: Double, voiced: [ClosedRange<Double>] = []) -> [Double?] {
        (0..<Int((end * 10).rounded())).map { index in
            let center = (Double(index) + 0.5) / 10
            return voiced.contains { $0.contains(center) } ? -20 : -60
        }
    }

    /// 受付の番号を振りながら保留へ渡す。届く順は受付の順と同じ。
    private struct Feed {
        var hold = ScreenSilenceHold<String>()
        /// 受け付けた自動の保存の数。
        var accepted = 0
        /// 届いた数。受け付けた数との差が、まだ届いていない保存。
        var arrived = 0
        var outstanding: Bool { arrived < accepted }

        mutating func accept(_ count: Int = 1) { accepted += count }
        mutating func arrive(_ name: String, at time: Double) {
            if arrived == accepted { accepted += 1 }
            hold.receive(name, at: time, sequence: arrived)
            arrived += 1
        }
        mutating func advance(_ levels: [Double?], _ voice: VoiceActivity) -> ScreenSilenceHold<String>.Outcome {
            hold.advance(levels: levels, voice: voice, outstanding: outstanding)
        }
        mutating func release(_ levels: [Double?], _ voice: VoiceActivity) -> ScreenSilenceHold<String>.Outcome {
            hold.release(below: accepted, levels: levels, voice: voice)
        }
    }

    @Test func 過去3秒にかかるウィンドウを調べ_録音の頭では0秒より前を見ない() {
        #expect(VoiceActivity.defaultSilenceSeconds == 3)
        #expect(voice.windows(endingAt: 5) == 20..<50)
        #expect(voice.windows(endingAt: 1.05) == 0..<11)
        #expect(voice.windows(endingAt: 0) == 0..<0)
    }

    @Test func しきい値は小音量の除外と同じで_欠測は声とみなさない() {
        #expect(voice.thresholdDBFS == -45)
        #expect(voice.isVoice(-45) && !voice.isVoice(-45.1) && !voice.isVoice(nil))
    }

    @Test func 話している間の画面はすぐ出す() {
        var feed = Feed()
        feed.arrive("A", at: 4)
        let outcome = feed.advance(levels(until: 5, voiced: [3.5...5]), voice)
        #expect(outcome.publish == ["A"] && outcome.discard.isEmpty && feed.hold.isEmpty)
    }

    @Test func 無音の間は最後の1枚だけを保留し_話し始めに出す() {
        var feed = Feed()
        for (name, time) in [("A", 0.05), ("B", 1.9), ("C", 4.1), ("D", 7.0)] { feed.arrive(name, at: time) }
        var outcome = feed.advance(levels(until: 12), voice)
        #expect(outcome.publish.isEmpty && outcome.discard == ["A", "B", "C"] && feed.hold.count == 1)
        // 声が来るまでは出さない。
        outcome = feed.advance(levels(until: 13), voice)
        #expect(outcome.publish.isEmpty && outcome.discard.isEmpty)
        outcome = feed.advance(levels(until: 13.5, voiced: [13...14]), voice)
        #expect(outcome.publish == ["D"] && feed.hold.isEmpty)
    }

    @Test func 音量が観測位置まで届く前は無音と決めない() {
        var feed = Feed()
        feed.arrive("X", at: 4)
        // 2秒までしか届いていない。無音でも保留へ回さず待つ。
        #expect(feed.advance(levels(until: 2), voice).publish.isEmpty)
        #expect(feed.hold.supersede(below: 0).isEmpty && feed.hold.count == 1)
        // 観測の直前に話していたと後から分かれば、話している間の画面として出す。
        #expect(feed.advance(levels(until: 4, voiced: [3.5...4]), voice).publish == ["X"])
        // 届いている分にすでに声があれば、残りを待たずに出す。
        feed.arrive("Y", at: 8)
        #expect(feed.advance(levels(until: 6, voiced: [3.5...6]), voice).publish == ["Y"])
        // 判定の範囲より手前までしか届いていなくても待つ。
        feed.arrive("Z", at: 20)
        #expect(feed.advance(levels(until: 6), voice).publish.isEmpty && feed.hold.count == 1)
    }

    @Test func 保留の古い1枚と話し始めの新しい1枚を受付の順に出す() {
        var feed = Feed()
        feed.arrive("old", at: 5)
        _ = feed.advance(levels(until: 6), voice)
        #expect(feed.hold.count == 1)
        // 話し始めの直後に撮れた画面と、話し始めを同じ更新で知る。
        feed.arrive("new", at: 9)
        let outcome = feed.advance(levels(until: 9.5, voiced: [8...9.5]), voice)
        #expect(outcome.publish == ["old", "new"] && outcome.discard.isEmpty)
        // しきい値を変えて前後の判定が食い違っても、受付の順を保つ。
        var changed = Feed()
        changed.arrive("old", at: 5)
        _ = changed.advance(levels(until: 6), voice)
        changed.arrive("new", at: 6)
        let louder = VoiceActivity(thresholdDBFS: -70)
        #expect(changed.advance(levels(until: 6), louder).publish == ["old", "new"])
    }

    @Test func 話し始めがまだ届いていない保存を追い越しても_無音の区間から1枚だけ出す() {
        var feed = Feed()
        feed.arrive("A", at: 5)
        _ = feed.advance(levels(until: 6), voice)
        // 無音の中で次のBを受け付けた。符号化している間に声が届く。
        feed.accept()
        let early = feed.advance(levels(until: 8, voiced: [7...8]), voice)
        #expect(early.publish.isEmpty && feed.hold.count == 1)
        // Bは声より前に観測した無音の中の画面。Aと置き換わり、話し始めにBだけを出す。
        feed.hold.receive("B", at: 6.5, sequence: 1); feed.arrived += 1
        let outcome = feed.advance(levels(until: 8, voiced: [7...8]), voice)
        #expect(outcome.publish == ["B"] && outcome.discard == ["A"])
        // 届かないまま失敗した保存は、届いていない数から外れたところで話し始めを進める。
        var failed = Feed()
        failed.arrive("C", at: 5)
        _ = failed.advance(levels(until: 6), voice)
        failed.accept()
        #expect(failed.advance(levels(until: 8, voiced: [7...8]), voice).publish.isEmpty)
        failed.accepted -= 1
        #expect(failed.advance(levels(until: 8, voiced: [7...8]), voice).publish == ["C"])
    }

    @Test func 公開の境界より前に受け付けた保存は_境界の後に届いてもその場で公開する() {
        var feed = Feed()
        feed.arrive("A", at: 5)
        _ = feed.advance(levels(until: 6), voice)
        // Bを受け付けた後、届く前に一時停止した。境界は受け付けた2件の後に引く。
        feed.accept()
        #expect(feed.release(levels(until: 7), voice).publish == ["A"])
        feed.hold.receive("B", at: 6.5, sequence: 1); feed.arrived += 1
        #expect(feed.advance(levels(until: 7), voice).publish == ["B"] && feed.hold.isEmpty)
        // 境界の後に受け付けた画面はふだんの規則に戻る。無音なら保留し、前の公開分を捨てない。
        feed.arrive("C", at: 20)
        let after = feed.advance(levels(until: 21), voice)
        #expect(after.publish.isEmpty && after.discard.isEmpty && feed.hold.count == 1)
    }

    @Test func 送信などの契機では保留も音量待ちも受付の順に全部出す() {
        var feed = Feed()
        feed.arrive("A", at: 2)
        feed.arrive("B", at: 4)
        _ = feed.advance(levels(until: 3), voice)
        #expect(feed.hold.count == 2)
        let outcome = feed.release(levels(until: 3), voice)
        #expect(outcome.publish == ["A", "B"] && outcome.discard.isEmpty && feed.hold.isEmpty)
        // 境界の後に受け付けた分は、決められる分を先に決める。置き換えた古い1枚は出さない。
        feed.arrive("C", at: 1)
        feed.arrive("D", at: 2)
        let decided = feed.release(levels(until: 3), voice)
        #expect(decided.publish == ["D"] && decided.discard == ["C"])
    }

    @Test func いま撮るは押す前に受け付けた保留だけを捨て_会議の切替では全部捨てる() {
        var feed = Feed()
        feed.arrive("held", at: 1)
        _ = feed.advance(levels(until: 2), voice)
        // 押した時点では1件だけ受け付けていた。押した後に受け付けた保留は、手動の完了が遅れても残す。
        let pressed = feed.accepted
        feed.arrive("later", at: 1.5)
        _ = feed.advance(levels(until: 2), voice)
        #expect(feed.hold.count == 1)
        #expect(feed.hold.supersede(below: pressed).isEmpty && feed.hold.count == 1)
        // 押す前に受け付けて、押した後に届いた無音の中の画面は保留しない。
        var late = Feed()
        late.accept()
        _ = late.hold.supersede(below: late.accepted)
        late.hold.receive("before", at: 1, sequence: 0); late.arrived += 1
        #expect(late.advance(levels(until: 2), voice).discard == ["before"] && late.hold.isEmpty)
        // 押す前に受け付けた保留は捨てる。
        var dropped = Feed()
        dropped.arrive("held", at: 1)
        _ = dropped.advance(levels(until: 2), voice)
        #expect(dropped.hold.supersede(below: dropped.accepted) == ["held"] && dropped.hold.isEmpty)
        // 会議の切替では全部捨て、境界も忘れる。
        feed.arrive("waiting", at: 5)
        #expect(feed.hold.removeAll() == ["later", "waiting"] && feed.hold.isEmpty)
        feed.hold.receive("next meeting", at: 1, sequence: 0)
        #expect(feed.hold.advance(levels: levels(until: 2), voice: voice, outstanding: false).discard.isEmpty && feed.hold.count == 1)
    }

    /// 試用の会議の `.levels.json` へ当て、設計案の見積もりと照らす。会議の本文を含むのでリポジトリには置かず、
    /// `KIKIGAKI_SCREEN_SILENCE_TRIAL` にパスを渡したときだけ動く。
    /// - 見積もり: 15枚 → 12枚。記録は docs/records/screen-silence-estimate.md
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KIKIGAKI_SCREEN_SILENCE_TRIAL"] != nil))
    func 試用の会議の音量と画面の位置へ当てる() throws {
        let path = try #require(ProcessInfo.processInfo.environment["KIKIGAKI_SCREEN_SILENCE_TRIAL"])
        let report = try JSONDecoder().decode(AudioLevelReport.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let voice = VoiceActivity(thresholdDBFS: report.audioExclusion?.thresholdDBFS ?? AudioExclusion().thresholdDBFS)
        let screens = report.utterances.filter { $0.kind == .screen && $0.screenEvent == nil }.map(\.start)
        // 録音中と同じく、ウィンドウが1つ届くごとに決める。画面は観測位置まで音声を受け付けた時点で届く。
        var hold = ScreenSilenceHold<Double>()
        var published: [Double] = [], discarded: [Double] = []
        var next = 0
        for count in 0...report.track.levels.count {
            while next < screens.count, screens[next] <= Double(count) / 10 { hold.receive(screens[next], at: screens[next], sequence: next); next += 1 }
            let outcome = hold.advance(levels: Array(report.track.levels.prefix(count)), voice: voice, outstanding: false)
            published += outcome.publish; discarded += outcome.discard
        }
        while next < screens.count { hold.receive(screens[next], at: screens[next], sequence: next); next += 1 }
        let last = hold.release(below: screens.count, levels: report.track.levels, voice: voice)
        published += last.publish; discarded += last.discard
        print("[screen-silence-trial] screens=\(screens.count) published=\(published.count) discarded=\(discarded.map { String(format: "%.1f", $0) })")
        #expect(screens.count == 15)
        #expect(published.count == 12)
        #expect(published == published.sorted())
    }
}
