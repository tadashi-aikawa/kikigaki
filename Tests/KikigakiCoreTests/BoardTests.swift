import Foundation
import Testing
@testable import KikigakiCore

@Suite struct BoardTests {
    @Test func 設定は板と手動プロンプトを共存させる() throws {
        let parsed = try ConfigLoader.parse(toml: """
        [[ai]]
        board = "## 板"
        autoPrompt = "議事録を更新"
        autoStart = true
        """)
        let profile = try #require(ResolvedConfig(config: parsed, home: URL(fileURLWithPath: "/tmp")).aiProfiles.first)
        #expect(profile.scheduledPrompt == BoardPrompt.builtIn)
        #expect(profile.autoPrompt == "議事録を更新")
        #expect(try AIJSON.decode(ResolvedAIConfig.self, from: AIJSON.encode(profile)) == profile)
        let custom = ResolvedAIConfig(config: AIConfig(board: "# 板", boardPrompt: "独自の板"), home: URL(fileURLWithPath: "/tmp"))
        #expect(custom.scheduledPrompt == "独自の板")
        try AIConfig(autoStart: true, board: "# 板").validate()
    }
    @Test(arguments: ["", "板", "##", "## ", "####### 板", "##板", "## 板\n## 板", " ## 板", "## \0"])
    func 不正見出しを拒否する(_ heading: String) {
        #expect(throws: (any Error).self) { try AIConfig(board: heading).validate() }
    }
    @Test func 設定の孤立プロンプトと重複と型違いを拒否する() {
        for toml in ["[ai]\nboardPrompt = '更新'", "[ai]\nboard = 3", "[ai]\nboard = '## 板'\nboardPrompt = ''",
                     "[[ai]]\nname = 'a'\nboard = '## カード'\n[[ai]]\nname = 'b'\nboard = '## カード'"] {
            #expect(throws: (any Error).self) { try ConfigLoader.parse(toml: toml) }
        }
    }
    @Test func 節の境界は同階層以上でコードとfrontmatterを除く() throws {
        let source = "---\n## 板\n---\n# 会議\n前文\n```md\n## 板\n```\n## 板\n現在地\n### 論点\n~~~\n# 偽の境界\n~~~\n図\n## 次\n不変\n"
        let parts = BoardSection.split(source, heading: "## 板")
        #expect(parts.board == "現在地\n### 論点\n~~~\n# 偽の境界\n~~~\n図\n")
        #expect(parts.minutes == "---\n## 板\n---\n# 会議\n前文\n```md\n## 板\n```\n## 次\n不変\n")
        let updated = try BoardSection.replacing(source, heading: "## 板", body: "新版")
        #expect(updated == "---\n## 板\n---\n# 会議\n前文\n```md\n## 板\n```\n## 板\n新版\n## 次\n不変\n")
        #expect(BoardSection.split("## 板\n中\n# 後\n外", heading: "## 板").board == "中\n")
        #expect(BoardSection.split("\u{FEFF}---\r\n## 板\r\n---\r\n## 板\r\n中\r\n#\t後\r\n外", heading: "## 板").board == "中\r\n")
        #expect(BoardSection.split("## 板\n中\n##\n外", heading: "## 板").board == "中\n")
    }
    @Test func 無ければ末尾へ追加しNFCとNFDを同一視する() throws {
        #expect(try BoardSection.replacing("前文", heading: "## 板", body: "初版") == "前文\n## 板\n初版\n")
        #expect(try BoardSection.replacing("", heading: "## 板", body: "初版") == "## 板\n初版\n")
        #expect(try BoardSection.replacing("## 板", heading: "## 板", body: "初版") == "## 板\n初版\n")
        let nfd = "## カード\n内容\n## 外\n維持"
        #expect(BoardSection.split(nfd, heading: "## カード").board == "内容\n")
        #expect(try BoardSection.replacing(nfd, heading: "## カード", body: "新版").utf8.elementsEqual("## カード\n新版\n## 外\n維持".utf8))
        #expect(try BoardSection.replacing("## 板\r\n旧\r\n## 外\r\n維持", heading: "## 板", body: "新版") == "## 板\r\n新版\n## 外\r\n維持")
    }
    private func participant(trigger: AIParticipantContext.Trigger? = nil, heading: String? = nil) -> AIParticipantContext {
        AIParticipantContext(streamID: UUID(), requestID: UUID(), sessionGeneration: 1, participantName: "板",
            cliPath: "/tmp/helper", sessionPath: "/tmp/session.json", requestToken: "token", question: BoardPrompt.builtIn,
            capturedAt: Date(timeIntervalSince1970: 100), audioCutoffSeconds: 1, trigger: trigger, boardHeading: heading)
    }
    @Test func envelopeは省略だけを未指定として検証する() throws {
        let old = participant()
        let bytes = try AIJSON.encode(old)
        let encoded = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(encoded["board_heading"] == nil)
        let new = participant(heading: "## 板")
        #expect(try AIJSON.decode(AIParticipantContext.self, from: AIJSON.encode(new)) == new)
        for value: Any in [NSNull(), 1, true, "", "板", "## 板\n## 他"] {
            var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            json["board_heading"] = value
            let data = try JSONSerialization.data(withJSONObject: json)
            #expect(throws: (any Error).self) { try AIJSON.decode(AIParticipantContext.self, from: data) }
        }
    }
    @Test func 会議の固定見出しはパス変更と復元で残る() throws {
        var state = MinutesState(meetingID: UUID())
        try state.select("/tmp/minutes.md", at: Date())
        try state.bindBoard("## 板")
        try state.bindBoard("## 板")
        #expect(throws: (any Error).self) { try state.bindBoard("## 別の板") }
        try state.select(nil, at: Date())
        #expect(try AIJSON.decode(MinutesState.self, from: AIJSON.encode(state)).boardHeading == "## 板")
    }
    @Test func 内蔵文面と文書を機械照合する() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let doc = try String(contentsOf: root.appendingPathComponent("docs/board.md"), encoding: .utf8)
        let start = try #require(doc.range(of: "````text\n"))
        let end = try #require(doc.range(of: "\n````", range: start.upperBound..<doc.endIndex))
        #expect(String(doc[start.upperBound..<end.lowerBound]) == BoardPrompt.builtIn)
    }
    @Test func 自動の送信文だけ要約する() throws {
        let meeting = UUID()
        var history = try AIStreamHistory(meetingID: meeting)
        let snapshot = try history.prepare(lines: ["会話"], outputDirectory: URL(fileURLWithPath: "/tmp"))
        for automatic in [true, false] {
            let p = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
                participantName: "板", cliPath: "/tmp/helper", sessionPath: "/tmp/.kikigaki-context/\(meeting.uuidString)/ai/sessions/1.json",
                requestToken: "token", question: BoardPrompt.builtIn, capturedAt: Date(), audioCutoffSeconds: 1,
                trigger: automatic ? .scheduled : nil, boardHeading: "## 板")
            let request = try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: p), number: 1)
            var conversation = AIConversation(meetingID: meeting)
            try conversation.append(request)
            let markdown = AIMarkdown.section(conversation)
            #expect(markdown.contains("板を更新(## 板)") == automatic)
            #expect(markdown.contains("classDef now") == !automatic)
        }
    }
}
