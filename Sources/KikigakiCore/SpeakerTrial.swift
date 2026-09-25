import Foundation

/// 話者補正の除外比較とフレーズ固定の試験。本番の判定は変えない。
/// 1回の録音(replay)で得た入力を保存し、全条件を同じ入力へ当てて差だけを見る。
/// 設計: docs/speaker-correction-trial.md
public enum SpeakerTrial {
    /// 試験の環境変数。アプリはDEBUGビルドだけで読む
    /// - `KIKIGAKI_TRIAL_ALIGNER`: `Aligner.Options.presetNames` のどれか
    /// - `KIKIGAKI_TRIAL_FREEZE`: `grace30` / `phrase`
    /// - `KIKIGAKI_TRIAL_DUMP`: 比較用の入力を書き出す先。会話本文を含む
    public struct Settings: Equatable, Sendable {
        public var preset: String
        public var options: Aligner.Options
        public var freeze: SpeakerFreeze.Mode
        public var dumpDirectory: String?
        public var isActive: Bool

        public struct Invalid: Error, CustomStringConvertible {
            public let description: String
        }

        public init(environment: [String: String]) throws {
            let preset = environment["KIKIGAKI_TRIAL_ALIGNER"] ?? "current"
            guard let options = Aligner.Options.preset(preset) else {
                throw Invalid(description: "KIKIGAKI_TRIAL_ALIGNER=\(preset) は不明。候補: \(Aligner.Options.presetNames.joined(separator: ", "))")
            }
            let freezeName = environment["KIKIGAKI_TRIAL_FREEZE"] ?? SpeakerFreeze.Mode.grace30.rawValue
            guard let freeze = SpeakerFreeze.Mode(rawValue: freezeName) else {
                throw Invalid(description: "KIKIGAKI_TRIAL_FREEZE=\(freezeName) は不明。候補: grace30, phrase")
            }
            let dump = environment["KIKIGAKI_TRIAL_DUMP"].flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
            self.preset = preset
            self.options = options
            self.freeze = freeze
            dumpDirectory = dump
            isActive = ["KIKIGAKI_TRIAL_ALIGNER", "KIKIGAKI_TRIAL_FREEZE", "KIKIGAKI_TRIAL_DUMP"].contains { environment[$0] != nil }
        }
    }

    /// 記録の由来。等倍と加速で待ちの意味が違うため、比較の表へ出す
    public struct Meta: Codable, Equatable, Sendable {
        public var pace: String
        public var preset: String
        public var freeze: String

        public init(pace: String, preset: String, freeze: String) {
            self.pace = pace
            self.preset = preset
            self.freeze = freeze
        }
    }

    /// 録音中の描画1回分。トークンは直前の記録との共通接頭辞数 `keep` と、それ以降だけを持つ。
    /// 区間は変わったときだけ持つ
    public struct LiveRecord: Codable, Equatable, Sendable {
        public var elapsed: Double
        public var uptime: Double
        public var keep: Int
        public var tokens: [TimedToken]
        public var finalCount: Int
        public var accurateFinalCount: Int
        public var judgedUntil: Double
        public var segments: [SpeakerSegment]?
        /// アプリがこの描画で新しく凍結した話者。再生が実際の表示と一致するかの照合に使う
        public var frozenAppended: [Int?]?
    }

    /// 停止時の最終判定の入力
    public struct FinalRecord: Codable, Equatable, Sendable {
        public var tokens: [TimedToken]
        public var segments: [SpeakerSegment]
        public var duration: Double

        public init(tokens: [TimedToken], segments: [SpeakerSegment], duration: Double) {
            self.tokens = tokens
            self.segments = segments
            self.duration = duration
        }
    }

    /// 録音中の突き合わせループが見た入力
    public struct Snapshot: Equatable, Sendable {
        public var elapsed: Double
        public var uptime: Double
        public var tokens: [TimedToken]
        public var finalCount: Int
        public var accurateFinalCount: Int
        public var judgedUntil: Double
        public var segments: [SpeakerSegment]
        /// 記録にあれば、アプリがこの描画の後に持っていた凍結列
        public var recordedFrozen: [Int?]?

