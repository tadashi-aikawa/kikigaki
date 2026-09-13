import Foundation
import Testing
@testable import KikigakiCore

/// AIの返事行へ添えるモデル表記。値はプロファイルだけから採り、CLIの既定モデルは推測しない。
@Suite struct AIModelLabelTests {
    private let home = URL(fileURLWithPath: "/Users/test")
    private func label(_ config: AIConfig) -> AIModelLabel {
        AIModelLabel(profile: ResolvedAIConfig(config: config, home: home))
    }
    /// 文字数だけで測る物差し。フォントに依存させずに段の落ち方を確かめる。
    private func measure(_ text: String) -> Double { Double(text.count) * 6 }

    @Test func modelとeffortとcwdの末端を中黒で結ぶ() {
        let value = label(AIConfig(cli: .codex, model: "gpt-6-astra", effort: "high", cwd: "~/work/minutes"))
        #expect(value.model == "gpt-6-astra" && value.effort == "high" && value.directory == "minutes")
        #expect(value.text == "gpt-6-astra · high · minutes")
    }

    @Test(arguments: [AIProvider.codex, .claude]) func model未設定ならCLI名を出す(cli: AIProvider) {
        let value = label(AIConfig(cli: cli, effort: "high", cwd: "~/work/minutes"))
        #expect(value.model == cli.rawValue)
        #expect(value.text == cli.rawValue + " · high · minutes")
    }

    @Test func effort未設定なら飛ばし末端ディレクトリは既定cwdでも出す() {
        let value = label(AIConfig(cli: .codex, model: "gpt-6-astra"))
        #expect(value.effort == nil && value.directory == "ai-work")
        #expect(value.text == "gpt-6-astra · ai-work")
        #expect(value.stages == ["gpt-6-astra · ai-work", "gpt-6-astra"])
    }

    @Test func ルート直下のcwdは末端ディレクトリとして出さない() {
        let value = label(AIConfig(cli: .claude, model: "sonnet-5", cwd: "/"))
        #expect(value.directory == nil && value.stages == ["sonnet-5"])
    }

    @Test func 段は末端ディレクトリからエフォートの順に落ちる() {
        let value = AIModelLabel(model: "gpt-6-astra", effort: "high", directory: "minutes")
        #expect(value.stages == ["gpt-6-astra · high · minutes", "gpt-6-astra · high", "gpt-6-astra"])
    }

    @Test func 幅に収まる最も広い段を選ぶ() {
        let stages = AIModelLabel(model: "gpt-6-astra", effort: "high", directory: "minutes").stages
        func fit(_ available: Double) -> String? { AIModelLabel.fit(stages, available: available, measure: measure) }
        #expect(fit(measure(stages[0])) == stages[0])
        #expect(fit(measure(stages[0]) - 1) == stages[1])
        #expect(fit(measure(stages[1]) - 1) == stages[2])
    }

    /// どれも収まらなければ表記ごと出さない。時刻を押し出してまで一部を出さない。
    @Test(arguments: [0.0, -20.0, 10.0]) func 収まる段が無ければnilを返す(available: Double) {
        let stages = AIModelLabel(model: "gpt-6-astra", effort: "high", directory: "minutes").stages
        #expect(AIModelLabel.fit(stages, available: available, measure: measure) == nil)
    }

    /// 過去会議は保存済みプロファイルから同じ表記を作る。保存形式は変えない。
    @Test func 保存して読み直したプロファイルも同じ表記になる() throws {
        let resolved = ResolvedAIConfig(config: AIConfig(cli: .claude, effort: "max", address: "ネオへ", cwd: "~/work/owlery"),
                                        home: home, slot: 2)
        let decoded = try JSONDecoder().decode(ResolvedAIConfig.self, from: JSONEncoder().encode(resolved))
        #expect(AIModelLabel(profile: decoded) == AIModelLabel(profile: resolved))
        #expect(AIModelLabel(profile: decoded).text == "claude · max · owlery")
    }

    @Test func 空白だけの値は項目として出さない() {
        let value = AIModelLabel(model: "gpt-6-astra", effort: "  ", directory: "")
        #expect(value.effort == nil && value.directory == nil && value.stages == ["gpt-6-astra"])
    }
}
