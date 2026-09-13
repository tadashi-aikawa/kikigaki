import Foundation

/// 受信箱の自己申告とフック観測から集めた、1依頼分の段の到達。
/// 進捗率ではないので、総数が分かっても消化件数は表さない。
public struct AIProgressReport: Equatable, Sendable {
    /// 編集の観測。AIの1回の自己申告を正、Claudeのフックの編集系ツール呼び出しを補助にする。
    public let isEditing: Bool
    /// 分かっている場合の編集箇所の総数。フック観測では出ない。
    public let editingTotal: Int?
    /// 返答を書き始めたというAIの1回の自己申告。フックでは観測しない。
    public let isReplying: Bool

    public init(isEditing: Bool = false, editingTotal: Int? = nil, isReplying: Bool = false) {
        self.isEditing = isEditing; self.editingTotal = editingTotal; self.isReplying = isReplying
    }

    public static func editing(total: Int? = nil) -> Self { Self(isEditing: true, editingTotal: total) }
    public static let replying = Self(isReplying: true)
}

/// 依頼ごとに確認できた段と、現在の補助表示。作業量や残り時間は表さない。
/// 保存する状態ではない。接続の観測が途切れても位置を残すため、呼び出し側が同じrequestの
/// 前回値を渡す。再読込では保存済みAIQuestionと受信箱の証拠だけから作り直す。
public struct AIProgress: Equatable, Sendable {
    public enum Stage: Int, CaseIterable, Sendable {
        case sending, reading, editing, reply

        public var title: String {
            switch self {
            case .sending: return "送信"
            case .reading: return "読込"
            case .editing: return "編集"
            case .reply: return "返答"
            }
        }
    }

    public enum Status: Equatable, Sendable {
        case preparing, awaitingAcceptance, awaitingReply, editing, replying, blocked, returnUnconfirmed
        case unknown, disconnected, deliveryUnknown, answered, needsInput, failed, cancelled
    }

    public let requestID: UUID
    /// 連続prefixではない。返答だけ先着した場合に未観測の読込・編集を塗らない。
    public let observedStages: Set<Stage>
    /// 最後に確認した最も先の位置。不明・切断・idleでは前回より戻さない。
    /// 何も観測していなければnilで、どの段も現在地にしない。
    public let currentStage: Stage?
    public let status: Status
    public let showsReplyProgress: Bool
    public let isHistorical: Bool
    public let sendAttemptedAt: Date?
    /// 返答到着の一瞬だけ全段を点灯させる表示用の派生。観測の記録ではない。
    public let isArrival: Bool
    /// 編集の総数。自己申告に添えられていた場合だけ入る。
    public let editingTotal: Int?

    public var isPaused: Bool { status == .blocked }
    public var isUnknown: Bool {
        status == .unknown || status == .disconnected || status == .deliveryUnknown
    }

    /// connectionはこのrequestの宛先slotの観測を渡す。世代が違えば不明として扱い、
    /// 新しい接続のworking/blockedを古い依頼へ付けない。完了フックは入力に取らない。
    /// reportはAIの自己申告とClaudeのフック観測。接続のworkingから推測しない。
    public init(question: AIQuestion, connection: AIConnectionStatus,
                connectionGeneration: Int?, isUnconfirmed: Bool = false,
                report: AIProgressReport? = nil,
                previous: AIProgress? = nil, isHistorical: Bool = false) {
        requestID = question.request.id
        self.isHistorical = isHistorical
        sendAttemptedAt = question.sendAttemptedAt
        isArrival = false
        var observed: Set<Stage> = []
        var total = report?.editingTotal
        if !isHistorical, let previous, previous.requestID == requestID, !previous.isHistorical {
            observed.formUnion(previous.observedStages)
            total = total ?? previous.editingTotal
        }
        // sendAttemptedAtは送信試行の証拠で、送信成功の証拠ではない。
        // accept・resultの到着は配達の直接の証拠。読込・編集はそこから推測しない。
        if question.state == .submitted || question.acceptance != nil || question.result != nil {
            observed.insert(.sending)
        }
        if question.acceptance != nil { observed.insert(.reading) }
        // 送信していない依頼の申告は成立しない。準備中・起動失敗を申告で塗らない。
        if question.sendAttemptedAt != nil {
            if report?.isEditing == true { observed.insert(.editing) }
            // 返答の申告は返答の段だけを塗る。編集を経ていなければ編集は塗らない。
            if report?.isReplying == true { observed.insert(.reply) }
        }
        editingTotal = observed.contains(.editing) ? total : nil

        let waiting = question.isAwaitingResult && question.state != .deliveryUnknown
        showsReplyProgress = waiting
        let sameGeneration = connectionGeneration == question.request.envelope.participant.sessionGeneration
        let connection: AIConnectionStatus = sameGeneration ? connection : .unknown
        // 編集・返答は観測できた事実なので、接続がidle・workingのどちらでも現在の位置として扱う。
        // 返答の申告の後に編集の申告が届いても、位置は返答のまま戻さない。
        let working: Status = observed.contains(.reply) ? .replying
            : observed.contains(.editing) ? .editing
            : question.acceptance == nil ? .awaitingAcceptance : .awaitingReply
        let next: Status
        // 取消後にも結果が到着する。保存状態がcancelledのままでも、本文・失敗表示を優先する。
        if let result = question.result {
            switch result.kind {
            case .answered: observed.insert(.reply); next = .answered
            case .needsInput: observed.insert(.reply); next = .needsInput
            case .failed: next = .failed
            case .accept:
                assertionFailure("AIQuestion.result must not contain accept")
                next = .awaitingAcceptance
            }
        } else if question.state == .cancelled {
            next = .cancelled
        } else if question.state == .failed {
            next = .failed
        } else if question.state == .prepared {
            next = .preparing
        } else if question.state == .deliveryUnknown {
            next = .deliveryUnknown
        } else if isHistorical {
            // 過去会議は現在の接続・前回の表示メモリを混ぜない。保存されていない作業は復元しない。
            next = working
        } else {
            switch connection {
            case .blocked: next = .blocked
            case .unknown: next = .unknown
            case .disconnected: next = .disconnected
            case .idle where isUnconfirmed: next = .returnUnconfirmed
            default: next = working
            }
        }
        observedStages = observed
        currentStage = observed.max(by: { $0.rawValue < $1.rawValue })
        status = next
    }

