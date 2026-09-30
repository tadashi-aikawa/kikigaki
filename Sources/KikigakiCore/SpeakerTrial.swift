import Foundation

/// 話者の割当と固定の検証用に、録音の入力を保存して本番の判定を当て直す。本番の判定は変えない。
/// 1回の録音(replay)で得た入力を保存し、別のビルドの結果とも同じ入力で比べられるようにする。
/// 設計: docs/speaker-compare.md
public enum SpeakerTrial {
    /// 試験の環境変数。アプリはDEBUGビルドだけで読む
    /// - `KIKIGAKI_TRIAL_DUMP`: 比較用の入力を書き出す先。会話本文を含む
    ///
    /// 補正を外す `KIKIGAKI_TRIAL_ALIGNER` と固定方式の `KIKIGAKI_TRIAL_FREEZE`、島の補正の段階の
    /// `KIKIGAKI_TRIAL_ISLAND` は廃止した。指定されていたら止める。試したつもりで本番の判定のまま比べないため
    public struct Settings: Equatable, Sendable {
        public var dumpDirectory: String?

        public struct Invalid: Error, CustomStringConvertible {
            public let description: String
        }

        static let retired = [
            "KIKIGAKI_TRIAL_ALIGNER": "11d8733",
            "KIKIGAKI_TRIAL_FREEZE": "11d8733",
            "KIKIGAKI_TRIAL_ISLAND": "66be821",
        ]

        public init(environment: [String: String]) throws {
            if let name = Self.retired.keys.sorted().first(where: { environment[$0] != nil }) {
                throw Invalid(description: "\(name) は廃止した。条件の比較はコミット \(Self.retired[name]!) のビルドで行う")
            }
            dumpDirectory = environment["KIKIGAKI_TRIAL_DUMP"].flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
        }
    }

    /// 記録の由来。等倍と加速で待ちの意味が違うため、比較の表へ出す。
    /// `preset` と `freeze` は旧版の比較CLIでも読めるよう残す。今の記録は `adopted` と `phrase`。
    /// `islands` は島の補正の段階。今の記録は `cross`。`66be821` の試験版も同じキーで段階を残す
    public struct Meta: Codable, Equatable, Sendable {
        public static let adoptedPreset = "adopted"
        public static let phraseFreeze = "phrase"
        public static let adoptedIslands = "cross"

        public var pace: String
        public var preset: String
        public var freeze: String
        public var islands: String?

        public init(pace: String, preset: String = adoptedPreset, freeze: String = phraseFreeze,
                    islands: String? = adoptedIslands) {
            self.pace = pace
            self.preset = preset
            self.freeze = freeze
            self.islands = islands
        }

