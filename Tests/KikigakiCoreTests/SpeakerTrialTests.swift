import Foundation
import Testing
@testable import KikigakiCore

@Suite struct SpeakerTrialOptionsTests {
    @Test func 点判定は中央を含む区間だけを見て同時発話は番号の小さい話者() {
        let segments = [SpeakerSegment(speaker: 1, start: 0.5, end: 2), SpeakerSegment(speaker: 0, start: 0, end: 1)]
        #expect(Aligner.pointSpeaker(at: 0.5, segments: segments) == 0)
        // 半開区間。終端ちょうどは含まない
        #expect(Aligner.pointSpeaker(at: 1.0, segments: segments) == 1)
        #expect(Aligner.pointSpeaker(at: 2.0, segments: segments) == nil)
        #expect(Aligner.pointSpeaker(at: -0.1, segments: segments) == nil)
        // 窓判定は前後0.5秒の重なりで決まり、中央に区間が無くても話者を返す
        let gap = [SpeakerSegment(speaker: 2, start: 0, end: 0.9)]
        #expect(Aligner.pointSpeaker(at: 1.0, segments: gap) == nil)
        #expect(Aligner.speaker(at: 1.0, segments: gap) == 2)
    }

    @Test func プリセットの名前を解釈する() {
        for name in Aligner.Options.presetNames { #expect(Aligner.Options.preset(name) != nil, "\(name)") }
        #expect(Aligner.Options.preset("current") == .current)
        #expect(Aligner.Options.preset("current-tail")?.tail == false)
        #expect(Aligner.Options.preset("current-tail")?.word == true)
        #expect(Aligner.Options.preset("current-foo") == nil)
        #expect(Aligner.Options.preset("none") == nil)
        let none = Aligner.Options.window
        #expect(!none.tail && !none.evidence && !none.word && !none.absorb && !none.protect && !none.punct)
        #expect(Aligner.Options.point.assignment == .point)
    }

    @Test func 試験変数が無ければ本番と同じで不正な値は止める() throws {
        let empty = try SpeakerTrial.Settings(environment: [:])
        #expect(!empty.isActive && empty.options == .current && empty.freeze == .grace30 && empty.dumpDirectory == nil)
        let set = try SpeakerTrial.Settings(environment: ["KIKIGAKI_TRIAL_ALIGNER": "window", "KIKIGAKI_TRIAL_FREEZE": "phrase"])
        #expect(set.isActive && set.options == .window && set.freeze == .phrase)
        #expect(throws: SpeakerTrial.Settings.Invalid.self) { try SpeakerTrial.Settings(environment: ["KIKIGAKI_TRIAL_ALIGNER": "none"]) }
        #expect(throws: SpeakerTrial.Settings.Invalid.self) { try SpeakerTrial.Settings(environment: ["KIKIGAKI_TRIAL_FREEZE": "30"]) }
    }

    @Test func 補正なしでは句読点も長い1文字も元の判定のまま() {
        // 句点が次の発話の頭に食い込み、窓判定で別話者になる形
        let tokens = [TimedToken(text: "そうです", phraseId: 1, start: 0, end: 1.0),
                      TimedToken(text: "。", phraseId: 1, start: 1.0, end: 1.6)]
        let segments = [SpeakerSegment(speaker: 0, start: 0, end: 1.0), SpeakerSegment(speaker: 1, start: 1.0, end: 3)]
        #expect(Aligner.speakers(for: tokens, segments: segments) == [0, 0])
        #expect(Aligner.speakers(for: tokens, segments: segments, options: .window) == [0, 1])
        // 句読点の付替えだけを外しても、短い島の吸収が同じ句点を直前の話者へ戻す
        #expect(Aligner.speakers(for: tokens, segments: segments, options: .preset("current-punct")!) == [0, 0])
        #expect(Aligner.speakers(for: tokens, segments: segments, options: .preset("current-absorb")!) == [0, 0])
        // 既定値の呼び出しは .current と同じ
        let fixture = RecordedSpeakerFixtures.iBoku
        #expect(Aligner.speakers(for: fixture.tokens, segments: fixture.segments)
                == Aligner.speakers(for: fixture.tokens, segments: fixture.segments, options: .current))
    }

