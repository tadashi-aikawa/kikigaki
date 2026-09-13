import Foundation
import Testing
import KikigakiCore

@Suite struct AIProgressTests {
    private let sent = Date(timeIntervalSince1970: 100)
    private static let connections: [AIConnectionStatus] = [.idle, .working, .blocked, .unknown, .disconnected]
    private static let states: [AIQuestionState] = [
        .prepared, .submitted, .accepted, .answered, .needsInput, .failed, .deliveryUnknown, .cancelled,
    ]

    private func question(_ state: AIQuestionState = .prepared, slot: Int = 1, generation: Int = 1) throws -> AIQuestion {
        let root = URL(fileURLWithPath: "/tmp/ai-progress-tests")
        var history = try AIStreamHistory(meetingID: UUID(), sessionGeneration: generation)
        let snapshot = try history.prepare(lines: ["[00:00:01] 話者A: 確認してください"], outputDirectory: root)
        let participant = AIParticipantContext(streamID: snapshot.streamID, requestID: UUID(), sessionGeneration: generation,
            participantName: "迅雷", cliPath: "/tmp/helper",
            sessionPath: root.appendingPathComponent(".kikigaki-context/\(snapshot.meetingID)/"
                + AIEnvelope.sessionPath(slot: slot, generation: generation)).path,
            requestToken: "test", question: "確認してください", capturedAt: sent.addingTimeInterval(-10),
            audioCutoffSeconds: 2, profile: "宛先\(slot)", profileSlot: slot)
        var value = try AIQuestion(request: AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: participant),
                                                     number: 1, snapshot: snapshot))
        if state == .prepared { return value }
        if state == .failed { try value.failBeforeSending("起動失敗"); return value }
        try value.beginSending(at: sent)
        if state == .deliveryUnknown { return value }
        try value.submitted()
        switch state {
        case .accepted: try receive(.accept, into: &value)
        case .answered: try receive(.answered, into: &value)
        case .needsInput: try receive(.needsInput, into: &value)
        case .cancelled: try value.cancel(at: sent.addingTimeInterval(1))
        default: break
        }
        return value
    }

    private func receive(_ kind: AIReceiveEvent.Kind, into question: inout AIQuestion) throws {
        let date = sent.addingTimeInterval(2)
        let reason: String? = kind == .needsInput ? "clarification" : kind == .failed ? "work_failed" : nil
        try question.receive(AIReceiveEvent(request: question.request, kind: kind, recordedAt: date,
                                           body: kind == .accept ? nil : "返事の本文", reason: reason), at: date, order: 1)
    }

    private func progress(_ question: AIQuestion, _ connection: AIConnectionStatus = .idle,
                          unconfirmed: Bool = false, editing: AIEditingReport? = nil,
                          previous: AIProgress? = nil) -> AIProgress {
        AIProgress(question: question, connection: connection, connectionGeneration: 1,
                   isUnconfirmed: unconfirmed, editing: editing, previous: previous)
    }

    @Test func 送信から読込編集返答まで確認した段だけを保持する() throws {
        var value = try question()
        var current = progress(value)
        #expect(current.observedStages.isEmpty && current.currentStage == nil)
        #expect(current.status == .preparing && !current.showsReplyProgress)
        try value.beginSending(at: sent)
        current = progress(value, previous: current)
        #expect(current.status == .deliveryUnknown && current.isUnknown && !current.showsReplyProgress)
        try value.submitted()
        current = progress(value, previous: current)
        #expect(current.observedStages == [.sending])
        #expect(current.text(at: sent.addingTimeInterval(42)) == "送信済み · AIが読込中 · 0:42経過")
        try receive(.accept, into: &value)
        current = progress(value, previous: current)
        #expect(current.observedStages == [.sending, .reading] && current.currentStage == .reading)
        #expect(current.message == "読込済み · 作業中")
        // workingだけでは編集へ進めない。現在段は読込に留める。
        current = progress(value, .working, previous: current)
        #expect(current.currentStage == .reading && current.message == "読込済み · 作業中")
        current = progress(value, .working, editing: AIEditingReport(total: 7), previous: current)
        #expect(current.observedStages == [.sending, .reading, .editing])
        #expect(current.text(at: sent.addingTimeInterval(80)) == "編集中(全7か所) · 1:20経過")
        try receive(.answered, into: &value)
        current = progress(value, .working, unconfirmed: true, previous: current)
        #expect(current.observedStages == Set(AIProgress.Stage.allCases))
        #expect(current.currentStage == .reply && current.status == .answered)
        #expect(!current.showsReplyProgress && !current.isUnknown && !current.isPaused)
        #expect(current.elapsedSeconds(at: sent.addingTimeInterval(90)) == nil)
    }

    @Test func 総数のない編集は箇所を書かず一度知った総数は保つ() throws {
        let value = try question(.accepted)
        let plain = progress(value, editing: AIEditingReport())
        #expect(plain.message == "編集中" && plain.currentStage == .editing)
        let counted = progress(value, editing: AIEditingReport(total: 1), previous: plain)
        #expect(counted.message == "編集中(全1か所)")
        // 観測が途切れても前回の位置と総数は残す。塗り直しで段が戻らない。
        let lost = progress(value, .unknown, previous: counted)
        #expect(lost.currentStage == .editing && lost.message == "? 読込 → 状況を確認できません")
        let again = progress(value, previous: lost)
        #expect(again.message == "編集中(全1か所)")
    }

    @Test func acceptを経ない編集と返答は読込を塗らない() throws {
        var value = try question(.submitted)
        let editing = progress(value, editing: AIEditingReport(total: 2))
        #expect(editing.observedStages == [.sending, .editing])
        #expect(editing.currentStage == .editing && editing.message == "編集中(全2か所)")
        try receive(.answered, into: &value)
        let answered = progress(value, previous: editing)
        #expect(answered.observedStages == [.sending, .editing, .reply])
        #expect(!answered.observedStages.contains(.reading))
    }

    @Test(arguments: connections) func 読込なしの返答は途中を済みに塗らない(_ connection: AIConnectionStatus) throws {
        var value = try question(.deliveryUnknown)
        let before = progress(value)
        try receive(.answered, into: &value)
        let result = progress(value, connection, unconfirmed: true, previous: before)
        #expect(result.observedStages == [.sending, .reply])
        #expect(result.status == .answered && !result.showsReplyProgress)
        try receive(.accept, into: &value)
        let late = progress(value, connection, previous: result)
        #expect(late.observedStages == [.sending, .reading, .reply])
        #expect(late.currentStage == .reply && late.status == .answered)
        #expect(!late.observedStages.contains(.editing))
    }

    @Test func workingだけで読込や編集を推測しない() throws {
        let result = progress(try question(.submitted), .working)
        #expect(result.observedStages == [.sending])
        #expect(result.status == .awaitingAcceptance)
        #expect(result.message == "送信済み · AIが読込中")
    }

    @Test func 読込前のblockedは送信位置を保ち編集を塗らない() throws {
        let result = progress(try question(.submitted), .blocked)
        #expect(result.observedStages == [.sending])
        #expect(result.currentStage == .sending && result.isPaused && !result.isUnknown)
        #expect(result.message == "‖ 送信済み · ペインで確認待ち")
    }

    @Test func 確認待ちから再開とidleを経ても位置を巻き戻さない() throws {
        let value = try question(.accepted)
        let editing = progress(value, .working, editing: AIEditingReport())
        let blocked = progress(value, .blocked, previous: editing)
        #expect(blocked.text(at: sent.addingTimeInterval(80)) == "‖ 読込 → ペインで確認待ち · 1:20経過")
        #expect(blocked.currentStage == .editing)
        let resumed = progress(value, .working, editing: AIEditingReport(), previous: blocked)
        #expect(!resumed.isPaused && resumed.status == .editing)
        let idle = progress(value, .idle, previous: resumed)
        #expect(idle.currentStage == .editing && idle.message == "編集中")
        #expect(!idle.observedStages.contains(.reply))
    }

    @Test(arguments: [AIConnectionStatus.unknown, .disconnected])
    func 観測不能は最後の位置を残し復帰で疑問符だけを消す(_ connection: AIConnectionStatus) throws {
        let value = try question(.accepted)
        let editing = progress(value, .working, editing: AIEditingReport())
        let unknown = progress(value, connection, unconfirmed: true, previous: editing)
        #expect(unknown.observedStages == editing.observedStages)
        #expect(unknown.currentStage == .editing && unknown.isUnknown && !unknown.isPaused)
        #expect(unknown.message == (connection == .unknown ? "? 読込 → 状況を確認できません" : "? 読込 → 接続が切れています"))
        let restored = progress(value, .working, editing: AIEditingReport(), previous: unknown)
        #expect(restored.observedStages == editing.observedStages)
        #expect(!restored.isUnknown && restored.status == .editing)
    }

    @Test func 返送未確認は既存判定を受け取り完了とみなさない() throws {
        let value = try question(.accepted)
        let editing = progress(value, .working, editing: AIEditingReport())
        for seconds in [4.99, 5.0] {
            let now = sent.addingTimeInterval(seconds)
            let flag = AIReturnStatus.isUnconfirmed(question: value, connection: .idle, idleSince: sent,
                                                    now: now, hasRunningBackgroundTasks: false)
            let result = progress(value, .idle, unconfirmed: flag, previous: editing)
            #expect(result.status == (seconds < 5 ? .editing : .returnUnconfirmed))
            #expect(result.currentStage == .editing && !result.observedStages.contains(.reply))
        }
        let now = sent.addingTimeInterval(130)
        let flag = AIReturnStatus.isUnconfirmed(question: value, connection: .idle, idleSince: sent,
                                                now: now, hasRunningBackgroundTasks: true)
        #expect(!flag)
        #expect(progress(value, unconfirmed: flag).status == .awaitingReply)
        #expect(progress(value, unconfirmed: true).text(at: now) == "読込 → 返送未確認 · 2:10経過")
        #expect(progress(value, .working, unconfirmed: true).status == .awaitingReply)
        #expect(progress(value, .blocked, unconfirmed: true).status == .blocked)
    }

    @Test func 未読込のidle警告も読込済みとは書かない() throws {
        let value = try question(.submitted)
        #expect(progress(value, unconfirmed: true).message == "送信済み · 返送未確認")
        #expect(progress(value, .unknown).message == "? 送信済み · 状況を確認できません")
        #expect(progress(value, .disconnected).message == "? 送信済み · 接続が切れています")
    }

    @Test(arguments: [AIReceiveEvent.Kind.answered, .needsInput, .failed])
    func 取消後の結果を接続観測より優先する(_ kind: AIReceiveEvent.Kind) throws {
        var value = try question(.accepted)
        let editing = progress(value, .working, editing: AIEditingReport())
        try value.cancel(at: sent.addingTimeInterval(1))
        let cancelled = progress(value, .blocked, previous: editing)
        #expect(cancelled.status == .cancelled && !cancelled.showsReplyProgress && !cancelled.isPaused)
        #expect(cancelled.observedStages == editing.observedStages)
        try receive(kind, into: &value)
        #expect(value.state == .cancelled)
        let arrived = progress(value, .disconnected, unconfirmed: true, previous: cancelled)
        #expect(arrived.status == (kind == .answered ? .answered : kind == .needsInput ? .needsInput : .failed))
        #expect(!arrived.showsReplyProgress && !arrived.isUnknown)
        #expect(arrived.observedStages.contains(.reply) == (kind != .failed))
    }

    @Test func 送信前失敗と未送信取消は接続が動いていても進めない() throws {
        let failed = progress(try question(.failed), .working)
        #expect(failed.status == .failed && failed.observedStages.isEmpty)
        var value = try question()
        try value.cancel(at: sent)
        let cancelled = progress(value, .blocked)
        #expect(cancelled.status == .cancelled && cancelled.observedStages.isEmpty)
        #expect(cancelled.elapsedSeconds(at: sent) == nil)
    }

    @Test func 送達不明とpreparedには既存どおり返事行を作らない() throws {
        for state: AIQuestionState in [.prepared, .deliveryUnknown] {
            let value = try question(state)
            let result = progress(value, .working)
            #expect(!result.showsReplyProgress)
            #expect(result.observedStages.isEmpty)
            #expect(result.elapsedSeconds(at: sent.addingTimeInterval(42)) == nil)
            var conversation = AIConversation(meetingID: value.request.envelope.meetingID)
            try conversation.append(value.request)
            if state == .deliveryUnknown { try conversation.update(value.request.id) { try $0.beginSending(at: sent) } }
            let items = AITimeline.items(conversation: conversation, utterances: [], timeline: MeetingTimeline(startedAt: sent))
            #expect(items.count == 1 && items[0].isSend)
            #expect(items[0].notes.contains(state == .prepared ? "送信準備中" : "送達不明"))
        }
    }

    @Test func 別requestと別宛先の前回値を混ぜない() throws {
        let first = try question(.accepted, slot: 1)
        let previous = progress(first, .working, editing: AIEditingReport(total: 3))
        for slot in [1, 2, 3] {
            let next = try question(.submitted, slot: slot)
            let result = progress(next, .unknown, previous: previous)
            #expect(result.requestID == next.request.id)
            #expect(result.observedStages == [.sending] && result.editingTotal == nil)
            #expect(result.currentStage == .sending && result.isUnknown)
        }
    }

    @Test(arguments: [AIConnectionStatus.working, .blocked, .idle])
    func 別世代の接続で古いrequestを進めない(_ connection: AIConnectionStatus) throws {
        let value = try question(.accepted)
        let old = progress(value, .working, editing: AIEditingReport())
        let result = AIProgress(question: value, connection: connection, connectionGeneration: 2,
                                isUnconfirmed: true, previous: old)
        #expect(result.observedStages == old.observedStages)
        #expect(result.currentStage == .editing && result.status == .unknown && !result.isPaused)
        let fresh = AIProgress(question: value, connection: .working, connectionGeneration: nil)
        #expect(fresh.status == .unknown && fresh.currentStage == .reading)
    }

    @Test(arguments: connections) func 過去会議は保存状態と受信箱だけを静止表示する(_ connection: AIConnectionStatus) throws {
        let value = try question(.accepted)
        let live = progress(value, .working, editing: AIEditingReport(total: 4))
        let historical = AIProgress(question: value, connection: connection, connectionGeneration: 1,
                                    isUnconfirmed: true, previous: live, isHistorical: true)
        #expect(historical.observedStages == [.sending, .reading])
        #expect(historical.status == .awaitingReply && historical.currentStage == .reading)
        #expect(historical.showsReplyProgress && !historical.isUnknown)
        #expect(historical.text(at: sent.addingTimeInterval(9999)) == "読込済み · 作業中")
        #expect(!historical.updatesElapsedTime(isDisplayed: true, reduceMotion: false))
        // 受信箱に残る自己申告は、過去会議でも同じ位置と総数で再現する。
        let replayed = AIProgress(question: value, connection: connection, connectionGeneration: 1,
                                  editing: AIEditingReport(total: 4), isHistorical: true)
        #expect(replayed.currentStage == .editing && replayed.message == "編集中(全4か所)")
    }

    @Test func 返答到着の点灯は全段を塗り経過も現在段も出さない() throws {
        var value = try question(.accepted)
        let editing = progress(value, .working, editing: AIEditingReport(total: 2))
        #expect(editing.arrival() == nil)
        try receive(.needsInput, into: &value)
        let arrived = progress(value, .working, previous: editing)
        let flash = try #require(arrived.arrival())
        #expect(flash.observedStages == Set(AIProgress.Stage.allCases) && flash.currentStage == nil)
        #expect(flash.showsReplyProgress && flash.status == .needsInput)
        #expect(flash.text(at: sent.addingTimeInterval(300)) == "確認質問が到着")
        #expect(!flash.updatesElapsedTime(isDisplayed: true, reduceMotion: false))
        var answered = try question(.answered)
        #expect(try #require(progress(answered).arrival()).message == "返答到着")
        try receive(.accept, into: &answered)
        // 過去会議の読込では点灯しない。静止のまま本文を出す。
        let historical = AIProgress(question: answered, connection: .unknown, connectionGeneration: nil, isHistorical: true)
        #expect(historical.arrival() == nil)
        let failed = try question(.failed)
        #expect(progress(failed).arrival() == nil)
    }

    @Test func 経過時間は送信試行から計算し異常値を表示しない() throws {
        let result = progress(try question(.submitted))
        #expect(result.text(at: sent) == "送信済み · AIが読込中 · 0:00経過")
        #expect(result.text(at: sent.addingTimeInterval(59.99)) == "送信済み · AIが読込中 · 0:59経過")
        #expect(result.text(at: sent.addingTimeInterval(60)) == "送信済み · AIが読込中 · 1:00経過")
        #expect(result.text(at: sent.addingTimeInterval(3600)) == "送信済み · AIが読込中 · 60:00経過")
        #expect(result.elapsedSeconds(at: sent.addingTimeInterval(-1000)) == 0)
        for interval in [Double.nan, Double.infinity, -Double.infinity, Double(Int.max)] {
            #expect(result.elapsedSeconds(at: sent.addingTimeInterval(interval)) == nil)
        }
    }

    @Test(arguments: [true, false], [true, false])
    func 表示中で動きを減らさない場合だけ経過を更新する(displayed: Bool, reduceMotion: Bool) throws {
        for state in Self.states {
            let result = progress(try question(state))
            let waiting = state == .submitted || state == .accepted
            #expect(result.updatesElapsedTime(isDisplayed: displayed, reduceMotion: reduceMotion)
                    == (waiting && displayed && !reduceMotion))
        }
    }

    @Test(arguments: states, connections) func 保存状態と接続の全組合せで表示契約を守る(
        state: AIQuestionState, connection: AIConnectionStatus
    ) throws {
        let value = try question(state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(value)
        let result = progress(value, connection, unconfirmed: true, editing: AIEditingReport(total: 9))
        #expect(result.showsReplyProgress == (state == .submitted || state == .accepted))
        #expect(result.observedStages.contains(.reading) == (value.acceptance != nil))
        #expect(result.observedStages.contains(.reply) == (state == .answered || state == .needsInput))
        for word in ["承認待ち", "返送中", "回答できた", "受領"] { #expect(!result.message.contains(word)) }
        #expect(try encoder.encode(value) == before)
    }

    @Test func 過去会議の前回値はライブの観測履歴へ混ぜない() throws {
        var value = try question(.submitted)
        let submitted = value
        try receive(.answered, into: &value)
        let historical = AIProgress(question: value, connection: .unknown, connectionGeneration: nil, isHistorical: true)
        let live = progress(submitted, .idle, previous: historical)
        #expect(live.observedStages == [.sending])
        #expect(live.status == .awaitingAcceptance && live.currentStage == .sending)
    }
}
