import Foundation
import Testing
@testable import KikigakiCore

struct AutoSendPhraseTests {
    private func row(_ text: String = "アバンティ", start: Double = 1, end: Double = 2) -> Utterance {
        .init(speaker: nil, start: start, end: end, text: text)
    }
    @Test func 正規化は空白句読点記号とかな幅だけを揃える() {
        #expect(AutoSendPhrase.normalize(" \t\n　「シオリ」、(を挟んで)!?！？・…『』（）,.★＋＄") == "しおりを挟んで")
        #expect(AutoSendPhrase.normalize("ｼｵﾘ ＡＢＣ１２３") == "しおりABC123")
        #expect(AutoSendPhrase.normalize("栞、を挟んで") == "栞を挟んで")
        #expect(AutoSendPhrase.normalize("しおりを挟んで") != AutoSendPhrase.normalize("栞を挟んで"))
    }
    @Test func 設定も本文も正規化して行のどこでも部分一致する() {
        var state = AutoSendPhraseState(phrases: ["シオリ、を挟んで！"])
        let event = state.observe(row("えっと、ｼｵﾘ を挟んで。続きを話します"), now: 100, automaticActive: true, canFireNow: true)
        #expect(event?.decision == .fire && event?.phrase == "しおりを挟んで")
    }
    @Test func 既定の合図は伸ばし棒付きでも部分一致する() {
        for text in ["アバンティー", "では、アヴァンティ！", "ｱﾊﾞﾝﾃｨ"] {
            var state = AutoSendPhraseState(phrases: ResolvedConfig.defaultAutoSendPhrases)
            #expect(state.observe(row(text), now: 100, automaticActive: true, canFireNow: true)?.decision == .fire)
        }
    }
    @Test func 行をまたぐ一致も手入力も対象にしない() throws {
        var state = AutoSendPhraseState(phrases: ResolvedConfig.defaultAutoSendPhrases)
        #expect(state.observe(row("アバ"), now: 100, automaticActive: true, canFireNow: true) == nil)
        #expect(state.observe(row("ンティ", start: 3, end: 4), now: 100, automaticActive: true, canFireNow: true) == nil)
        let typed = try Utterance(typedText: "アバンティ", at: 5, postedAt: Date())
        #expect(state.observe(typed, now: 100, automaticActive: true, canFireNow: true) == nil)
    }
    @Test func 水位は着火行の終了でその時刻以前に始まる訂正行を着火させない() {
        var state = AutoSendPhraseState(phrases: ResolvedConfig.defaultAutoSendPhrases)
        #expect(state.observe(row(start: 1, end: 5), now: 100, automaticActive: true, canFireNow: true)?.decision == .fire)
        #expect(state.watermark == 5)
        #expect(state.observe(row("アヴァンティ。", start: 1, end: 6), now: 120, automaticActive: true, canFireNow: true) == nil)
        #expect(state.observe(row(start: 2, end: 4), now: 120, automaticActive: true, canFireNow: true)?.decision == .watermark)
        #expect(state.observe(row(start: 5, end: 6), now: 120, automaticActive: true, canFireNow: true)?.decision == .watermark)
        #expect(state.observe(row(start: 6, end: 7), now: 120, automaticActive: true, canFireNow: true)?.decision == .fire)
    }
    @Test func 十秒未満は無視し無視行を後から再試行せず十秒ちょうどで再び着火する() {
        var state = AutoSendPhraseState(phrases: ResolvedConfig.defaultAutoSendPhrases)
        #expect(state.observe(row(), now: 100, automaticActive: true, canFireNow: true)?.decision == .fire)
        #expect(state.observe(row(start: 3, end: 4), now: 109.999, automaticActive: true, canFireNow: true)?.decision == .cooldown)
        #expect(state.watermark == 2 && state.lastFiredAt == 100)
        #expect(state.observe(row("アバンティ。", start: 3, end: 4), now: 120, automaticActive: true, canFireNow: true) == nil)
        #expect(state.observe(row(start: 5, end: 6), now: 110, automaticActive: true, canFireNow: true)?.decision == .fire)
    }
    @Test func 非稼働の行を後から着火させず無効条件では着火しない() {
        var state = AutoSendPhraseState(phrases: ResolvedConfig.defaultAutoSendPhrases)
        #expect(state.observe(row(), now: 100, automaticActive: false, canFireNow: true) == nil)
        #expect(state.observe(row(), now: 110, automaticActive: true, canFireNow: true) == nil)
        #expect(state.observe(row(start: 3, end: 4), now: 110, automaticActive: true, canFireNow: false)?.decision == .unavailable)
        #expect(state.watermark == nil && state.lastFiredAt == nil)
        #expect(state.observe(row(start: 3, end: 4), now: 120, automaticActive: true, canFireNow: true) == nil)
    }
    @Test func 非一致の速報が高精度で合図に訂正されれば着火する() {
        var state = AutoSendPhraseState(phrases: ResolvedConfig.defaultAutoSendPhrases)
        #expect(state.observe(row("聞かせて"), now: 100, automaticActive: true, canFireNow: true) == nil)
        #expect(state.observe(row(), now: 101, automaticActive: true, canFireNow: true)?.decision == .fire)
    }
    @Test func 省略は既定で空配列は無効() throws {
        let defaults = ResolvedConfig(config: try ConfigLoader.parse(toml: ""))
        #expect(defaults.autoSendPhrases == ["アバンティ", "アヴァンティ"])
        for phrase in defaults.autoSendPhrases {
            var state = AutoSendPhraseState(phrases: defaults.autoSendPhrases)
            #expect(state.observe(row(phrase), now: 100, automaticActive: true, canFireNow: true)?.decision == .fire)
        }
        let disabled = ResolvedConfig(config: try ConfigLoader.parse(toml: "autoSendPhrases = []"))
        var off = AutoSendPhraseState(phrases: disabled.autoSendPhrases)
        #expect(off.observe(row(), now: 100, automaticActive: true, canFireNow: true) == nil)
    }
    @Test(arguments: ["true", "\"しおりを挟んで\"", "[1]", "[\"a\", 1]", "[\"\"]", "[\"　!?★\"]", "[\"シオリ、を挟んで\", \"ｼｵﾘを挟んで\"]",
                       "[\"" + String(repeating: "あ", count: 65) + "\"]",
                       "[" + (1...21).map { "\"合図\($0)\"" }.joined(separator: ",") + "]"],
          ["", "[[ai]]\n"])
    func 不正な合図設定を拒否する(value: String, prefix: String) {
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: prefix + "autoSendPhrases = \(value)") }
    }
    @Test(arguments: ["", "[[ai]]\n"])
    func 上限ちょうどは使える(prefix: String) throws {
        let phrases = [String(repeating: "あ", count: 64)] + (1...19).map { "合図\($0)" }
        let config = try ConfigLoader.parse(toml: prefix + "autoSendPhrases = [" + phrases.map { "\"\($0)\"" }.joined(separator: ",") + "]")
        #expect((prefix.isEmpty ? config.autoSendPhrases : config.ai?.first?.autoSendPhrases) == phrases)
    }
    @Test func プロファイルの合図は指定と未指定と空配列を区別する() throws {
        let config = try ConfigLoader.parse(toml: """
        autoSendPhrases = ["共通の合図"]
        [[ai]]
        name = "専用"
        autoSendPhrases = ["最新に更新してください"]
        [[ai]]
        name = "共通"
        [[ai]]
        name = "無効"
        autoSendPhrases = []
        """)
        #expect(config.ai?.profiles.map(\.autoSendPhrases) == [["最新に更新してください"], nil, []])
        let resolved = ResolvedConfig(config: config)
        #expect(resolved.aiProfiles.map { $0.autoSendPhrases ?? resolved.autoSendPhrases }
                == [["最新に更新してください"], ["共通の合図"], []])
        let defaults = ResolvedConfig(config: try ConfigLoader.parse(toml: "[[ai]]"))
        #expect(defaults.ai?.autoSendPhrases == nil)
        #expect((defaults.ai?.autoSendPhrases ?? defaults.autoSendPhrases) == ResolvedConfig.defaultAutoSendPhrases)
    }
    @Test(arguments: [nil, [], ["最新に更新してください"]] as [[String]?])
    func 保存したプロファイルの合図を復号し旧保存の欠損を許す(phrases: [String]?) throws {
        let config = ResolvedAIConfig(config: AIConfig(autoSendPhrases: phrases), home: URL(fileURLWithPath: "/tmp"))
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(ResolvedAIConfig.self, from: data) == config)
    }
    @Test func 合図の切替は判定履歴と水位と十秒の無視を引き継ぐ() {
        var state = AutoSendPhraseState(phrases: ["旧合図"])
        #expect(state.observe(row("新合図", start: 0, end: 1), now: 99, automaticActive: true, canFireNow: true) == nil)
        #expect(state.observe(row("旧合図", start: 1, end: 5), now: 100, automaticActive: true, canFireNow: true)?.decision == .fire)
        state.replacePhrases(["新合図"])
        #expect(state.watermark == 5 && state.lastFiredAt == 100)
        #expect(state.observe(row("新合図", start: 0, end: 1), now: 120, automaticActive: true, canFireNow: true) == nil)
        #expect(state.observe(row("新合図。", start: 1, end: 6), now: 120, automaticActive: true, canFireNow: true) == nil)
        #expect(state.observe(row("新合図", start: 2, end: 4), now: 120, automaticActive: true, canFireNow: true)?.decision == .watermark)
        #expect(state.observe(row("新合図", start: 6, end: 7), now: 109, automaticActive: true, canFireNow: true)?.decision == .cooldown)
        state.replacePhrases([])
        #expect(state.observe(row("新合図", start: 8, end: 9), now: 110, automaticActive: true, canFireNow: true) == nil)
        state.replacePhrases(["新合図"])
        #expect(state.observe(row("新合図", start: 8, end: 9), now: 120, automaticActive: true, canFireNow: true) == nil)
        #expect(state.observe(row("新合図。", start: 6, end: 7), now: 120, automaticActive: true, canFireNow: true) == nil)
        #expect(state.observe(row("新合図", start: 10, end: 11), now: 110, automaticActive: true, canFireNow: true)?.decision == .fire)
        #expect(state.observe(row("旧合図", start: 12, end: 13), now: 120, automaticActive: true, canFireNow: true) == nil)
    }
    @Test func ログに本文を出さず正規化後の合図と時刻を残す() throws {
        var state = AutoSendPhraseState(phrases: ResolvedConfig.defaultAutoSendPhrases)
        let observed = state.observe(row("秘密の話です。アバンティ。"), now: 100, automaticActive: true, canFireNow: true)
        let event = try #require(observed)
        let log = Diagnostics().autoSendPhraseLine(event)
        #expect(log == "[auto-send-phrase fire] phrase=あばんてぃ start=1.000 end=2.000 at=100.000")
        #expect(!log.contains("秘密"))
    }
}
