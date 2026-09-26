import Foundation

/// 島の補正の段階を同じ入力へ当てて並べる。採用前の比較用で、本番の既定は `off`。
/// 設計: docs/speaker-overlap-islands.md
extension SpeakerTrial {
    /// `off` と話者が違う、連続したトークンの塊
    public struct StageChange: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String
        /// 前後の文脈。原音と突き合わせるため
        public var before: String
        public var after: String
        public var from: Int?
        public var to: Int?
        /// 全ての有意文字が正解区間の中か。外の差は正解が分からない
        public var inExpectation: Bool
        /// 一部の有意文字だけが正解区間の中か
        public var partlyInExpectation: Bool
    }

    public struct Stage: Codable, Equatable, Sendable {
        public var islands: SpeakerIslands
        public var comparison: Comparison
        public var changes: [StageChange]
        /// 行を連結した本文が、空白を除いて入力のトークンの連結と同じか。補正は話者だけを変え、文字と時刻を変えない
        public var textPreserved: Bool
    }

    public struct StageComparison: Codable, Equatable, Sendable {
        public var source: String
        public var duration: Double
        /// 記録時の島の段階。旧版の条件の記録は nil で、再生の照合はしない
        public var recordedIslands: SpeakerIslands?
        public var stages: [Stage]
        public var liveWallSeconds: Double?
        public var liveAudioSeconds: Double?
    }

    public static func compareStages(source: String, final: FinalRecord, snapshots: [Snapshot], expectations: [Expectation],
                                     recorded: Meta? = nil) -> (StageComparison, speakers: [SpeakerIslands: [Int?]]) {
        var stages: [Stage] = []
        var speakers: [SpeakerIslands: [Int?]] = [:]
        for islands in SpeakerIslands.allCases {
            let (comparison, assigned) = compare(source: source, final: final, snapshots: snapshots, expectations: expectations,
                                                 recorded: recorded, islands: islands)
            speakers[islands] = assigned
            stages.append(Stage(
                islands: islands, comparison: comparison,
                changes: changes(tokens: final.tokens, base: speakers[.off]!, speakers: assigned, expectations: expectations),
                textPreserved: preservesText(tokens: final.tokens, speakers: assigned)))
        }
        let first = stages[0].comparison
        return (StageComparison(source: source, duration: final.duration, recordedIslands: recorded?.recordedIslands,
                                stages: stages, liveWallSeconds: first.liveWallSeconds, liveAudioSeconds: first.liveAudioSeconds),
                speakers)
    }

    static func changes(tokens: [TimedToken], base: [Int?], speakers: [Int?], expectations: [Expectation]) -> [StageChange] {
        var result: [StageChange] = []
        var i = 0
        while i < tokens.count {
            guard base[i] != speakers[i] else { i += 1; continue }
            var j = i + 1
            while j < tokens.count && base[j] != speakers[j] && base[j] == base[i] && speakers[j] == speakers[i] { j += 1 }
            let start = tokens[i].start, end = tokens[j - 1].end
            let inside = tokens[i..<j].filter(SpeechTail.hasLetter).map { token in
                expectations.contains { ($0.start...$0.end).contains(token.midpoint) }
            }
            let all = !inside.isEmpty && inside.allSatisfy { $0 }
            result.append(StageChange(
                start: start, end: end, text: tokens[i..<j].map(\.text).joined(),
                before: String(tokens[..<i].map(\.text).joined().suffix(12)),
                after: String(tokens[j...].map(\.text).joined().prefix(12)),
                from: base[i], to: speakers[i],
                inExpectation: all, partlyInExpectation: !all && inside.contains(true)))
            i = j
        }
        return result
    }

    static func preservesText(tokens: [TimedToken], speakers: [Int?]) -> Bool {
        func strip(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        return strip(Aligner.utterances(tokens: tokens, speakers: speakers).map(\.text).joined())
            == strip(tokens.map(\.text).joined())
    }

    public static func stageMarkdown(_ comparison: StageComparison, names: [Int: String], meta: Meta?) -> String {
        var lines: [String] = []
        lines.append("# 島の補正の段階比較: \(comparison.source)")
        lines.append("")
        lines.append("- 音声: \(String(format: "%.1f", comparison.duration))秒")
        if let meta {
            let pace = switch meta.pace {
            case "replay-realtime": "等倍replay"
            case "replay-accelerated": "加速replay (約10倍)。待ちの値は代表値にしない"
            default: "マイク"
            }
            let islands = comparison.recordedIslands.map { "`\($0.rawValue)`" } ?? "旧版の条件 `\(meta.preset)` / `\(meta.freeze)`"
            lines.append("- 録音中の記録: \(pace)。記録時の島の段階: \(islands)")
        }
        lines.append("- 全段階で同じトークン・時刻・話者区間へ、本番の判定とフレーズ固定を当てた。段階は `off` ⊂ `cut` ⊂ `phrase` ⊂ `cross` の順に範囲が広い")
        lines.append("    - `off` は本番の既定。`cross` だけ、凍結が後続のフレーズの確定を待つ")
        lines.append("    - 繰り返し相槌の省略・手動の話者統合・小音量の除外・速報と高精度の合流は対象外")
        lines.append("- 差は正誤ではない。正解があるのは「正解区間」だけ。区間の話者ラベルも正解ではない")
        if !names.isEmpty {
            lines.append("- 名前: " + names.keys.sorted().map { "\($0)=\(names[$0]!)" }.joined(separator: ", "))
        }
        lines.append("")
        lines.append("## 最終判定")
        lines.append("")
        let hasExpectation = comparison.stages.contains { !$0.comparison.final.expectations.isEmpty }
        lines.append("| 段階 | 行 | 話者切替 | 断片行 | 不明文字 | 処理ms | offとの差 | 本文 |" + (hasExpectation ? " 正解区間 |" : ""))
        lines.append("|---|---|---|---|---|---|---|---|" + (hasExpectation ? "---|" : ""))
        for stage in comparison.stages {
            let metric = stage.comparison.final
            let letters = stage.changes.reduce(0) { $0 + $1.text.filter { $0.isLetter || $0.isNumber }.count }
            let expected = metric.expectations.map { "\($0.matchedLetters)/\($0.totalLetters)" }.joined(separator: " ")
            lines.append("| `\(stage.islands.rawValue)` | \(metric.utterances) | \(metric.switches) | \(metric.fragments) "
                         + "| \(metric.unknownLetters) | \(String(format: "%.1f", metric.milliseconds)) "
                         + "| \(stage.changes.count)箇所 \(letters)文字 | \(stage.textPreserved ? "不変" : "**変化**") |"
                         + (hasExpectation ? " \(expected) |" : ""))
        }
        lines.append("")
        lines.append("- 断片行: 有意文字1〜2字の行。相槌も含むので、多いこと自体を悪いとは断定しない")
        lines.append("- 本文: 行を連結した本文が、空白を除いて入力のトークンの連結と同じか。補正は話者だけを変える")
        if let expectations = comparison.stages.first?.comparison.final.expectations, !expectations.isEmpty {
            let text = expectations.map {
                "\(clock($0.expectation.start))〜\(clock($0.expectation.end)) を \(name($0.expectation.speaker, names: names))"
            }.joined(separator: "、")
            lines.append("- 正解区間: \(text)。区間内に中央がある文字のうち正解の話者に付いた数")
        }
        if comparison.stages.contains(where: { $0.comparison.live != nil }) {
            lines.append("")
            lines.append("## 録音中の固定")
            lines.append("")
            lines.append("| 段階 | 凍結 | 未凍結で停止 | 固定待ち 中央/p90/最大 | 停止時と不一致 | 後で判定が変わった | 固定前の揺れ | 再生の照合 |")
            lines.append("|---|---|---|---|---|---|---|---|")
            for stage in comparison.stages {
                guard let live = stage.comparison.live else { continue }
                let wait = live.freezeWait.map { String(format: "%.1f / %.1f / %.1f", $0.median, $0.p90, $0.max) } ?? "—"
                let ratio = live.finalTokens == 0 ? 0 : Double(live.unfrozenTokens) / Double(live.finalTokens) * 100
                let reproduced = live.reproduced.map { $0 ? "一致" : "**不一致**" } ?? "対象外"
                lines.append("| `\(stage.islands.rawValue)` | \(live.frozenTokens) | \(live.unfrozenTokens) (\(String(format: "%.1f", ratio))%) "
                             + "| \(wait) | \(live.mismatches.count) | \(live.latentChanges.count) | \(live.flipsBeforeFreeze) | \(reproduced) |")
            }
            lines.append("")
            lines.append("- 単位はトークン数と音声秒。待ちは文字起こしの確定待ちを含む")
            if let wall = comparison.liveWallSeconds, let audio = comparison.liveAudioSeconds, audio > 0 {
                lines.append(String(format: "- 最初と最後の描画の間: 壁時計 %.1f秒 / 音声 %.1f秒 (比 %.2f)", wall, audio, wall / audio))
            }
            lines.append("- 再生の照合: 記録時と同じ段階だけ、アプリの実際の凍結列と全描画で一致したかを見る。他の段階は対象外")
            for stage in comparison.stages {
                guard let live = stage.comparison.live, !live.mismatches.isEmpty || !live.latentChanges.isEmpty else { continue }
                lines.append("")
                lines.append("### 不一致 `\(stage.islands.rawValue)`")
                lines.append("")
                for change in (live.mismatches + live.latentChanges).prefix(40) {
                    lines.append("- \(clock(change.start))〜\(clock(change.end)) 「\(change.text)」 凍結 \(name(change.frozen, names: names)) → \(name(change.other, names: names))")
                }
            }
        }
        lines.append("")
        lines.append("## offとの差")
        lines.append("")
        lines.append("段階ごとに、`off` から話者が変わった箇所。[ ] が変わった文字。「正解区間」は全ての有意文字が区間内の場合だけ。それ以外は正解が分からない")
        for stage in comparison.stages where stage.islands != .off {
            lines.append("")
            lines.append("### `\(stage.islands.rawValue)` (\(stage.changes.count)箇所)")
            lines.append("")
            if stage.changes.isEmpty { lines.append("- なし") }
            for change in stage.changes {
                lines.append("- \(clock(change.start))〜\(clock(change.end)) …\(change.before)[\(change.text)]\(change.after)… "
                             + "\(name(change.from, names: names)) → \(name(change.to, names: names))"
                             + (change.inExpectation ? " (正解区間)" : change.partlyInExpectation ? " (一部だけ正解区間)" : " (未確認)"))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