    private init(arrivalOf source: AIProgress) {
        requestID = source.requestID
        observedStages = Set(Stage.allCases)
        currentStage = nil
        status = source.status
        showsReplyProgress = true
        isHistorical = source.isHistorical
        sendAttemptedAt = source.sendAttemptedAt
        isArrival = true
        editingTotal = source.editingTotal
    }

    /// 返答が届いた行に、本文へ入れ替える前の全段点灯を出すための派生。
    /// 過去会議の読込と、結果以外の状態では作らない。
    public func arrival() -> AIProgress? {
        guard !isHistorical, status == .answered || status == .needsInput else { return nil }
        return AIProgress(arrivalOf: self)
    }

    public var message: String {
        // preparing・deliveryUnknown・cancelled・failedは行を作らない、または失敗行を使うため、
        // ここで返す文言は進行表示として画面には出ない。状態の分類としてケースを残す。
        let received = observedStages.contains(.reading)
        let prefix = received ? "読込 → " : "送信済み · "
        switch status {
        case .preparing: return "送信準備中"
        case .awaitingAcceptance: return "送信済み · AIが読込中"
        case .awaitingReply: return "読込済み · 作業中"
        case .editing: return editingTotal.map { "編集中(全\($0)か所)" } ?? "編集中"
        // 返答を書いている最中は、終わった編集の総数を出さない。
        case .replying: return "返答を作成中"
        case .blocked: return "‖ " + prefix + "ペインで確認待ち"
        case .returnUnconfirmed: return prefix + "返送未確認"
        case .unknown: return "? " + prefix + "状況を確認できません"
        case .disconnected: return "? " + prefix + "接続が切れています"
        case .deliveryUnknown: return "? 送達不明"
        case .answered: return "返答到着"
        case .needsInput: return "確認質問が到着"
        case .failed: return "失敗"
        case .cancelled: return "取消"
        }
    }

    /// 送信試行からの経過であり、作業開始からの時間ではない。時計の巻き戻りは0秒へ丸める。
    public func elapsedSeconds(at now: Date) -> Int? {
        guard showsReplyProgress, !isHistorical, !isArrival, let sent = sendAttemptedAt else { return nil }
        let interval = now.timeIntervalSince(sent)
        guard interval.isFinite, interval < Double(Int.max) else { return nil }
        return Int(max(0, interval))
    }

    public func text(at now: Date) -> String {
        guard let seconds = elapsedSeconds(at: now) else { return message }
        let tail = seconds % 60
        return message + " · \(seconds / 60):\(tail < 10 ? "0" : "")\(tail)経過"
    }

    /// タイマー自体はUIが管理する。表示中かつ動きを減らさない未完了の返事行だけ1秒更新する。
    public func updatesElapsedTime(isDisplayed: Bool, reduceMotion: Bool) -> Bool {
        showsReplyProgress && !isHistorical && !isArrival && sendAttemptedAt != nil && isDisplayed && !reduceMotion
    }
}