        public init(elapsed: Double, uptime: Double, tokens: [TimedToken], finalCount: Int, accurateFinalCount: Int,
                    judgedUntil: Double, segments: [SpeakerSegment], recordedFrozen: [Int?]? = nil) {
            self.elapsed = elapsed
            self.uptime = uptime
            self.tokens = tokens
            self.finalCount = finalCount
            self.accurateFinalCount = accurateFinalCount
            self.judgedUntil = judgedUntil
            self.segments = segments
            self.recordedFrozen = recordedFrozen
        }
    }

    public enum TrialError: Error, Equatable, CustomStringConvertible {
        case malformed(record: Int)
        /// 高精度側の確定済み接頭辞が後で変わった。凍結の前提が崩れるので比較を無効にする
        case accuratePrefixChanged(record: Int, index: Int)
        /// 停止時のトークンが録音中の確定済み接頭辞と食い違った
        case finalDiffersFromLive(index: Int)

        public var description: String {
            switch self {
            case .malformed(let record): "live記録 \(record) 行目の keep が不正"
            case .accuratePrefixChanged(let record, let index): "live記録 \(record) 行目で高精度の確定済みトークン \(index) が変わった"
            case .finalDiffersFromLive(let index): "停止時のトークン \(index) が録音中の確定済みと食い違った"
            }
        }
    }

    /// 差分で記録する
    public struct Recorder: Sendable {
        private var previousTokens: [TimedToken] = []
        private var previousSegments: [SpeakerSegment]?

        public init() {}

        public mutating func record(_ snapshot: Snapshot, frozenAppended: [Int?]? = nil) -> LiveRecord {
            let limit = min(previousTokens.count, snapshot.tokens.count)
            var keep = 0
            while keep < limit && previousTokens[keep] == snapshot.tokens[keep] { keep += 1 }
            let segments = snapshot.segments == previousSegments ? nil : snapshot.segments
            previousTokens = snapshot.tokens
            previousSegments = snapshot.segments
            return LiveRecord(elapsed: snapshot.elapsed, uptime: snapshot.uptime, keep: keep,
                              tokens: Array(snapshot.tokens.dropFirst(keep)), finalCount: snapshot.finalCount,
                              accurateFinalCount: snapshot.accurateFinalCount, judgedUntil: snapshot.judgedUntil,
                              segments: segments, frozenAppended: frozenAppended)
        }
    }

    /// 記録を復元し、確定済み接頭辞が不変であることを確かめる
    public static func snapshots(from records: [LiveRecord], final: FinalRecord? = nil) throws -> [Snapshot] {
        var tokens: [TimedToken] = []
        var segments: [SpeakerSegment] = []
        var frozen: [Int?]? = nil
        var result: [Snapshot] = []
        for (index, record) in records.enumerated() {
            guard record.keep >= 0, record.keep <= tokens.count else { throw TrialError.malformed(record: index) }
            tokens = Array(tokens.prefix(record.keep)) + record.tokens
            if let changed = record.segments { segments = changed }
            if let appended = record.frozenAppended { frozen = (frozen ?? []) + appended }
            result.append(Snapshot(elapsed: record.elapsed, uptime: record.uptime, tokens: tokens,
                                   finalCount: record.finalCount, accurateFinalCount: record.accurateFinalCount,
                                   judgedUntil: record.judgedUntil, segments: segments, recordedFrozen: frozen))
        }
        try validate(result, final: final)
        return result
    }

    public static func validate(_ snapshots: [Snapshot], final: FinalRecord? = nil) throws {
        var confirmed: [TimedToken] = []
        for (index, snapshot) in snapshots.enumerated() {
            let count = min(max(snapshot.accurateFinalCount, 0), snapshot.tokens.count)
            guard count >= confirmed.count else { throw TrialError.accuratePrefixChanged(record: index, index: count) }
            if let changed = confirmed.indices.first(where: { confirmed[$0] != snapshot.tokens[$0] }) {
                throw TrialError.accuratePrefixChanged(record: index, index: changed)
            }
            confirmed = Array(snapshot.tokens.prefix(count))
        }
        if let final {
            guard final.tokens.count >= confirmed.count else { throw TrialError.finalDiffersFromLive(index: final.tokens.count) }
            if let changed = confirmed.indices.first(where: { confirmed[$0] != final.tokens[$0] }) {
                throw TrialError.finalDiffersFromLive(index: changed)
            }
        }
    }