        /// 記録時も今の本番の判定と固定だったか。違えば、再生がアプリの凍結列と一致しないので照合しない。
        /// `islands` の無い記録は島の補正の採用前のもの
        public var matchesAdopted: Bool {
            preset == Self.adoptedPreset && freeze == Self.phraseFreeze && islands == Self.adoptedIslands
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
        public var tokens: Int
        public var letters: Int
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

    public static func finalMetrics(tokens: [TimedToken], speakers: [Int?], milliseconds: Double,
                                    expectations: [Expectation]) -> FinalMetrics {
        let lettered = tokens.indices.filter { letters(tokens[$0]) > 0 }
        let switches = zip(lettered, lettered.dropFirst()).filter { speakers[$0.0] != speakers[$0.1] }.count
        let ranges = Aligner.utteranceTokenRanges(tokens: tokens, speakers: speakers)
        let rowLetters = ranges.map { $0.reduce(0) { $0 + letters(tokens[$1]) } }
        return FinalMetrics(
            tokens: tokens.count, letters: tokens.reduce(0) { $0 + letters($1) },
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

    /// 録音中の突き合わせループを本番の判定とフレーズ固定で再生する
    public static func simulate(snapshots: [Snapshot], final: FinalRecord, checksLatent: Bool = true,
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
            let speakers = Aligner.speakers(for: tokens, segments: snapshot.segments, frozen: frozen)
            let next = SpeakerFreeze.advanceByPhrase(frozen: frozen, speakers: speakers, tokens: tokens,
                                                     accurateFinalCount: snapshot.accurateFinalCount,
                                                     judgedUntil: snapshot.judgedUntil)
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
                let unfrozen = Aligner.speakers(for: tokens, segments: snapshot.segments)
                for index in frozen.indices where unfrozen[index] != frozen[index] && latent[index] == nil {
                    latent[index] = change(index, tokens: tokens, frozen: frozen[index], other: unfrozen[index])
                }
            }
        }
        let finalSpeakers = Aligner.speakers(for: final.tokens, segments: final.segments)
        let frozenCount = min(frozen.count, final.tokens.count)
        let unfrozen = final.tokens.dropFirst(frozenCount)
        return LiveMetrics(
            snapshots: snapshots.count, finalTokens: final.tokens.count,
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

    // MARK: - 報告

    static func name(_ speaker: Int?, names: [Int: String]) -> String {
        guard let speaker else { return "?" }
        return names[speaker] ?? SpeakerNames.letter(for: speaker)
    }

    public static func clock(_ seconds: Double) -> String {
        let value = max(0, seconds)
        return String(format: "%02d:%05.2f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }

    /// 行ごとに時刻と話者を付けた全文。旧版の `transcripts/<条件>.md` と同じ形式で、`diff` で読み比べる
    public static func transcript(tokens: [TimedToken], speakers: [Int?], names: [Int: String]) -> String {
        Aligner.utteranceTokenRanges(tokens: tokens, speakers: speakers).map { range in
            "[\(clock(tokens[range.lowerBound].start))] \(name(speakers[range.lowerBound], names: names)): "
                + tokens[range].map(\.text).joined().trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n") + "\n"
    }

    public struct Comparison: Codable, Equatable, Sendable {
        public var source: String
        public var duration: Double
        public var final: FinalMetrics
        public var live: LiveMetrics?
        /// 最初と最後の描画の間の壁時計秒と音声秒。等倍なら比がほぼ1で、消費が遅れていないことを示す
        public var liveWallSeconds: Double?
        public var liveAudioSeconds: Double?
    }

    /// 本番の判定を停止時の入力へ当て、録音中の記録があればフレーズ固定で再生する。
    /// 再生の照合は、記録時も今の本番の判定だった場合だけ行う。旧版の条件で録った記録とは凍結列が一致しない
    public static func compare(source: String, final: FinalRecord, snapshots: [Snapshot], expectations: [Expectation],
                               recorded: Meta? = nil, repeats: Int = 5) -> (Comparison, speakers: [Int?]) {
        var times: [Double] = []
        var speakers: [Int?] = []
        for _ in 0..<max(repeats, 1) {
            let begin = DispatchTime.now().uptimeNanoseconds
            speakers = Aligner.speakers(for: final.tokens, segments: final.segments)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000)
        }
        let metrics = finalMetrics(tokens: final.tokens, speakers: speakers, milliseconds: Stats(times)!.median,
                                   expectations: expectations)
        let live = snapshots.isEmpty ? nil : simulate(
            snapshots: snapshots, final: final,
            checksReproduction: recorded?.matchesAdopted == true)
        let first = snapshots.first, last = snapshots.last
        return (Comparison(source: source, duration: final.duration, final: metrics, live: live,
                          liveWallSeconds: first.flatMap { f in last.map { $0.uptime - f.uptime } },
                          liveAudioSeconds: first.flatMap { f in last.map { $0.elapsed - f.elapsed } }), speakers)
    }

    public static func markdown(_ comparison: Comparison, names: [Int: String], meta: Meta?) -> String {
        var lines: [String] = []
        lines.append("# 話者の割当と固定: \(comparison.source)")
        lines.append("")
        lines.append("- 音声: \(String(format: "%.1f", comparison.duration))秒")
        if let meta {
            let pace = switch meta.pace {
            case "replay-realtime": "等倍replay"
            case "replay-accelerated": "加速replay (約10倍)。待ちの値は代表値にしない"
            default: "マイク"
            }
            lines.append("- 録音中の記録: \(pace)。記録時の設定は `\(meta.preset)` / `\(meta.freeze)` / 島 `\(meta.islands ?? "なし")`")
        }
        lines.append("- 本番の話者の割当とフレーズ固定を、記録したトークン・時刻・話者区間へ当てた")
        lines.append("    - 繰り返し相槌の省略は無効。保存の `.md` と違う場合がある")
        lines.append("    - 手動の話者統合・小音量の除外・速報と高精度の合流は対象外")
        lines.append("- 別のビルドとの差は `transcript.md` の `diff` で見る。差は正誤ではない。正解があるのは「正解区間」だけ")
        if !names.isEmpty {
            lines.append("- 名前: " + names.keys.sorted().map { "\($0)=\(names[$0]!)" }.joined(separator: ", "))
        }
        lines.append("")
        lines.append("## 最終判定")
        lines.append("")
        let metric = comparison.final
        let hasExpectation = !metric.expectations.isEmpty
        lines.append("| 行 | 話者切替 | 断片行 | 句読点だけの行 | 不明文字 | 処理ms |" + (hasExpectation ? " 正解区間 |" : ""))
        lines.append("|---|---|---|---|---|---|" + (hasExpectation ? "---|" : ""))
        let expected = metric.expectations.map { "\($0.matchedLetters)/\($0.totalLetters)" }.joined(separator: " ")
        lines.append("| \(metric.utterances) | \(metric.switches) | \(metric.fragments) | \(metric.punctuationOnly) "
                     + "| \(metric.unknownLetters) | \(String(format: "%.1f", metric.milliseconds)) |"
                     + (hasExpectation ? " \(expected) |" : ""))
        lines.append("")
        lines.append("- 断片行: 有意文字1〜2字の行。相槌も含むので、多いこと自体を悪いとは断定しない")
        if hasExpectation {
            let expectation = metric.expectations.map {
                "\(clock($0.expectation.start))〜\(clock($0.expectation.end)) を \(name($0.expectation.speaker, names: names))"
            }.joined(separator: "、")
            lines.append("- 正解区間: \(expectation)。区間内に中央がある文字のうち正解の話者に付いた数")
        }
        if let live = comparison.live {
            lines.append("")
            lines.append("## 録音中の固定")
            lines.append("")
            lines.append("| 凍結 | 未凍結で停止 | うち確定済みで保留 | 固定待ち 中央/p90/最大 | 確定待ち 中央/p90/最大 | 停止時と不一致 | 後で判定が変わった | 固定前の揺れ |")
            lines.append("|---|---|---|---|---|---|---|---|")
            func stats(_ value: Stats?) -> String {
                value.map { String(format: "%.1f / %.1f / %.1f", $0.median, $0.p90, $0.max) } ?? "—"
            }
            let ratio = live.finalTokens == 0 ? 0 : Double(live.unfrozenTokens) / Double(live.finalTokens) * 100
            lines.append("| \(live.frozenTokens) | \(live.unfrozenTokens) (\(String(format: "%.1f", ratio))%) | \(live.heldConfirmedTokens) "
                         + "| \(stats(live.freezeWait)) | \(stats(live.confirmWait)) | \(live.mismatches.count) "
                         + "| \(live.latentChanges.count) | \(live.flipsBeforeFreeze) |")
            lines.append("")
            lines.append("- 単位はトークン数と音声秒。snapshot数: \(live.snapshots)")
            lines.append("- 確定待ち: トークン終端から高精度側の確定まで。凍結はこれより早くならない")
            lines.append("- 待ちは音声秒。文字起こしの確定待ちを含み、話者判別モデルの推論速度そのものではない")
            if let wall = comparison.liveWallSeconds, let audio = comparison.liveAudioSeconds, audio > 0 {
                lines.append(String(format: "- 最初と最後の描画の間: 壁時計 %.1f秒 / 音声 %.1f秒 (比 %.2f)", wall, audio, wall / audio))
            }
            lines.append("- 停止時と不一致: 凍結した話者と停止時の全体判定の差。後で判定が変わった: 凍結後の snapshot で凍結なしに判定し直した値との差")
            if let reproduced = live.reproduced {
                lines.append("- 再生は、アプリの実際の凍結列と" + (reproduced ? "全描画で一致した" : "**一致しなかった**"))
            } else {
                lines.append("- 記録時の条件が今の本番の判定ではないため、アプリの凍結列との照合はしていない")
            }
            if !live.mismatches.isEmpty || !live.latentChanges.isEmpty {
                lines.append("")
                lines.append("### 不一致")
                lines.append("")
                for change in (live.mismatches + live.latentChanges).prefix(40) {
                    lines.append("- \(clock(change.start))〜\(clock(change.end)) 「\(change.text)」 凍結 \(name(change.frozen, names: names)) → \(name(change.other, names: names))")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
