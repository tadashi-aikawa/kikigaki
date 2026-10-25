import AppKit
import Foundation
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import Kikigaki

extension AppKitTests {
@Suite(.timeLimit(.minutes(1))) @MainActor struct AIAppendixTests {
    private func setup(_ root: URL, fake: FakeHerdr, scheduled: Bool = false,
                       identifySpeakers: Bool = false) async throws -> (AIConversationController, ResolvedAIConfig, AIRequest) {
        let config = ResolvedAIConfig(config: AIConfig(command: "/bin/echo", cwd: root.path, identifySpeakers: identifySpeakers), home: root)
        let controller = try testAIController(meetingID: UUID(), outputDirectory: root, herdr: AIHerdr(run: { try await fake.run($0, $1) }))
        let request = try controller.prepare(lines: ["[12:00:00] A: 最初の会話"], question: "作業して", voiceQuestion: "",
            capturedAt: Date(), cutoff: 1, tail: nil, config: config, helper: URL(fileURLWithPath: "/bin/echo"),
            workAllowed: false, trigger: scheduled ? .scheduled : nil)
        try await controller.connect(config: config, label: "test", executable: URL(fileURLWithPath: "/bin/echo"), arguments: [])
        try await controller.send(request, config: config)
        return (controller, config, request)
    }
    private func result(_ controller: AIConversationController, root: URL, request: AIRequest, numbers: [Int]? = nil) throws {
        let event = try AIReceiveEvent(request: request, kind: .answered, recordedAt: Date(), body: "反映しました", appliedAppendices: numbers)
        try AIFileStore(root: root).write(AIJSON.encode(event), to: [".kikigaki-context", controller.meetingID.uuidString, "ai", "inbox", event.filename], replacing: false)
        controller.scan()
    }
    private func waitForRetry(_ controller: AIConversationController) async throws {
        for _ in 0..<200 {
            if !controller.hasPendingAppendices { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("追記の送り直しが完了しません")
    }

    @Test(arguments: [false, true]) func 作業中へ二回追記し反映した番号だけ閉じ残りは同じ種類で送り直す(scheduled: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let (controller, config, request) = try await setup(root, fake: fake, scheduled: scheduled)
        defer { controller.stopWatching() }
        await fake.setStatuses(["working"]); try await controller.refreshConnection()
        #expect(controller.canAppend(slot: 1) && !controller.canSend)
        let first = ["[12:00:00] A: 最初の会話", "[12:00:01] A: 赤にして"]
        try await controller.append(to: request.id, lines: first, question: "色を修正", capturedAt: Date(), cutoff: 2, tail: nil, config: config)
        try await controller.append(to: request.id, lines: first + ["[12:00:02] A: 二か所とも"], question: "二か所", capturedAt: Date(), cutoff: 3, tail: nil, config: config)
        let q = controller.conversation.questions[0]
        #expect(controller.conversation.questions.count == 1 && q.appendices.count == 2)
        #expect(q.appendices.map { $0.snapshot.readStartLine } == [2, 3])
        let prompt = try q.appendices[1].prompt(for: request)
        #expect(prompt.range(of: "\"read_start_line\"\\s*:\\s*3", options: .regularExpression) != nil && prompt.contains("\"context\""))
        #expect(!prompt.contains("最初の会話") && !prompt.contains("赤にして") && !prompt.contains("\"lines\""))
        #expect(q.state == .submitted && q.request.trigger == request.trigger)
        #expect(try String(contentsOf: q.appendices[1].snapshot.fileURL, encoding: .utf8).contains("二か所"))
        #expect(await fake.commands.filter { $0.prefix(2) == ["agent", "prompt"] }.count == 3)
        await fake.setStatuses(["idle"])
        try result(controller, root: root, request: request, numbers: [1])
        try await waitForRetry(controller)
        #expect(controller.conversation.questions.count == 2)
        let original = controller.conversation.questions[0], forwarded = controller.conversation.questions[1]
        #expect(original.hasApplied(original.appendices[0]) && !original.hasApplied(original.appendices[1]))
        #expect(original.appendices[1].forwardedRequestID == forwarded.request.id)
        #expect(forwarded.request.trigger == request.trigger && !forwarded.request.envelope.participant.workAllowed)
        #expect(forwarded.request.displayQuestion.contains("二か所") && !forwarded.request.displayQuestion.contains("色を修正"))
        #expect(forwarded.request.envelope.kind == .full && forwarded.state == .submitted)
        controller.scan(); try await Task.sleep(for: .milliseconds(20))
        #expect(controller.conversation.questions.count == 2)
        let markdown = AIMarkdown.section(controller.conversation)
        #expect(markdown.contains("#### 追記 1") && markdown.contains("色を修正") && markdown.contains("赤にして"))
        #expect(markdown.contains("反映済み") && markdown.contains("#2へ送り直し"))
        let saved = try AIJSON.encode(controller.conversation)
        #expect(try AIJSON.encode(AIJSON.decode(AIConversation.self, from: saved)) == saved)
    }

    @Test func 返事が追記のペイン入力より先に届いても次の依頼へ送り直す() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), (controller, config, request) = try await setup(root, fake: fake)
        defer { controller.stopWatching() }
        await fake.onCommand { args in
            if args.prefix(2) == ["agent", "prompt"], args.last?.contains("KIKIGAKI_APPENDIX") == true {
                try? await MainActor.run { try result(controller, root: root, request: request) }
            }
        }
        try await controller.append(to: request.id, lines: ["[12:00:00] A: 後の指示"], question: "追加の指示", capturedAt: Date(), cutoff: 2, tail: nil, config: config)
        try await waitForRetry(controller)
        #expect(controller.conversation.questions.count == 2)
        #expect(controller.conversation.questions[0].appendices[0].forwardedRequestID == controller.conversation.questions[1].request.id)
    }

    /// 送り直しは新しい依頼なので、話者名の割当はその時点の名前で作り直す。元の依頼の固定情報は後に付いた名前を知らない。
    @Test(arguments: [true, false]) func 話者を推定する宛先の送り直しにはいまの割当を同梱する(identifySpeakers: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), (controller, config, request) = try await setup(root, fake: fake, identifySpeakers: identifySpeakers)
        defer { controller.stopWatching() }
        let current = SpeakerIdentification(unresolved: ["A", "B"], candidates: [], origin: .participants,
                                            tentative: ["B": "中村"], tentativeEvents: ["B": "\(request.id.uuidString)/speaker/B"])
        controller.speakerIdentification = { current }
        try await controller.append(to: request.id, lines: ["[12:00:00] A: 後の指示"], question: "推定し直して", capturedAt: Date(), cutoff: 2, tail: nil, config: config)
        try result(controller, root: root, request: request)
        try await waitForRetry(controller)
        let forwarded = try #require(controller.conversation.questions.last?.request)
        #expect(forwarded.id != request.id)
        #expect(forwarded.envelope.participant.speakerIdentification == (identifySpeakers ? current : nil))
        #expect(forwarded.envelope.participant.question.contains(SpeakerIdentificationPrompt.builtIn) == identifySpeakers)
    }