    // MARK: - 最終判定

    /// 正解が分かっている区間。区間内に中央があるトークンの文字が `speaker` に付いた割合を数える
    public struct Expectation: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var speaker: Int

        public init(start: Double, end: Double, speaker: Int) {
            self.start = start
            self.end = end
            self.speaker = speaker
        }

        /// `45.24-47.94=2` の形
        public init?(argument: String) {
            let parts = argument.split(separator: "=")
            guard parts.count == 2, let speaker = Int(parts[1]) else { return nil }
            let range = parts[0].split(separator: "-")
            guard range.count == 2, let start = Double(range[0]), let end = Double(range[1]), start < end else { return nil }
            self.init(start: start, end: end, speaker: speaker)
        }
    }

    public struct ExpectationResult: Codable, Equatable, Sendable {
        public var expectation: Expectation
        public var matchedLetters: Int
        public var totalLetters: Int
    }

    public struct FinalMetrics: Codable, Equatable, Sendable {
        public var preset: String
        public var tokens: Int
        public var letters: Int
        /// 基準(`current`)と話者が違うトークン数と文字数
        public var changedTokens: Int
        public var changedLetters: Int
        public var utterances: Int
        /// 有意文字を持つ隣り合うトークンの話者が変わる回数。不明も1つの値として数える
        public var switches: Int
        /// 有意文字が1〜2字の行
        public var fragments: Int
        /// 句読点だけの行
        public var punctuationOnly: Int
        public var unknownLetters: Int
        /// 判定1回の処理時間の中央値(ミリ秒)
        public var milliseconds: Double
        public var expectations: [ExpectationResult]
    }

    static func letters(_ token: TimedToken) -> Int { token.text.filter { $0.isLetter || $0.isNumber }.count }

    public static func finalMetrics(preset: String, tokens: [TimedToken], speakers: [Int?], base: [Int?],
                                    milliseconds: Double, expectations: [Expectation]) -> FinalMetrics {
        let changed = tokens.indices.filter { speakers[$0] != base[$0] }
        let lettered = tokens.indices.filter { letters(tokens[$0]) > 0 }
        let switches = zip(lettered, lettered.dropFirst()).filter { speakers[$0.0] != speakers[$0.1] }.count
        let ranges = Aligner.utteranceTokenRanges(tokens: tokens, speakers: speakers)
        let rowLetters = ranges.map { $0.reduce(0) { $0 + letters(tokens[$1]) } }
        return FinalMetrics(
            preset: preset, tokens: tokens.count, letters: tokens.reduce(0) { $0 + letters($1) },
            changedTokens: changed.count, changedLetters: changed.reduce(0) { $0 + letters(tokens[$1]) },
            utterances: ranges.count, switches: switches,
            fragments: rowLetters.filter { (1...2).contains($0) }.count,
            punctuationOnly: rowLetters.filter { $0 == 0 }.count,
            unknownLetters: tokens.indices.filter { speakers[$0] == nil }.reduce(0) { $0 + letters(tokens[$1]) },
            milliseconds: milliseconds,
            expectations: expectations.map { expectation in
                let inside = tokens.indices.filter { (expectation.start...expectation.end).contains(tokens[$0].midpoint) }
                return ExpectationResult(
                    expectation: expectation,
                    matchedLetters: inside.filter { speakers[$0] == expectation.speaker }.reduce(0) { $0 + letters(tokens[$1]) },
                    totalLetters: inside.reduce(0) { $0 + letters(tokens[$1]) })
            })
    }

    // MARK: - 録音中

    public struct Stats: Codable, Equatable, Sendable {
        public var count: Int
        public var median: Double
        public var p90: Double
        public var max: Double

        init?(_ values: [Double]) {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            func rank(_ p: Double) -> Double { sorted[Swift.min(sorted.count - 1, Int((p * Double(sorted.count)).rounded(.up)) - 1)] }
            count = sorted.count
            median = rank(0.5)
            p90 = rank(0.9)
            max = sorted.last!
        }
    }

    public struct TokenChange: Codable, Equatable, Sendable {
        public var index: Int
        public var start: Double
        public var end: Double
        public var text: String
        public var frozen: Int?
        public var other: Int?
    }

    public struct LiveMetrics: Codable, Equatable, Sendable {
        public var preset: String
        public var mode: String
        public var snapshots: Int
        public var finalTokens: Int
        public var frozenTokens: Int
        public var frozenLetters: Int
        /// 停止時に未凍結だったトークン。停止時の全体判定だけで話者が決まった分
        public var unfrozenTokens: Int
        public var unfrozenLetters: Int
        /// そのうち、録音中に高精度側で確定していたのに条件を満たさず保留したまま停止した分
        public var heldConfirmedTokens: Int
        /// トークン終端から凍結までの音声秒
        public var freezeWait: Stats?
        /// トークン終端から高精度側の確定までの音声秒。どの方式でも凍結はこれより早くならない
        public var confirmWait: Stats?
        /// 凍結した話者と停止時の判定が違うトークン
        public var mismatches: [TokenChange]
        /// 凍結した話者と、後の snapshot で凍結なしに判定し直した話者が違ったトークン
        public var latentChanges: [TokenChange]
        /// 高精度側で確定してから凍結するまでに、表示の話者が変わった回数の合計
        public var flipsBeforeFreeze: Int
        /// 記録時と同じ条件なら、再生の凍結列がアプリの実際の凍結列と全描画で一致したか
        public var reproduced: Bool?
    }

    public static func simulate(snapshots: [Snapshot], final: FinalRecord, preset: String, options: Aligner.Options,
                                mode: SpeakerFreeze.Mode, checksLatent: Bool = true,
                                checksReproduction: Bool = false) -> LiveMetrics {
        var reproduced = true
        var frozen: [Int?] = []
        var freezeAt: [Double] = []
        var confirmAt: [Double] = []
        var lastLabel: [Int: Int?] = [:]
        var flips = 0
        var latent: [Int: TokenChange] = [:]
        var lastConfirmed = 0
        for snapshot in snapshots {
            let tokens = snapshot.tokens
            let speakers = Aligner.speakers(for: tokens, segments: snapshot.segments, frozen: frozen, options: options)
            let next: [Int?] = switch mode {
            case .grace30:
                SpeakerFreeze.advance(frozen: frozen, speakers: speakers, tokens: tokens, elapsed: snapshot.elapsed,
                                      finalCount: snapshot.accurateFinalCount, judgedUntil: snapshot.judgedUntil)
            case .phrase:
                SpeakerFreeze.advanceByPhrase(frozen: frozen, speakers: speakers, tokens: tokens,
                                              accurateFinalCount: snapshot.accurateFinalCount,
                                              judgedUntil: snapshot.judgedUntil, options: options)
            }
            let confirmed = min(max(snapshot.accurateFinalCount, 0), tokens.count)
            while confirmAt.count < confirmed { confirmAt.append(snapshot.elapsed) }
            lastConfirmed = confirmed
            for index in frozen.count..<max(confirmed, frozen.count) {
                if let previous = lastLabel[index], previous != speakers[index] { flips += 1 }
                // 不明(nil)も1つの値として残す。代入だとキーが消え、不明→既知の揺れを数え損ねる
                lastLabel.updateValue(speakers[index], forKey: index)
            }
            while freezeAt.count < next.count { freezeAt.append(snapshot.elapsed) }
            if checksReproduction, let recorded = snapshot.recordedFrozen, recorded != next, reproduced {
                reproduced = false
            }
            frozen = next
            if checksLatent, !frozen.isEmpty {
                let unfrozen = Aligner.speakers(for: tokens, segments: snapshot.segments, options: options)
                for index in frozen.indices where unfrozen[index] != frozen[index] && latent[index] == nil {
                    latent[index] = change(index, tokens: tokens, frozen: frozen[index], other: unfrozen[index])
                }
            }
        }
        let finalSpeakers = Aligner.speakers(for: final.tokens, segments: final.segments, options: options)
        let frozenCount = min(frozen.count, final.tokens.count)
        let unfrozen = final.tokens.dropFirst(frozenCount)
        return LiveMetrics(
            preset: preset, mode: mode.rawValue, snapshots: snapshots.count, finalTokens: final.tokens.count,
            frozenTokens: frozenCount, frozenLetters: final.tokens.prefix(frozenCount).reduce(0) { $0 + letters($1) },
            unfrozenTokens: unfrozen.count, unfrozenLetters: unfrozen.reduce(0) { $0 + letters($1) },
            heldConfirmedTokens: max(0, min(lastConfirmed, final.tokens.count) - frozenCount),
            freezeWait: Stats((0..<frozenCount).map { freezeAt[$0] - final.tokens[$0].end }),
            confirmWait: Stats(confirmAt.indices.filter { $0 < final.tokens.count }.map { confirmAt[$0] - final.tokens[$0].end }),
            mismatches: (0..<frozenCount).filter { frozen[$0] != finalSpeakers[$0] }
                .map { change($0, tokens: final.tokens, frozen: frozen[$0], other: finalSpeakers[$0]) },
            latentChanges: latent.values.sorted { $0.index < $1.index },
            flipsBeforeFreeze: flips,
            reproduced: checksReproduction && snapshots.contains { $0.recordedFrozen != nil } ? reproduced : nil)
    }

    private static func change(_ index: Int, tokens: [TimedToken], frozen: Int?, other: Int?) -> TokenChange {
        TokenChange(index: index, start: tokens[index].start, end: tokens[index].end, text: tokens[index].text,
                    frozen: frozen, other: other)
    }

    // MARK: - 比較と報告

    public struct Hunk: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var base: String
        public var variant: String
    }

    /// 話者の違うトークンを含むフレーズを、基準と比較先の両方の話者付き本文で並べる
    public static func hunks(tokens: [TimedToken], base: [Int?], variant: [Int?], names: [Int: String]) -> [Hunk] {
        var result: [Hunk] = []
        for phrase in Aligner.phraseRanges(tokens) where phrase.contains(where: { base[$0] != variant[$0] }) {
            result.append(Hunk(start: tokens[phrase.lowerBound].start, end: tokens[phrase.upperBound - 1].end,
                               base: render(tokens: tokens, speakers: base, range: phrase, names: names),
                               variant: render(tokens: tokens, speakers: variant, range: phrase, names: names)))
        }
        return result
    }

    static func name(_ speaker: Int?, names: [Int: String]) -> String {
        guard let speaker else { return "?" }
        return names[speaker] ?? SpeakerNames.letter(for: speaker)
    }

    static func render(tokens: [TimedToken], speakers: [Int?], range: Range<Int>, names: [Int: String]) -> String {
        var parts: [String] = []
        var start = range.lowerBound
        for index in range where index + 1 == range.upperBound || speakers[index + 1] != speakers[start] {
            parts.append(name(speakers[start], names: names) + ": " + tokens[start...index].map(\.text).joined())
            start = index + 1
        }
        return parts.joined(separator: " / ")
    }

    public static func clock(_ seconds: Double) -> String {
        let value = max(0, seconds)
        return String(format: "%02d:%05.2f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }

    /// 行ごとに時刻と話者を付けた全文。補正なしの結果を読み比べる用
    public static func transcript(tokens: [TimedToken], speakers: [Int?], names: [Int: String]) -> String {
        Aligner.utteranceTokenRanges(tokens: tokens, speakers: speakers).map { range in
            "[\(clock(tokens[range.lowerBound].start))] \(name(speakers[range.lowerBound], names: names)): "
                + tokens[range].map(\.text).joined().trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n") + "\n"
    }

    public struct Comparison: Codable, Equatable, Sendable {
        public var source: String
        public var duration: Double
        public var final: [FinalMetrics]
        public var live: [LiveMetrics]
        public var hunks: [String: [Hunk]]
        /// 最初と最後の描画の間の壁時計秒と音声秒。等倍なら比がほぼ1で、消費が遅れていないことを示す
        public var liveWallSeconds: Double?
        public var liveAudioSeconds: Double?
    }

    public static func compare(source: String, final: FinalRecord, snapshots: [Snapshot], presets: [String],
                               livePresets: [String], expectations: [Expectation], names: [Int: String],
                               recorded: Meta? = nil, repeats: Int = 5) -> Comparison {
        func judge(_ options: Aligner.Options) -> ([Int?], Double) {
            var times: [Double] = []
            var speakers: [Int?] = []
            for _ in 0..<max(repeats, 1) {
                let begin = DispatchTime.now().uptimeNanoseconds
                speakers = Aligner.speakers(for: final.tokens, segments: final.segments, options: options)
                times.append(Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000)
            }
            return (speakers, Stats(times)!.median)
        }
        let (base, baseTime) = judge(.current)
        var finals: [FinalMetrics] = []
        var hunks: [String: [Hunk]] = [:]
        for preset in presets {
            guard let options = Aligner.Options.preset(preset) else { continue }
            let (speakers, time) = preset == "current" ? (base, baseTime) : judge(options)
            finals.append(finalMetrics(preset: preset, tokens: final.tokens, speakers: speakers, base: base,
                                       milliseconds: time, expectations: expectations))
            if preset != "current" {
                hunks[preset] = Self.hunks(tokens: final.tokens, base: base, variant: speakers, names: names)
            }
        }
        var live: [LiveMetrics] = []
        if !snapshots.isEmpty {
            for preset in livePresets {
                guard let options = Aligner.Options.preset(preset) else { continue }
                for mode in SpeakerFreeze.Mode.allCases {
                    live.append(simulate(snapshots: snapshots, final: final, preset: preset, options: options, mode: mode,
                                         checksReproduction: recorded?.preset == preset && recorded?.freeze == mode.rawValue))
                }
            }
        }
        let first = snapshots.first, last = snapshots.last
        return Comparison(source: source, duration: final.duration, final: finals, live: live, hunks: hunks,
                          liveWallSeconds: first.flatMap { f in last.map { $0.uptime - f.uptime } },
                          liveAudioSeconds: first.flatMap { f in last.map { $0.elapsed - f.elapsed } })
    }

    public static func markdown(_ comparison: Comparison, names: [Int: String], meta: Meta?) -> String {
        var lines: [String] = []
        lines.append("# 話者補正の比較: \(comparison.source)")
        lines.append("")
        lines.append("- 音声: \(String(format: "%.1f", comparison.duration))秒")
        if let meta {
            let pace = switch meta.pace {
            case "replay-realtime": "等倍replay"
            case "replay-accelerated": "加速replay (約10倍)。待ちの値は代表値にしない"
            default: "マイク"
            }
            lines.append("- 録音中の記録: \(pace)。記録時の設定は `\(meta.preset)` / `\(meta.freeze)`")
        }
        lines.append("- 全条件は同じトークン・時刻・話者区間へ当てた。差は処理の差だけ")
        lines.append("- 対象はトークンへの話者の割当と補正だけ。ASR自体と話者判別モデルの出力は全条件で同じ")
        lines.append("    - 「補正なし」(`window` / `point`) でも、行の区切り(同じ話者で1秒以上の無音)は同じ規則を使う")
        lines.append("    - 繰り返し相槌の省略はこの比較では全条件で無効。保存の `.md` と違う場合がある")
        lines.append("    - 手動の話者統合・小音量の除外・速報と高精度の合流は対象外で、比較に含めない")
        lines.append("- 基準 `current` との差は正誤ではない。正解があるのは「正解区間」の列だけ")
        if !names.isEmpty {
            lines.append("- 名前: " + names.keys.sorted().map { "\($0)=\(names[$0]!)" }.joined(separator: ", "))
        }
        lines.append("")
        lines.append("## 最終判定")
        lines.append("")
        let hasExpectation = comparison.final.contains { !$0.expectations.isEmpty }
        lines.append("| 条件 | 変更トークン | 変更文字 | 行 | 話者切替 | 断片行 | 句読点だけの行 | 不明文字 | 処理ms |"
                     + (hasExpectation ? " 正解区間 |" : ""))
        lines.append("|---|---|---|---|---|---|---|---|---|" + (hasExpectation ? "---|" : ""))
        for metric in comparison.final {
            let expected = metric.expectations.map { "\($0.matchedLetters)/\($0.totalLetters)" }.joined(separator: " ")
            lines.append("| `\(metric.preset)` | \(metric.changedTokens) | \(metric.changedLetters) | \(metric.utterances) "
                         + "| \(metric.switches) | \(metric.fragments) | \(metric.punctuationOnly) | \(metric.unknownLetters) "
                         + "| \(String(format: "%.1f", metric.milliseconds)) |" + (hasExpectation ? " \(expected) |" : ""))
        }
        lines.append("")
        lines.append("- 断片行: 有意文字1〜2字の行。相槌も含むので、多いこと自体を悪いとは断定しない")
        if hasExpectation {
            let expectation = comparison.final.first!.expectations.map {
                "\(clock($0.expectation.start))〜\(clock($0.expectation.end)) を \(name($0.expectation.speaker, names: names))"
            }.joined(separator: "、")
            lines.append("- 正解区間: \(expectation)。区間内に中央がある文字のうち正解の話者に付いた数")
        }
        if !comparison.live.isEmpty {
            lines.append("")
            lines.append("## 録音中の固定")
            lines.append("")
            lines.append("| 条件 | 方式 | 凍結 | 未凍結で停止 | うち確定済みで保留 | 固定待ち 中央/p90/最大 | 確定待ち 中央/p90/最大 | 停止時と不一致 | 後で判定が変わった | 固定前の揺れ |")
            lines.append("|---|---|---|---|---|---|---|---|---|---|")
            func stats(_ value: Stats?) -> String {
                value.map { String(format: "%.1f / %.1f / %.1f", $0.median, $0.p90, $0.max) } ?? "—"
            }
            for metric in comparison.live {
                let ratio = metric.finalTokens == 0 ? 0 : Double(metric.unfrozenTokens) / Double(metric.finalTokens) * 100
                lines.append("| `\(metric.preset)` | \(metric.mode) | \(metric.frozenTokens) "
                             + "| \(metric.unfrozenTokens) (\(String(format: "%.1f", ratio))%) | \(metric.heldConfirmedTokens) "
                             + "| \(stats(metric.freezeWait)) | \(stats(metric.confirmWait)) | \(metric.mismatches.count) "
                             + "| \(metric.latentChanges.count) | \(metric.flipsBeforeFreeze) |")
            }
            lines.append("")
            lines.append("- 単位はトークン数と音声秒。snapshot数: \(comparison.live.first!.snapshots)")
            lines.append("- 確定待ち: トークン終端から高精度側の確定まで。どの方式も凍結はこれより早くならない")
            lines.append("- 待ちは音声秒。文字起こしの確定待ちを含み、話者判別モデルの推論速度そのものではない")
            if let wall = comparison.liveWallSeconds, let audio = comparison.liveAudioSeconds, audio > 0 {
                lines.append(String(format: "- 最初と最後の描画の間: 壁時計 %.1f秒 / 音声 %.1f秒 (比 %.2f)", wall, audio, wall / audio))
            }
            lines.append("- 停止時と不一致: 凍結した話者と停止時の全体判定の差。後で判定が変わった: 凍結後の snapshot で凍結なしに判定し直した値との差")
            for metric in comparison.live {
                guard let reproduced = metric.reproduced else { continue }
                lines.append("- 記録時の条件 `\(metric.preset)` / \(metric.mode) の再生は、アプリの実際の凍結列と"
                             + (reproduced ? "全描画で一致した" : "**一致しなかった**"))
            }
            let problems = comparison.live.filter { !$0.mismatches.isEmpty || !$0.latentChanges.isEmpty }
            for metric in problems {
                lines.append("")
                lines.append("### `\(metric.preset)` \(metric.mode) の不一致")
                lines.append("")
                for change in (metric.mismatches + metric.latentChanges).prefix(40) {
                    lines.append("- \(clock(change.start))〜\(clock(change.end)) 「\(change.text)」 凍結 \(name(change.frozen, names: names)) → \(name(change.other, names: names))")
                }
            }
        }
        for metric in comparison.final where metric.preset != "current" {
            let hunks = comparison.hunks[metric.preset] ?? []
            lines.append("")
            lines.append("## `current` → `\(metric.preset)` の差分 (\(hunks.count)フレーズ)")
            if hunks.isEmpty { continue }
            lines.append("")
            for hunk in hunks {
                lines.append("- \(clock(hunk.start))〜\(clock(hunk.end))")
                lines.append("    - current: \(hunk.base)")
                lines.append("    - \(metric.preset): \(hunk.variant)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