    /// 旧区間の実録事例で、補正を1つずつ外すと期待が保てなくなる箇所を固定する。
    /// Sortformer 時代の区間なので、その補正が当時の事例に効いていたことだけを示す
    @Test func 旧fixtureの補正ごとの効き目の行列() {
        var table: [String: [String: Bool]] = [:]
        for fixture in RecordedSpeakerFixtures.all {
            for name in Aligner.Options.presetNames {
                let options = Aligner.Options.preset(name)!
                let result = fixture.segments.isEmpty
                    ? (name == "point" ? nil : Aligner.smoothSpeakers(tokens: fixture.tokens, speakers: fixture.raw, options: options))
                    : Aligner.speakers(for: fixture.tokens, segments: fixture.segments, options: options)
                table[fixture.name, default: [:]][name] = result.map { $0 == fixture.expected }
            }
        }
        var lines = ["| 事例 | 録音 | " + Aligner.Options.presetNames.joined(separator: " | ") + " |",
                     "|---|---|" + String(repeating: "---|", count: Aligner.Options.presetNames.count)]
        for fixture in RecordedSpeakerFixtures.all {
            lines.append("| \(fixture.name) | \(fixture.recording) | " + Aligner.Options.presetNames.map {
                table[fixture.name]?[$0].map { $0 ? "○" : "×" } ?? "—"
            }.joined(separator: " | ") + " |")
        }
        if let path = ProcessInfo.processInfo.environment["KIKIGAKI_TRIAL_FIXTURE_REPORT"] {
            try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        for fixture in RecordedSpeakerFixtures.all { #expect(table[fixture.name]?["current"] == true, "\(fixture.name)") }
        #expect(table["じゃあ/そう"]?["current-word"] == false)
        #expect(table["はい/すごいね。"]?["current-protect"] == false)
        #expect(table["代表"]?["current-absorb"] == false)
        #expect(table["い/僕"]?["current-tail"] == false)
    }
}

@Suite struct PhraseFreezeTests {
    private func token(_ text: String, _ start: Double, _ end: Double, phrase: Int = 1) -> TimedToken {
        TimedToken(text: text, phraseId: phrase, start: start, end: end)
    }

    private var tokens: [TimedToken] {
        [token("今日", 0, 0.5), token("は", 0.5, 0.7), token("晴れ。", 0.7, 1.2),
         token("明日", 2.0, 2.4, phrase: 2), token("も", 2.4, 2.6, phrase: 2)]
    }
    private let speakers: [Int?] = [0, 0, 0, 0, 0, 0]

    @Test func 文末で閉じたフレーズは窓の先まで判定済みになってから凍結する() {
        let tokens = self.tokens
        // 最後の「晴れ。」の中央0.95+0.5秒まで区間が届く必要がある
        #expect(SpeakerFreeze.advanceByPhrase(frozen: [], speakers: speakers, tokens: tokens, accurateFinalCount: 3,
                                              judgedUntil: 1.44).isEmpty)
        #expect(SpeakerFreeze.advanceByPhrase(frozen: [], speakers: speakers, tokens: tokens, accurateFinalCount: 3,
                                              judgedUntil: 1.45).count == 3)
        // 点判定は窓の先を読まないので、終端まで判定済みなら足りる
        #expect(SpeakerFreeze.advanceByPhrase(frozen: [], speakers: speakers, tokens: tokens, accurateFinalCount: 3,
                                              judgedUntil: 1.2, options: .point).count == 3)
    }

    @Test func 間で閉じるフレーズは次のトークンが高精度で確定するまで待つ() {
        var tokens = self.tokens
        #expect(SpeakerFreeze.advanceByPhrase(frozen: [], speakers: speakers, tokens: tokens, accurateFinalCount: 5,
                                              judgedUntil: 100).count == 3)
        // 速報のトークンは差し替わるので終端の根拠にしない
        tokens.append(token("雨", 3.5, 3.9, phrase: ~3))
        #expect(SpeakerFreeze.advanceByPhrase(frozen: [], speakers: speakers, tokens: tokens, accurateFinalCount: 5,
                                              judgedUntil: 100).count == 3)
        tokens[5] = token("雨", 3.5, 3.9, phrase: 3)
        #expect(SpeakerFreeze.advanceByPhrase(frozen: [], speakers: speakers, tokens: tokens, accurateFinalCount: 6,
                                              judgedUntil: 100).count == 5)
        // フレーズの途中までしか確定していなければ、そのフレーズは凍結しない
        #expect(SpeakerFreeze.advanceByPhrase(frozen: [], speakers: speakers, tokens: tokens, accurateFinalCount: 4,
                                              judgedUntil: 100).count == 3)
    }

    @Test func 語頭の付け替えが読む後続文字はtail有効のときだけ待つ() {
        let tokens = [token("え", 10, 11.5), token("。", 11.5, 11.6),
                      token("い", 11.7, 11.9, phrase: 2), token("や", 11.9, 12.0, phrase: 2), token("。", 12.0, 12.1, phrase: 2)]
        let speakers: [Int?] = [1, 1, 2, 2, 2]
        func freeze(_ accurate: Int, _ judged: Double, _ options: Aligner.Options = .current, _ values: [TimedToken]? = nil) -> Int {
            let values = values ?? tokens
            return SpeakerFreeze.advanceByPhrase(frozen: [], speakers: Array(speakers.prefix(values.count)), tokens: values,
                                                 accurateFinalCount: accurate, judgedUntil: judged, options: options).count
        }
        // 後続の有意文字がまだ無い
        #expect(freeze(2, 100, .current, Array(tokens.prefix(2))) == 0)
        // 後続はあるが高精度で未確定
        #expect(freeze(2, 100) == 0)
        // 後続が確定しても、その中央+0.5秒(12.3)まで区間が届いていない
        #expect(freeze(3, 12.29) == 0)
        #expect(freeze(3, 12.3) == 2)
        // tailを外した条件では後続を待たない
        #expect(freeze(2, 12.1, .preset("current-tail")!) == 2)
        #expect(freeze(2, 12.1, .window) == 2)
    }

    @Test func 窓の先の区間が届く前に凍結すると後で話者が変わる() {
        // 終端までの判定済みで固めた場合の反例。条件4の窓の先が要る根拠
        let tokens = [token("あ", 0, 0.2), token("。", 0.2, 0.3)]
        let early = [SpeakerSegment(speaker: 1, start: 0, end: 0.3)]
        let late = [SpeakerSegment(speaker: 1, start: 0, end: 0.3), SpeakerSegment(speaker: 0, start: 0.3, end: 1.0)]
        #expect(Aligner.speakers(for: tokens, segments: early) != Aligner.speakers(for: tokens, segments: late))
        #expect(SpeakerFreeze.advanceByPhrase(frozen: [], speakers: [1, 1], tokens: tokens, accurateFinalCount: 2,
                                              judgedUntil: 0.3).isEmpty)
    }

    /// 話者判別を10.24秒のchunkで届け、区間を `SpeakerRuns` で畳み、文字の確定を結果ごとに遅らせた録音を再生する。
    /// chunk境界をまたぐ発話・長い語頭・重なった相槌・速報の差し替えを含む。
    /// フレーズ固定の凍結は、どの補正条件でも後の判定・停止時の判定と食い違ってはならない
    @Test(arguments: Aligner.Options.presetNames)
    func chunk到着の境界でもフレーズ固定の後に話者が変わらない(preset: String) throws {
        let session = SyntheticSession.make()
        let options = Aligner.Options.preset(preset)!
        let metrics = SpeakerTrial.simulate(snapshots: session.snapshots, final: session.final, preset: preset,
                                            options: options, mode: .phrase)
        #expect(metrics.frozenTokens > session.final.tokens.count / 2)
        #expect(metrics.mismatches.isEmpty, "\(metrics.mismatches.prefix(3))")
        #expect(metrics.latentChanges.isEmpty, "\(metrics.latentChanges.prefix(3))")
        try SpeakerTrial.validate(session.snapshots, final: session.final)
    }

    @Test func 合成録音は長い語頭と速報の差し替えを実際に含む() {
        let session = SyntheticSession.make()
        #expect(session.final.tokens.contains { SpeechTail.isLongSingle($0) })
        #expect(session.snapshots.contains { $0.tokens.contains { $0.phraseId < 0 } })
        // 区間が chunk 単位で届く
        #expect(Set(session.snapshots.map(\.judgedUntil)).count >= 5)
    }
}

