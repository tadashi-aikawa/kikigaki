import Foundation
import Testing
@testable import KikigakiCore

@Suite struct BoardTests {
    @Test(arguments: ["", "(00:00 更新)", "(17:48 更新)", "(23:59 更新)"])
    func 時刻付き見出しも同じ範囲を切り出す(_ suffix: String) {
        let source = "前\n## ボード\(suffix)\r\n```mermaid\r\nflowchart TB\r\n```\r\n### 立場\r\n未表明\r\n## 次\r\n後"
        let parts = BoardSection.split(source, heading: "## ボード")
        #expect(parts.minutes == "前\n## 次\r\n後")
        #expect(parts.updatedTime == (suffix.isEmpty ? nil : String(suffix.dropFirst().prefix(5))))
        #expect(parts.board == "```mermaid\r\nflowchart TB\r\n```\r\n### 立場\r\n未表明\r\n")
    }
    @Test(arguments: ["2", "補足", " (17:48 更新)", "(7:48 更新)", "(24:00 更新)", "(17:60 更新)", "(１７:４８ 更新)", "(17:48 更新)追記", "(17:48 更新)\n"])
    func 任意の続きと不正時刻を拒否する(_ suffix: String) {
        #expect(!BoardHeading.matches("## ボード" + suffix, heading: "## ボード"))
        if !suffix.contains("\n") {
            let source = "## ボード\(suffix)\n対象外"
            #expect(BoardSection.split(source, heading: "## ボード").minutes == source)
            #expect(BoardSection.split(source, heading: "## ボード").board == nil)
            #expect(BoardSection.split(source, heading: "## ボード").updatedTime == nil)
        }
    }
    @Test func 見出し行ごと更新し境界と改行を保つ() throws {
        let original = "---\r\n## ボード(17:47 更新)\r\n---\r\n```md\r\n## ボード(17:47 更新)\r\n```\r\n## ボード(17:48 更新)\r\n旧\r\n## 次\r\nそのまま"
        let updated = try BoardSection.replacing(original, heading: "## ボード", body: "図\r\n", headingLine: "## ボード(17:49 更新)")
        #expect(updated.utf8.elementsEqual(original.replacingOccurrences(of: "## ボード(17:48 更新)\r\n旧", with: "## ボード(17:49 更新)\r\n図").utf8))
        #expect(BoardSection.split(updated, heading: "## ボード").board == "図\r\n")
        #expect(BoardSection.split(updated, heading: "## ボード").updatedTime == "17:49")
        for old in ["", "## ボード", "## ボード(17:48 更新)"] {
            #expect(try BoardSection.replacing(old, heading: "## ボード", body: "図", headingLine: "## ボード(17:49 更新)") == "## ボード(17:49 更新)\n図\n")
        }
        #expect(try BoardSection.replacing("前文", heading: "## ボード", body: "図", headingLine: "## ボード(17:49 更新)") == "前文\n## ボード(17:49 更新)\n図\n")
        #expect(throws: (any Error).self) {
            try BoardSection.replacing(original, heading: "## ボード", body: "図", headingLine: "## ボード2")
        }
    }
    @Test func 書き先指示は未展開で保存されパスがない時だけ末尾に付く() throws {
        let location = "~/Documents/minutes/${yyyyMMdd_HHmmss}.md として作成し、変数は現在日時"
        for custom: String? in [nil, "独自のボード"] {
            let parsed = try ConfigLoader.parse(toml: """
            [ai]
            board = '## ボード'
            boardLocation = '\(location)'
            \(custom.map { "boardPrompt = '\($0)'" } ?? "")
            """)
            let profile = try #require(ResolvedConfig(config: parsed, home: URL(fileURLWithPath: "/tmp")).aiProfiles.first)
            #expect(profile.boardLocation == location)
            #expect(try AIJSON.decode(ResolvedAIConfig.self, from: AIJSON.encode(profile)) == profile)
            #expect(profile.scheduledPrompt(minutesPath: nil) == (custom ?? BoardPrompt.builtIn) + "\n\n" + BoardPrompt.locationInstruction + "\n" + location)
            #expect(profile.scheduledPrompt(minutesPath: "/tmp/minutes.md") == (custom ?? BoardPrompt.builtIn))
        }
    }
    @Test func 書き先指示の孤立と不正値と組み立て後の上限を拒否する() {
        for toml in ["[ai]\nboardLocation = '作成'", "[ai]\nboard = '## ボード'\nboardLocation = 1",
                     "[ai]\nboard = '## ボード'\nboardLocation = ''", "[ai]\nboard = '## ボード'\nboardLocation = '  '"] {
            #expect(throws: (any Error).self) { try ConfigLoader.parse(toml: toml) }
        }
        #expect(throws: (any Error).self) { try AIConfig(board: "## ボード", boardLocation: "\0").validate() }
        #expect(throws: (any Error).self) {
            try AIConfig(board: "## ボード", boardPrompt: String(repeating: "a", count: AILimits.questionBytes), boardLocation: "作成").validate()
        }
    }
    @Test func 設定はボードと手動プロンプトを共存させる() throws {
        let parsed = try ConfigLoader.parse(toml: """
        [[ai]]
        board = "## ボード"
        autoPrompt = "議事録を更新"
        autoStart = true
        """)
        let profile = try #require(ResolvedConfig(config: parsed, home: URL(fileURLWithPath: "/tmp")).aiProfiles.first)
        #expect(profile.scheduledPrompt == BoardPrompt.builtIn)
        #expect(profile.autoPrompt == "議事録を更新")
        #expect(try AIJSON.decode(ResolvedAIConfig.self, from: AIJSON.encode(profile)) == profile)
        let custom = ResolvedAIConfig(config: AIConfig(board: "# ボード", boardPrompt: "独自のボード"), home: URL(fileURLWithPath: "/tmp"))
        #expect(custom.scheduledPrompt == "独自のボード")
        try AIConfig(autoStart: true, board: "# ボード").validate()
    }
    @Test func 複数の宛先が同じボードの見出しを持てる() throws {
        let parsed = try ConfigLoader.parse(toml: """
        [[ai]]
        name = "Codex"
        board = "## ボード"
        [[ai]]
        name = "Claude"
        cli = "claude"
        board = "## ボード"
        """)
        let profiles = ResolvedConfig(config: parsed, home: URL(fileURLWithPath: "/tmp")).aiProfiles
        #expect(profiles.map(\.board) == ["## ボード", "## ボード"])
    }
    @Test func ボード開始には議事録パスか書き先指示が必要() {
        let home = URL(fileURLWithPath: "/tmp")
        let board = ResolvedAIConfig(config: AIConfig(board: "## ボード"), home: home)
        let locatedBoard = ResolvedAIConfig(config: AIConfig(board: "## ボード", boardLocation: "ここに作成"), home: home)
        let plain = ResolvedAIConfig(config: AIConfig(), home: home)

        #expect(board.boardStartIssue(minutesPath: "/tmp/minutes.md") == nil)
        #expect(locatedBoard.boardStartIssue(minutesPath: nil) == nil)
        #expect(board.boardStartIssue(minutesPath: nil) == BoardPrompt.missingLocation)
        #expect(plain.boardStartIssue(minutesPath: nil) == nil)
    }
    @Test(arguments: ["", "ボード", "##", "## ", "####### ボード", "##ボード", "## ボード\n## ボード", " ## ボード", "## \0"])
    func 不正見出しを拒否する(_ heading: String) {
        #expect(throws: (any Error).self) { try AIConfig(board: heading).validate() }
    }
    @Test func 設定の孤立プロンプトと型違いを拒否する() {
        for toml in ["[ai]\nboardPrompt = '更新'", "[ai]\nboard = 3", "[ai]\nboard = '## ボード'\nboardPrompt = ''"] {
            #expect(throws: (any Error).self) { try ConfigLoader.parse(toml: toml) }
        }
    }
    @Test func 節の境界は同階層以上でコードとfrontmatterを除く() throws {
        let source = "---\n## ボード\n---\n# 会議\n前文\n```md\n## ボード\n```\n## ボード\n現在地\n### 論点\n~~~\n# 偽の境界\n~~~\n図\n## 次\n不変\n"
        let parts = BoardSection.split(source, heading: "## ボード")
        #expect(parts.board == "現在地\n### 論点\n~~~\n# 偽の境界\n~~~\n図\n")
        #expect(parts.minutes == "---\n## ボード\n---\n# 会議\n前文\n```md\n## ボード\n```\n## 次\n不変\n")
        let updated = try BoardSection.replacing(source, heading: "## ボード", body: "新版")
        #expect(updated == "---\n## ボード\n---\n# 会議\n前文\n```md\n## ボード\n```\n## ボード\n新版\n## 次\n不変\n")
        #expect(BoardSection.split("## ボード\n中\n# 後\n外", heading: "## ボード").board == "中\n")
        #expect(BoardSection.split("\u{FEFF}---\r\n## ボード\r\n---\r\n## ボード\r\n中\r\n#\t後\r\n外", heading: "## ボード").board == "中\r\n")
        #expect(BoardSection.split("## ボード\n中\n##\n外", heading: "## ボード").board == "中\n")
    }
    @Test func 無ければ末尾へ追加しNFCとNFDを同一視する() throws {
        #expect(try BoardSection.replacing("前文", heading: "## ボード", body: "初版") == "前文\n## ボード\n初版\n")
        #expect(try BoardSection.replacing("", heading: "## ボード", body: "初版") == "## ボード\n初版\n")
        #expect(try BoardSection.replacing("## ボード", heading: "## ボード", body: "初版") == "## ボード\n初版\n")
        let nfd = "## カード\n内容\n## 外\n維持"
        #expect(BoardSection.split(nfd, heading: "## カード").board == "内容\n")
        #expect(try BoardSection.replacing(nfd, heading: "## カード", body: "新版").utf8.elementsEqual("## カード\n新版\n## 外\n維持".utf8))
        #expect(try BoardSection.replacing("## ボード\r\n旧\r\n## 外\r\n維持", heading: "## ボード", body: "新版") == "## ボード\r\n新版\n## 外\r\n維持")
    }
    private func participant(trigger: AIParticipantContext.Trigger? = nil, heading: String? = nil) -> AIParticipantContext {
        AIParticipantContext(streamID: UUID(), requestID: UUID(), sessionGeneration: 1, participantName: "ボード",
            cliPath: "/tmp/helper", sessionPath: "/tmp/session.json", requestToken: "token", question: BoardPrompt.builtIn,
            capturedAt: Date(timeIntervalSince1970: 100), audioCutoffSeconds: 1, trigger: trigger, boardHeading: heading)
    }
    @Test func envelopeは省略だけを未指定として検証する() throws {
        let old = participant()
        let bytes = try AIJSON.encode(old)
        let encoded = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(encoded["board_heading"] == nil)
        let new = participant(heading: "## ボード")
        #expect(try AIJSON.decode(AIParticipantContext.self, from: AIJSON.encode(new)) == new)
        for value: Any in [NSNull(), 1, true, "", "ボード", "## ボード\n## 他"] {
            var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            json["board_heading"] = value
            let data = try JSONSerialization.data(withJSONObject: json)
            #expect(throws: (any Error).self) { try AIJSON.decode(AIParticipantContext.self, from: data) }
        }
    }
    @Test func 会議の固定見出しはパス変更と復元で残る() throws {
        var state = MinutesState(meetingID: UUID())
        try state.select("/tmp/minutes.md", at: Date())
        try state.bindBoard("## ボード")
        try state.bindBoard("## ボード")
        #expect(throws: (any Error).self) { try state.bindBoard("## 別のボード") }
        try state.select(nil, at: Date())
        #expect(try AIJSON.decode(MinutesState.self, from: AIJSON.encode(state)).boardHeading == "## ボード")
    }
    @Test func 内蔵文面と文書を機械照合する() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let doc = try String(contentsOf: root.appendingPathComponent("docs/board.md"), encoding: .utf8)
        let start = try #require(doc.range(of: "````text\n"))
        let end = try #require(doc.range(of: "\n````", range: start.upperBound..<doc.endIndex))
        #expect(String(doc[start.upperBound..<end.lowerBound]) == BoardPrompt.builtIn)
        let locationStart = try #require(doc.range(of: "```text\n", range: end.upperBound..<doc.endIndex))
        let locationEnd = try #require(doc.range(of: "\n```", range: locationStart.upperBound..<doc.endIndex))
        #expect(String(doc[locationStart.upperBound..<locationEnd.lowerBound]) == BoardPrompt.locationInstruction)
    }
    @Test func 自動の送信文だけ要約する() throws {
        let meeting = UUID()
        var history = try AIStreamHistory(meetingID: meeting)
        let snapshot = try history.prepare(lines: ["会話"], outputDirectory: URL(fileURLWithPath: "/tmp"))
        for automatic in [true, false] {
            let p = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
                participantName: "ボード", cliPath: "/tmp/helper", sessionPath: "/tmp/.kikigaki-context/\(meeting.uuidString)/ai/sessions/1.json",
                requestToken: "token", question: BoardPrompt.builtIn, capturedAt: Date(), audioCutoffSeconds: 1,
                trigger: automatic ? .scheduled : nil, boardHeading: "## ボード")
            let request = try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: p), number: 1)
            var conversation = AIConversation(meetingID: meeting)
            try conversation.append(request)
            let markdown = AIMarkdown.section(conversation)
            #expect(markdown.contains("ボードを更新(## ボード)") == automatic)
            #expect(markdown.contains("classDef now") == !automatic)
        }
    }
}