    @Test func 確定待ち中に返事が届いた追記も新しい依頼へ引き継ぐ() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), (controller, config, request) = try await setup(root, fake: fake)
        defer { controller.stopWatching() }
        try result(controller, root: root, request: request)
        try await controller.append(to: request.id, lines: ["[12:00:01] A: 新しい指示"], question: "続けて", capturedAt: Date(), cutoff: 2, tail: nil, config: config)
        try await waitForRetry(controller)
        #expect(controller.conversation.questions.count == 2)
        #expect(await fake.commands.filter { $0.prefix(2) == ["agent", "prompt"] && $0.last?.contains("KIKIGAKI_APPENDIX") == true }.isEmpty)
    }

    @Test(arguments: ["blocked", "missing", "unknown"]) func 送れない接続では追記を受け付けない(status: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), (controller, config, request) = try await setup(root, fake: fake)
        defer { controller.stopWatching() }
        await fake.setStatuses([status]); try? await controller.refreshConnection()
        #expect(!controller.canAppend(slot: 1))
        await #expect(throws: (any Error).self) {
            try await controller.append(to: request.id, lines: ["会話"], question: "追記", capturedAt: Date(), cutoff: 2, tail: nil, config: config)
        }
        #expect(controller.conversation.questions[0].appendices.isEmpty)
    }

    @Test func 手動シートの送信名が追記に変わる() {
        let sheet = AIQuestionSheet(participant: "迅雷", parentNumber: nil, draft: "補足", voice: "", range: "1行", tentative: false, canSubmit: true)
        sheet.update(progress: nil, canSubmit: true, appending: true)
        #expect(sheet.sendButton.title == "追記して送る" && sheet.sendButton.isEnabled)
        sheet.update(progress: nil, canSubmit: false, appending: true)
        #expect(!sheet.sendButton.isEnabled)
        sheet.update(progress: nil, canSubmit: true)
        #expect(sheet.sendButton.title == "送信")
    }

    @Test func 全番号を反映した返事では依頼を増やさない() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), (controller, config, request) = try await setup(root, fake: fake)
        defer { controller.stopWatching() }
        try await controller.append(to: request.id, lines: ["[12:00:01] A: 追加の会話"], question: "追加", capturedAt: Date(), cutoff: 2, tail: nil, config: config)
        try result(controller, root: root, request: request, numbers: [1])
        try await waitForRetry(controller)
        #expect(controller.conversation.questions.count == 1 && controller.canSend)
    }

    @Test func 未反映の追記を残して接続を作り直しても新しい世代へ送り直す() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), (controller, config, request) = try await setup(root, fake: fake)
        defer { controller.stopWatching() }
        try await controller.append(to: request.id, lines: ["会話", "追加の指示"], question: "続けて", capturedAt: Date(), cutoff: 2, tail: nil, config: config)
        await fake.setStatuses(["missing"])
        try result(controller, root: root, request: request)
        for _ in 0..<200 {
            if controller.warning?.contains("未反映の追記を送り直せません") == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.hasPendingAppendices && controller.conversation.questions.count == 1)
        await fake.setStatuses(["idle"])
        try controller.newGeneration()
        try await waitForRetry(controller)
        let forwarded = try #require(controller.conversation.questions.last)
        #expect(controller.conversation.questions.count == 2 && forwarded.state == .submitted)
        #expect(forwarded.request.envelope.participant.sessionGeneration == 2)
        #expect(controller.conversation.questions[0].appendices[0].forwardedRequestID == forwarded.request.id)
    }

    /// 話者を推定する宛先では内蔵節の分も差し引いて分け、単独で上限近くの追記は割当を外して本文を届ける。
    @Test(arguments: [false, true]) func 上限近くの追記も切り詰めず依頼を分けて送り直す(identifySpeakers: Bool) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr(), (controller, config, request) = try await setup(root, fake: fake, identifySpeakers: identifySpeakers)
        defer { controller.stopWatching() }
        let identification = SpeakerIdentification(unresolved: ["A"], candidates: [])
        controller.speakerIdentification = { identification }
        let text = String(repeating: "字", count: AILimits.questionBytes / 3)
        try await controller.append(to: request.id, lines: ["会話"], question: text, capturedAt: Date(), cutoff: 2, tail: nil, config: config)
        try await controller.append(to: request.id, lines: ["会話", "続き"], question: "残りの指示", capturedAt: Date(), cutoff: 3, tail: nil, config: config)
        try result(controller, root: root, request: request)
        for _ in 0..<200 {
            if controller.conversation.questions.count == 2 && controller.conversation.questions[1].state == .submitted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.conversation.questions.count == 2)
        let first = try #require(controller.conversation.questions.last?.request)
        #expect(first.displayQuestion == text)
        #expect(first.envelope.participant.speakerIdentification == nil)
        try result(controller, root: root, request: first)
        try await waitForRetry(controller)
        #expect(controller.conversation.questions.count == 3)
        let rest = try #require(controller.conversation.questions.last?.request)
        #expect(rest.displayQuestion.contains("残りの指示"))
        #expect(rest.envelope.participant.speakerIdentification == (identifySpeakers ? identification : nil))
    }
}
}