/// 話者判別と文字起こしの到着を模した録音
private enum SyntheticSession {
    struct Turn { let speaker: Int; let start: Double; let end: Double; let sentenceEnd: Bool }

    static let turns = [
        Turn(speaker: 0, start: 0.5, end: 9.8, sentenceEnd: true),
        Turn(speaker: 1, start: 10.6, end: 20.1, sentenceEnd: false),
        Turn(speaker: 0, start: 20.9, end: 21.5, sentenceEnd: true),
        Turn(speaker: 2, start: 22.4, end: 30.6, sentenceEnd: true),
        Turn(speaker: 1, start: 31.2, end: 40.9, sentenceEnd: false),
        Turn(speaker: 0, start: 41.4, end: 51.0, sentenceEnd: true),
        Turn(speaker: 2, start: 51.6, end: 61.0, sentenceEnd: true),
    ]
    /// 文字には出ない重なった相槌。窓判定に島を作る
    static let overlaps = [(1, 4.0, 4.4), (0, 25.0, 25.3), (2, 45.0, 45.5), (0, 55.1, 55.9)]
    static let duration = 62.0

    static func make() -> (snapshots: [SpeakerTrial.Snapshot], final: SpeakerTrial.FinalRecord) {
        let chars = Array("あいうえおかきくけこさしすせそたちつてとなにぬねの").map(String.init)
        var tokens: [TimedToken] = []
        var phrase = 1
        for turn in turns {
            // 発話前の間を含んで長くなった語頭の1文字
            let lead = max(tokens.last?.end ?? 0, turn.start - 0.9)
            tokens.append(TimedToken(text: "ま", phraseId: phrase, start: lead, end: turn.start + 0.1))
            var t = turn.start + 0.1
            var k = 0
            while t + 0.15 <= turn.end - 0.1 {
                if k % 23 == 22 { t += 0.4; phrase += 1 }
                tokens.append(TimedToken(text: chars[k % chars.count], phraseId: phrase, start: t, end: t + 0.15))
                t += 0.15
                k += 1
            }
            if turn.sentenceEnd { tokens.append(TimedToken(text: "。", phraseId: phrase, start: t, end: t + 0.1)) }
            phrase += 1
        }
        let intervals = turns.map { ($0.speaker, $0.start, $0.end) } + overlaps
        func probabilities(_ frames: Range<Int>) -> [Float] {
            frames.flatMap { frame -> [Float] in
                let time = Double(frame) * SpeakerRuns.frameSeconds
                return (0..<3).map { speaker in
                    intervals.contains { $0.0 == speaker && $0.1 <= time && time < $0.2 } ? 0.9 : 0.1
                }
            }
        }
        var runs = SpeakerRuns(speakerCount: 3)
        var snapshots: [SpeakerTrial.Snapshot] = []
        var fed = 0
        var t = 0.5
        while t < duration {
            // fast128: chunk 10.24秒に右文脈0.32秒が溜まると chunk 全体の判定が出る
            let judged = t >= 10.56 ? Int((t - 0.32) / 10.24) * 1024 : 0
            if judged > fed { runs.append(probabilities(fed..<judged)); fed = judged }
            // 高精度の確定は結果ごとに3〜15秒遅れ、先頭から連続した分だけが確定になる
            var confirmed = 0
            while confirmed < tokens.count {
                let id = tokens[confirmed].phraseId
                let group = tokens[confirmed...].prefix { $0.phraseId == id }
                guard group.last!.end <= t - (3 + Double(id % 5) * 3) else { break }
                confirmed += group.count
            }
            let boundary = confirmed > 0 ? tokens[confirmed - 1].end : 0
            // 速報は少しずれた時刻で先に出て、高精度が確定すると差し替わる
            let fast = tokens[confirmed...].filter { $0.end <= t - 0.3 && $0.start + 0.02 >= boundary }.map {
                TimedToken(text: $0.text, phraseId: ~$0.phraseId, start: $0.start + 0.02, end: $0.end + 0.02)
            }
            snapshots.append(SpeakerTrial.Snapshot(
                elapsed: t, uptime: t, tokens: Array(tokens.prefix(confirmed)) + fast, finalCount: confirmed + fast.count,
                accurateFinalCount: confirmed, judgedUntil: runs.judgedSeconds, segments: runs.segments(until: t)))
            t += 0.5
        }
        let total = Int(duration * 100)
        runs.append(probabilities(fed..<total))
        return (snapshots, SpeakerTrial.FinalRecord(tokens: tokens, segments: runs.segments(until: duration), duration: duration))
    }
}

