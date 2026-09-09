import AppKit
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import KikigakiCLI
@testable import Kikigaki

/// クロスレビューで見つかった、プロファイル間の状態混在の再発防止。
@Suite(.timeLimit(.minutes(1))) @MainActor struct AIProfileRegressionTests {
    private func profiles(_ root: URL, toml: String) throws -> [ResolvedAIConfig] {
        ResolvedConfig(config: try ConfigLoader.parse(toml: toml), home: root).aiProfiles
    }
    private func two(_ root: URL) throws -> [ResolvedAIConfig] {
        try profiles(root, toml: """
        [[ai]]
        name = "議事録"
        command = "/bin/echo"
        cwd = "\(root.path)"
        address = "迅雷へ"

        [[ai]]
        name = "相談"
        command = "/bin/echo"
        cwd = "\(root.path)"
        address = "ネオへ"
        """)
    }
    private func session(_ root: URL, profiles: [ResolvedAIConfig], fake: FakeHerdr, recordedSamples: Int = 0) -> MeetingSession {
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        var config = ResolvedConfig(config: KikigakiConfig(), home: root)
        config.aiProfiles = profiles
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config,
                                     aiStore: store, recordedSamples: recordedSamples)
        session.automaticHelper = URL(fileURLWithPath: "/bin/echo")
        return session
    }
    private func submit(_ session: MeetingSession, profile: ResolvedAIConfig?, parent: UUID? = nil) async throws {
        session.submitAI(question: "質問", full: false, parent: parent, helper: URL(fileURLWithPath: "/bin/echo"), profile: profile)
        let slot = profile?.slot ?? session.aiConfiguration?.slot ?? 1
        if let task = session.submissionTaskForTesting(slot: slot) ?? session.submissionTaskForTesting { await task.value }
    }
    private func deliver(_ session: MeetingSession, _ request: AIRequest, kind: AIReceiveEvent.Kind,
                         body: String, reason: String? = nil) throws {
        let event = try AIReceiveEvent(request: request, kind: kind, recordedAt: Date(), body: body, reason: reason)
        try AIFileStore(root: session.aiRecord!.controller.outputDirectory)
            .write(AIJSON.encode(event), to: [".kikigaki-context", session.aiMeetingID.uuidString, "ai", "inbox", event.filename],
                   replacing: false)
        session.aiRecord?.controller.scan()
    }

    /// 【高】確認質問への返答が現在の手動宛先へ送られていた。
    @Test func 確認への返答は宛先を変えても元の質問へ返る() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try two(root)
        let session = session(root, profiles: list, fake: fake)
        try await submit(session, profile: list[0])
        let controller = try #require(session.aiRecord?.controller)
        let asked = try #require(controller.conversation.questions.first?.request)
        try deliver(session, asked, kind: .needsInput, body: "会場は本社でよいですか", reason: "clarification")

        // 手動の宛先を相談へ変えてから、議事録の確認へ返答する。
        session.selectAIProfile(slot: 2)
        #expect(session.aiConfiguration?.slot == 2)
        try await submit(session, profile: session.aiConfiguration, parent: asked.id)

        let followup = try #require(controller.conversation.questions.last?.request)
        #expect(followup.id != asked.id)
        #expect(followup.envelope.participant.profileSlot == asked.envelope.participant.profileSlot)
        #expect(followup.envelope.participant.participantName == "迅雷")
    }

    /// 会話の整合検証でも親子の枠違いを拒否する。
    @Test func 枠の違う返答を会話が受け付けない() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID()
        var history = try AIStreamHistory(meetingID: meeting)
        func request(_ number: Int, slot: Int, parent: AIQuestion? = nil) throws -> AIRequest {
            let snapshot = try history.prepare(lines: ["[12:00:00] A: 質問です"], outputDirectory: root)
            let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(), sessionGeneration: 1,
                participantName: "迅雷", cliPath: "/tmp/helper",
                sessionPath: root.appendingPathComponent(".kikigaki-context/\(meeting.uuidString)/"
                    + AIEnvelope.sessionPath(slot: slot, generation: 1)).path,
                requestToken: "token", question: "問い", capturedAt: Date(), audioCutoffSeconds: 1,
                inReplyToRequestID: parent?.request.id,
                inReplyToEventID: parent?.result.map { "\($0.requestID.uuidString)/result" },
                profile: "議事録", profileSlot: slot)
            return try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant), number: number, snapshot: snapshot)
        }
        var conversation = AIConversation(meetingID: meeting)
        let first = try request(1, slot: 1)
        try conversation.append(first)
        try conversation.update(first.id) { try $0.beginSending(at: Date()); try $0.submitted() }
        _ = try conversation.receive(AIReceiveEvent(request: first, kind: .needsInput, recordedAt: Date(),
            body: "確認です", reason: "clarification"), at: Date())
        let parent = try #require(conversation.questions.first)
        #expect(throws: AIError.mismatch) { try conversation.append(try request(2, slot: 2, parent: parent)) }
        #expect(throws: Never.self) { try conversation.append(try request(2, slot: 1, parent: parent)) }
    }

    /// 【中】Aの送信準備中にBが送れなくなっていた。
    @Test func 別プロファイルの送信は互いを塞がない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try two(root)
        let session = session(root, profiles: list, fake: fake)
        // 1件目の完了を待たずに2件目を投げる。
        session.submitAI(question: "議事録へ", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"), profile: list[0])
        session.submitAI(question: "相談へ", full: false, parent: nil, helper: URL(fileURLWithPath: "/bin/echo"), profile: list[1])
        let first = try #require(session.submissionTaskForTesting(slot: 1))
        let second = try #require(session.submissionTaskForTesting(slot: 2))
        await first.value; await second.value
        let controller = try #require(session.aiRecord?.controller)
        #expect(controller.conversation.questions.count == 2)
        #expect(controller.conversation.questions.map { $0.request.envelope.participant.profileSlot } == [1, 2])
        // 別チャネルなので接続先も分かれる。
        #expect(controller.connection(slot: 1)?.paneID != controller.connection(slot: 2)?.paneID)
    }

    /// 【中】Bの回答でAの送達不明の警告が消えていた。
    @Test func 別チャネルの回答でこちらの警告を消さない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try two(root)
        let session = session(root, profiles: list, fake: fake)
        try await submit(session, profile: list[0])
        let controller = try #require(session.aiRecord?.controller)
        // 議事録の送信を送達不明にする。
        await fake.failPrompt {}
        try await submit(session, profile: list[1])
        #expect(controller.warning != nil)
        let minutes = try #require(controller.conversation.questions.first?.request)
        try deliver(session, minutes, kind: .answered, body: "議事録を更新しました")
        // 議事録の回答では相談の警告は晴れない。
        #expect(controller.warning != nil)
    }

    /// 【中】自動の宛先が手動の選択に追随していた。
    @Test func 手動の宛先を変えても自動の宛先は動かない() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = session(root, profiles: try two(root), fake: FakeHerdr())
        #expect(session.aiConfiguration?.slot == 1 && session.aiScheduleConfiguration?.slot == 1)
        session.selectAIProfile(slot: 2)
        #expect(session.aiConfiguration?.slot == 2 && session.aiScheduleConfiguration?.slot == 1)
        session.selectAIProfile(slot: 2, forSchedule: true)
        #expect(session.aiScheduleConfiguration?.slot == 2 && session.aiConfiguration?.slot == 2)
    }

    /// 【中】宛先を選び直すと共通ホットキーが変わっていた。
    @Test func 宛先を変えてもホットキーは1つ目のもの() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let list = try profiles(root, toml: """
        [[ai]]
        name = "議事録"
        [ai.hotkey]
        modifiers = ["cmd", "shift"]
        key = "j"

        [[ai]]
        name = "相談"
        """)
        let session = session(root, profiles: list, fake: FakeHerdr())
        #expect(session.snapshot.ai?.hotkey.key == "j")
        session.selectAIProfile(slot: 2)
        #expect(session.aiConfiguration?.slot == 2)
        #expect(session.snapshot.ai?.hotkey.key == "j")
        #expect(session.aiPrimaryConfiguration?.slot == 1)
    }

    /// 【中】全質問の接続状態・世代が選択中の宛先に依存していた。
    @Test func 印の接続状態と世代は送った枠のものを見る() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID()
        var history = try AIStreamHistory(meetingID: meeting)
        func request(_ number: Int, slot: Int, generation: Int) throws -> AIRequest {
            let snapshot = try history.prepare(lines: ["[12:00:00] A: 質問\(number)"], outputDirectory: root)
            let participant = AIParticipantContext(streamID: history.streamID, requestID: UUID(),
                sessionGeneration: generation, participantName: "迅雷", cliPath: "/tmp/helper",
                sessionPath: root.appendingPathComponent(".kikigaki-context/\(meeting.uuidString)/"
                    + AIEnvelope.sessionPath(slot: slot, generation: generation)).path,
                requestToken: "token", question: "問い", capturedAt: Date(), audioCutoffSeconds: 1,
                profile: "P\(slot)", profileSlot: slot)
            return try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant), number: number, snapshot: snapshot)
        }
        let a = try request(1, slot: 1, generation: 1), b = try request(2, slot: 2, generation: 1)
        var state = AIViewState()
        state.defaultSlot = 1
        // Aだけ世代2へ作り直し、Aの接続だけ切れている状況。
        state.generations = [1: 2, 2: 1]
        state.connections = [1: .disconnected, 2: .idle]
        state.generation = 2; state.connection = .disconnected
        #expect(state.generation(for: a) == 2 && state.generation(for: b) == 1)
        #expect(state.connection(for: a) == .disconnected && state.connection(for: b) == .idle)
        // Bの世代1は現世代なので「旧接続からの返事」にならない。
        #expect(b.envelope.participant.sessionGeneration == state.generation(for: b))
        #expect(a.envelope.participant.sessionGeneration < state.generation(for: a))
    }

    /// 【中】旧manifestの長い宛名で回収できなくなっていた。
    @Test func 宛名から補った長い名前でも旧manifestを読める() throws {
        let long = String(repeating: "あ", count: 22)
        let legacy = """
        {"cli":"codex","address":"\(long)へ","cwd":"file:///out/","extraArgs":[],"prompt":"",
         "notifySound":false,"hotkey":{"modifiers":["cmd"],"key":"a"}}
        """
        let decoded = try AIJSON.decode(ResolvedAIConfig.self, from: Data(legacy.utf8))
        #expect(decoded.name == long && decoded.participantName == long)
        // 設定として同じ宛名を書いても解析でき、往復しても壊れない。
        let parsed = ResolvedConfig(config: try ConfigLoader.parse(toml: "[ai]\naddress = \"\(long)へ\""),
                                    home: URL(fileURLWithPath: "/home/person")).aiProfiles[0]
        #expect(try AIJSON.decode(ResolvedAIConfig.self, from: AIJSON.encode(parsed)) == parsed)
        // 明示した長い name は今までどおり拒否する。
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: "[[ai]]\nname = \"\(long)\"") }
    }

    /// 【中】herdrCommand は共通設定。
    @Test func herdrCommandの不一致を拒否する() throws {
        #expect(throws: ConfigError.self) {
            try ConfigLoader.parse(toml: """
            [[ai]]
            name = "議事録"
            herdrCommand = "/opt/homebrew/bin/herdr"

            [[ai]]
            name = "相談"
            herdrCommand = "/usr/local/bin/herdr"
            """)
        }
        #expect(throws: Never.self) {
            try ConfigLoader.parse(toml: """
            [[ai]]
            name = "議事録"
            herdrCommand = "/opt/homebrew/bin/herdr"

            [[ai]]
            name = "相談"
            herdrCommand = "/opt/homebrew/bin/herdr"
            """)
        }
    }

    /// 【低】通知音が常に先頭プロファイルの設定で決まっていた。
    @Test func 通知音は返答元のプロファイルの設定で決まる() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try profiles(root, toml: """
        [[ai]]
        name = "議事録"
        command = "/bin/echo"
        cwd = "\(root.path)"
        notifySound = false

        [[ai]]
        name = "相談"
        command = "/bin/echo"
        cwd = "\(root.path)"
        address = "ネオへ"
        notifySound = true
        """)
        let store = AIRecordStore(directory: root, makeHerdr: { AIHerdr(run: { try await fake.run($0, $1) }) })
        var config = ResolvedConfig(config: KikigakiConfig(), home: root)
        config.aiProfiles = list
        let session = MeetingSession(testingRecordingAt: root.appendingPathComponent("meeting.md"), config: config, aiStore: store)
        var notified: [Int] = []
        store.onNewResult = { _, slot in notified.append(slot) }
        try await submit(session, profile: list[1])
        let request = try #require(session.aiRecord?.controller.conversation.questions.first?.request)
        try deliver(session, request, kind: .answered, body: "回答")
        #expect(notified == [2])
        let source = try #require(session.aiRecord?.manifest.profiles.first { $0.slot == notified[0] })
        #expect(source.notifySound)
    }

    /// 【低】相手側CLIの正常なフックを不正イベントに数えていた。
    @Test func 別CLIのフックを不正イベントに数えない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        // 2つ目はClaude。世代はどちらも1で並ぶ。
        let list = try profiles(root, toml: """
        [[ai]]
        name = "議事録"
        cli = "codex"
        command = "/bin/echo"
        cwd = "\(root.path)"

        [[ai]]
        name = "相談"
        cli = "claude"
        command = "/bin/echo"
        cwd = "\(root.path)"
        address = "ネオへ"
        """)
        await fake.setProviders(["p": "codex", "w2:p1": "claude"])
        // Claudeは agent_session が立つまで入力可能とみなさない(実測)。
        await fake.setSessions(["p": "codex-thread", "w2:p1": "claude-session"])
        let session = session(root, profiles: list, fake: fake)
        try await submit(session, profile: list[0])
        try await submit(session, profile: list[1])
        let controller = try #require(session.aiRecord?.controller)
        let files = AIFileStore(root: controller.outputDirectory)
        let base = [".kikigaki-context", session.aiMeetingID.uuidString, "ai"]
        // 両チャネルのsession recordからフック観測を作って受信箱へ置く。
        for slot in [1, 2] {
            let path = base + AIEnvelope.sessionPath(slot: slot, generation: 1).split(separator: "/").dropFirst().map(String.init)
            let record = try AIJSON.decode(AISessionRecord.self, from: files.read(path, limit: 8192))
            // identityは実際の接続と揃える。ずれていると観測が捨てられても「不正なし」で緑になる。
            let identity = try #require(record.connection?.sessionID)
            let payload = record.provider == .codex
                ? Data("{\"type\":\"agent-turn-complete\",\"thread-id\":\"\(identity)\",\"turn-id\":\"u\"}".utf8)
                : Data("{\"hook_event_name\":\"Stop\",\"session_id\":\"\(identity)\"}".utf8)
            let event = try AIHookObservation(payload: payload, session: record, now: Date())
            try files.write(AIJSON.encode(event), to: base + ["inbox", event.filename], replacing: false)
        }
        controller.scan()
        // 相手側の観測を自分のproviderで検証して不正へ落とさない。
        #expect(controller.invalidInboxFiles.isEmpty)
    }

    /// 同じCLI・同じ世代の2枠でも、持ち主をidentityまで見て決めるので観測が落ちない。
    @Test func 同じCLIの2枠でも背景処理の状態が枠ごとに反映される() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        await fake.setProvider("claude")
        await fake.setSessions(["p": "session-a", "w2:p1": "session-b"])
        let list = try profiles(root, toml: """
        [[ai]]
        name = "議事録"
        cli = "claude"
        command = "/bin/echo"
        cwd = "\(root.path)"

        [[ai]]
        name = "相談"
        cli = "claude"
        command = "/bin/echo"
        cwd = "\(root.path)"
        address = "ネオへ"
        """)
        let session = session(root, profiles: list, fake: fake)
        try await submit(session, profile: list[0])
        try await submit(session, profile: list[1])
        let controller = try #require(session.aiRecord?.controller)
        #expect(controller.connection(slot: 1)?.sessionID == "session-a")
        #expect(controller.connection(slot: 2)?.sessionID == "session-b")
        let files = AIFileStore(root: controller.outputDirectory)
        let base = [".kikigaki-context", session.aiMeetingID.uuidString, "ai"]
        // 2枠目だけ背景処理が走っている観測を置く。世代もCLIも同じなので、
        // 持ち主をproviderと世代だけで選ぶと1枠目が拾って捨ててしまう。
        for slot in [1, 2] {
            let path = base + AIEnvelope.sessionPath(slot: slot, generation: 1).split(separator: "/").dropFirst().map(String.init)
            let record = try AIJSON.decode(AISessionRecord.self, from: files.read(path, limit: 8192))
            let identity = try #require(record.connection?.sessionID)
            let running = slot == 2 ? "[{\"status\":\"running\"}]" : "[]"
            let payload = Data("{\"hook_event_name\":\"Stop\",\"session_id\":\"\(identity)\",\"background_tasks\":\(running)}".utf8)
            let event = try AIHookObservation(payload: payload, session: record, now: Date())
            try files.write(AIJSON.encode(event), to: base + ["inbox", event.filename], replacing: false)
        }
        controller.scan()
        #expect(controller.invalidInboxFiles.isEmpty)
        // 背景処理中の枠は「返送未確認」を出さない。もう片方は出せる状態のまま。
        let questions = controller.conversation.questions
        let later = Date().addingTimeInterval(600)
        #expect(!controller.isReturnUnconfirmed(questions[1], now: later))
        #expect(controller.isReturnUnconfirmed(questions[0], now: later))
    }

    /// 接続待ちで止まっている送信を作り、そのTaskを返す。取消・停止の競合はこの状態でしか起きない。
    /// 取消はTask参照をnilにするので、**呼び手は取消の前にこれを受け取っておく**。
    @discardableResult
    private func stalledSubmit(_ session: MeetingSession, profile: ResolvedAIConfig,
                               fake: FakeHerdr, trigger: AIParticipantContext.Trigger? = nil) async throws -> Task<Void, Never> {
        await fake.setStatuses(["unknown"])
        session.submitAI(question: "接続待ちの依頼", full: false, parent: nil,
                         helper: URL(fileURLWithPath: "/bin/echo"), trigger: trigger, profile: profile)
        let task = try #require(session.submissionTaskForTesting(slot: profile.slot))
        // requestが保存され、接続先が決まり、その接続の生存確認まで走ったことを確かめる。
        // ここまで来ていなければ「接続待ち」ではないので、競合を再現できていない。
        try await waitUntil("接続待ちに入る") {
            guard let controller = session.aiRecord?.controller,
                  controller.conversation.questions.contains(where: {
                      $0.request.envelope.participant.profileSlot == profile.slot }),
                  let pane = controller.connection(slot: profile.slot)?.paneID else { return false }
            return await fake.commands.contains { Array($0.prefix(3)) == ["agent", "get", pane] }
        }
        return task
    }
    /// 条件が満たされるまで待つ。時間切れは失敗にする(黙って進むと競合を再現できていない)。
    private func waitUntil(_ what: String, limit: Int = 400, _ condition: () async -> Bool) async throws {
        for _ in 0..<limit {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("\(what)まで待てなかった")
    }

    /// 【中】手動シートの取消が、送信を始めた枠ではなく取消時点の選択枠を見ていた。
    /// Aへ送って接続待ちの間にBへ変えて取り消すと、Aが接続完了後に飛んでいた。
    @Test func 送信後に宛先を変えても取消は送信した枠へ効く() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try two(root)
        let session = session(root, profiles: list, fake: fake)
        let before = await fake.commands.filter { Array($0.prefix(2)) == ["agent", "prompt"] }.count

        // 取消はTask参照をnilにするので、先に受け取っておく。
        let task = try await stalledSubmit(session, profile: list[0], fake: fake)
        // 接続待ちのまま宛先をBへ変える。シートは送信を始めた枠を持ち続ける。
        session.selectAIProfile(slot: 2)
        #expect(session.aiConfiguration?.slot == 2)
        session.cancelAIPreparation(slot: 1)
        // 取消の後で接続が整っても、送ってはいけない。
        await fake.setStatuses(["idle"])
        await task.value
        let after = await fake.commands.filter { Array($0.prefix(2)) == ["agent", "prompt"] }.count
        #expect(after == before)
        let controller = try #require(session.aiRecord?.controller)
        #expect(controller.conversation.questions.allSatisfy { $0.state != .submitted })
    }

    /// シートは送信を始めた枠を覚え、以後は宛先を選び直せない。
    @Test func シートは送信を始めた枠を保持し宛先を固定する() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let sheet = AIQuestionSheet(participant: "議事録", parentNumber: nil, draft: "依頼",
            voice: "", range: "対象なし", tentative: false, canSubmit: true)
        sheet.updateDestinations([.init(slot: 1, name: "議事録"),
                                  .init(slot: 2, name: "相談")], selected: 1, participant: "議事録")
        #expect(sheet.activeSlot == nil && sheet.owningSlot == 1)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let send = try #require(descendants(sheet.window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "送信" })
        send.performClick(nil)
        #expect(sheet.activeSlot == 1 && sheet.owningSlot == 1)
        // 送信を始めた後の差し替えは無視する。宛先のポップアップも操作させない。
        sheet.updateDestinations([.init(slot: 1, name: "議事録"),
                                  .init(slot: 2, name: "相談")], selected: 2, participant: "相談")
        #expect(sheet.owningSlot == 1)
        let popup = try #require(descendants(sheet.window.contentView!).compactMap { $0 as? NSPopUpButton }.first)
        #expect(!popup.isEnabled)
    }

    /// 【中】別枠が返事待ちだと自動送信を止められず、接続完了後に飛んでいた。
    @Test func 自動送信の停止は接続待ちの依頼も飛ばさない() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try two(root)
        // 自動送信は差分が無いと送らないので、会話本文を用意する。
        let session = session(root, profiles: list, fake: fake, recordedSamples: 16_000)
        session.setScheduleTranscriptForTesting("架空の会議です")
        // 1枠目を返事待ちにしておく。停止判定が会議全体を見ていると、ここで早期returnした。
        try await submit(session, profile: list[0])
        let controller = try #require(session.aiRecord?.controller)
        #expect(controller.conversation.questions.first?.isAwaitingResult == true)
        let before = await fake.commands.filter { Array($0.prefix(2)) == ["agent", "prompt"] }.count

        try session.startAISchedule(options: try AIScheduleOptions(prompt: "議事録を更新して", interval: 60),
                                    helper: URL(fileURLWithPath: "/bin/echo"), profile: list[1])
        let task = try await stalledSubmit(session, profile: list[1], fake: fake, trigger: .scheduled)
        session.stopAISchedule()
        #expect(!session.snapshot.aiSchedule.active)
        await fake.setStatuses(["idle"])
        await task.value
        let after = await fake.commands.filter { Array($0.prefix(2)) == ["agent", "prompt"] }.count
        #expect(after == before)
        let scheduled = try #require(controller.conversation.questions.last)
        #expect(scheduled.request.trigger == .scheduled && scheduled.state != .submitted)
    }

    /// 【中】Aへの返答シートを開いている間、Bの自動送信まで抑制していた。
    @Test func 返答シートは自分の枠だけを抑制する() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try two(root)
        let session = session(root, profiles: list, fake: fake, recordedSamples: 16_000)
        session.setScheduleTranscriptForTesting("架空の会議です")
        // 手動の選択はBのまま、Aの返答シートを開く。
        session.selectAIProfile(slot: 2)
        session.beginAIDraft(slot: 1)
        try session.startAISchedule(options: try AIScheduleOptions(prompt: "議事録を更新して", interval: 0.01),
                                    helper: URL(fileURLWithPath: "/bin/echo"), profile: list[1])
        // Bの自動送信は止まらない。Aのシートを開いていても対象が違う。
        try await waitUntil("Bの自動送信が始まる") { session.aiRecord?.controller.conversation.questions.isEmpty == false }
        if let task = session.submissionTaskForTesting(slot: 2) { await task.value }
        let controller = try #require(session.aiRecord?.controller)
        let sent = try #require(controller.conversation.questions.first)
        #expect(sent.request.envelope.participant.profileSlot == 2)
        #expect(sent.request.trigger == .scheduled)
        session.endAIDraft()
    }

    /// 【中】宛名から補った長い名前が、設定は通るのに送信準備で落ちていた。
    /// 設定側と送信側で検証条件が食い違うと、複数プロファイルにした途端に送れなくなる。
    @Test func 宛名から補った長い名前でも送信できる() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let long = String(repeating: "あ", count: 22)
        #expect(long.utf8.count > AILimits.profileNameBytes)
        let list = try profiles(root, toml: """
        [[ai]]
        name = "議事録"
        command = "/bin/echo"
        cwd = "\(root.path)"

        [[ai]]
        command = "/bin/echo"
        cwd = "\(root.path)"
        address = "\(long)へ"
        """)
        #expect(list[1].name == long)
        let session = session(root, profiles: list, fake: fake)
        try await submit(session, profile: list[1])
        let request = try #require(session.aiRecord?.controller.conversation.questions.first?.request)
        #expect(request.envelope.participant.profile == long)
        #expect(request.envelope.participant.participantName == long)
        #expect(session.aiRecord?.controller.conversation.questions.first?.state == .submitted)
    }

    /// 【中】共通のherdrCommandを後続で省略できる。
    @Test func herdrCommandの省略は先頭を引き継ぐ() throws {
        let resolved = ResolvedConfig(config: try ConfigLoader.parse(toml: """
        [[ai]]
        name = "議事録"
        herdrCommand = "/opt/homebrew/bin/herdr"

        [[ai]]
        name = "相談"
        """), home: URL(fileURLWithPath: "/home/person")).aiProfiles
        #expect(resolved.map(\.herdrCommand) == ["/opt/homebrew/bin/herdr", "/opt/homebrew/bin/herdr"])
    }

    /// テストの穴として指摘された結合。アプリが書いた複数枠の保存物を実CLIが読めること。
    @Test func 複数枠の保存物を実CLIで返送しcontrollerが回収する() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeHerdr()
        let list = try two(root)
        // 収録済みの位置が無いと確定範囲が0行になり、受領基準の前進を見られない。
        let session = session(root, profiles: list, fake: fake, recordedSamples: 16_000)
        session.setScheduleTranscriptForTesting("架空の会議を始めます")
        try await submit(session, profile: list[0])
        try await submit(session, profile: list[1])
        let controller = try #require(session.aiRecord?.controller)
        let requests = controller.conversation.questions.map(\.request)
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.envelope.totalLineCount > 0 })

        for request in requests {
            let participant = request.envelope.participant
            // 枝を切った保存パスをそのまま実CLIへ渡す。
            #expect(participant.sessionPath.contains("/ai/sessions/\(participant.profileSlot!)/1.json"))
            let args = ["--session", participant.sessionPath, "--request", request.id.uuidString,
                        "--token", participant.requestToken]
            _ = try ReturnCommand(["accept"] + args).execute(input: { Data() }, environment: [:])
            _ = try ReturnCommand(["reply"] + args + ["--kind", "answered"])
                .execute(input: { Data("\(participant.participantName)からの回答".utf8) }, environment: [:])
        }
        // 返送の前は、どちらのstreamもまだ受領していないので差分ありのまま。
        let snapshot = session.snapshot
        let lines = TranscriptRenderer.lines(snapshot.utterances, names: snapshot.names, timeline: snapshot.timeline)
        #expect(!lines.isEmpty)
        #expect(controller.hasChanges(lines: lines, slot: 1) && controller.hasChanges(lines: lines, slot: 2))

        controller.scan()
        #expect(controller.invalidInboxFiles.isEmpty)
        let answered = controller.conversation.questions
        #expect(answered.allSatisfy { $0.state == .answered })
        #expect(answered.map { $0.result?.body } == ["迅雷からの回答", "ネオからの回答"])
        // 受領基準はそれぞれのstreamで進む。同じ本文なら次回は差分なしになる。
        #expect(answered[0].contextReceived && answered[1].contextReceived)
        #expect(!controller.hasChanges(lines: lines, slot: 1))
        #expect(!controller.hasChanges(lines: lines, slot: 2))
        // 本文が増えれば両方とも差分ありへ戻る。
        #expect(controller.hasChanges(lines: lines + ["[12:00:10] B: 追記"], slot: 1))
        #expect(controller.hasChanges(lines: lines + ["[12:00:10] B: 追記"], slot: 2))
    }
}