@Suite struct SpeakerTrialRecordTests {
    private func token(_ text: String, _ start: Double, _ phrase: Int = 1) -> TimedToken {
        TimedToken(text: text, phraseId: phrase, start: start, end: start + 0.2)
    }

    private func snapshot(_ tokens: [TimedToken], accurate: Int, segments: [SpeakerSegment] = [], elapsed: Double = 1) -> SpeakerTrial.Snapshot {
        SpeakerTrial.Snapshot(elapsed: elapsed, uptime: elapsed, tokens: tokens, finalCount: tokens.count,
                              accurateFinalCount: accurate, judgedUntil: 0, segments: segments)
    }

    @Test func 差分の記録から同じsnapshot列を復元する() throws {
        let first = snapshot([token("あ", 0), token("速", 0.2, ~2)], accurate: 1, segments: [.init(speaker: 0, start: 0, end: 1)])
        let second = snapshot([token("あ", 0), token("い", 0.2, 2), token("う", 0.4, 2)], accurate: 3,
                              segments: [.init(speaker: 0, start: 0, end: 1)], elapsed: 1.5)
        var recorder = SpeakerTrial.Recorder()
        let records = [recorder.record(first, frozenAppended: []), recorder.record(second, frozenAppended: [0])]
        #expect(records[1].keep == 1 && records[1].tokens.count == 2 && records[1].segments == nil)
        let encoded = try records.map { try JSONEncoder().encode($0) }
        let decoded = try encoded.map { try JSONDecoder().decode(SpeakerTrial.LiveRecord.self, from: $0) }
        let restored = try SpeakerTrial.snapshots(from: decoded)
        #expect(restored.map(\.tokens) == [first.tokens, second.tokens])
        #expect(restored.map(\.segments) == [first.segments, second.segments])
        #expect(restored.map(\.recordedFrozen) == [[], [0]])
    }

    @Test func 高精度の確定済みが後で変わった記録は比較を無効にする() {
        let first = snapshot([token("あ", 0), token("い", 0.2)], accurate: 2)
        #expect(throws: SpeakerTrial.TrialError.accuratePrefixChanged(record: 1, index: 1)) {
            try SpeakerTrial.validate([first, snapshot([token("あ", 0), token("え", 0.2)], accurate: 2)])
        }
        #expect(throws: SpeakerTrial.TrialError.accuratePrefixChanged(record: 1, index: 1)) {
            try SpeakerTrial.validate([first, snapshot([token("あ", 0)], accurate: 1)])
        }
        #expect(throws: SpeakerTrial.TrialError.finalDiffersFromLive(index: 1)) {
            try SpeakerTrial.validate([first], final: .init(tokens: [token("あ", 0), token("う", 0.2)], segments: [], duration: 1))
        }
        #expect(throws: SpeakerTrial.TrialError.malformed(record: 0)) {
            try SpeakerTrial.snapshots(from: [SpeakerTrial.LiveRecord(elapsed: 0, uptime: 0, keep: 1, tokens: [], finalCount: 0,
                                                                        accurateFinalCount: 0, judgedUntil: 0)])
        }
    }

    @Test func 既知と不明の間の揺れも数える() {
        let tokens = [token("あ", 0)]
        let covered = [SpeakerSegment(speaker: 0, start: 0, end: 1)]
        // 既知 → 不明 → 既知。凍結は起きない時刻
        let snapshots = [snapshot(tokens, accurate: 1, segments: covered), snapshot(tokens, accurate: 1),
                         snapshot(tokens, accurate: 1, segments: covered)]
        let final = SpeakerTrial.FinalRecord(tokens: tokens, segments: covered, duration: 1)
        let metrics = SpeakerTrial.simulate(snapshots: snapshots, final: final, preset: "point", options: .point, mode: .grace30)
        #expect(metrics.flipsBeforeFreeze == 2)
        #expect(metrics.frozenTokens == 0 && metrics.unfrozenTokens == 1 && metrics.heldConfirmedTokens == 1)
    }

    @Test func 記録した凍結列と再生が一致するか照合する() {
        let tokens = [token("はい。", 0)]
        let covered = [SpeakerSegment(speaker: 0, start: 0, end: 1)]
        func run(_ recorded: [Int?]) -> Bool? {
            var value = snapshot(tokens, accurate: 1, segments: covered)
            value.judgedUntil = 1
            value.recordedFrozen = recorded
            return SpeakerTrial.simulate(snapshots: [value], final: .init(tokens: tokens, segments: covered, duration: 1),
                                         preset: "current", options: .current, mode: .phrase, checksReproduction: true).reproduced
        }
        #expect(run([0]) == true)
        #expect(run([1]) == false)
        #expect(run([]) == false)
    }

    @Test func 比較のMarkdownに対象範囲と差分の本文を出す() {
        let tokens = [TimedToken(text: "そうです", phraseId: 1, start: 0, end: 1.0),
                      TimedToken(text: "。", phraseId: 1, start: 1.0, end: 1.6)]
        let segments = [SpeakerSegment(speaker: 0, start: 0, end: 1.0), SpeakerSegment(speaker: 1, start: 1.0, end: 3)]
        let comparison = SpeakerTrial.compare(
            source: "例", final: .init(tokens: tokens, segments: segments, duration: 3), snapshots: [],
            presets: ["current", "window"], livePresets: [], expectations: [.init(start: 0, end: 2, speaker: 0)],
            names: [0: "司会"], repeats: 1)
        #expect(comparison.final.map(\.changedTokens) == [0, 1])
        #expect(comparison.final.map { $0.expectations.first?.matchedLetters } == [4, 4])
        let markdown = SpeakerTrial.markdown(comparison, names: [0: "司会"], meta: nil)
        #expect(markdown.contains("繰り返し相槌の省略はこの比較では全条件で無効"))
        #expect(markdown.contains("current: 司会: そうです。"))
        #expect(markdown.contains("window: 司会: そうです / B: 。"))
        #expect(SpeakerTrial.Expectation(argument: "45.24-47.94=2") == .init(start: 45.24, end: 47.94, speaker: 2))
        #expect(SpeakerTrial.Expectation(argument: "47-45=2") == nil)
    }
}
