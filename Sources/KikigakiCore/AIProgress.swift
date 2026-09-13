import Foundation

/// 依頼ごとに確認できた段と、現在の補助表示。作業量や残り時間は表さない。
/// 保存する状態ではない。接続の観測が途切れても位置を残すため、呼び出し側が同じrequestの
/// 前回値を渡す。再読込では保存済みAIQuestionの証拠だけから作り直す。
public struct AIProgress: Equatable, Sendable {
    public enum Stage: Int, CaseIterable, Sendable {
        case preparation, sending, acceptance, working, reply

        public var title: String {
            switch self {
            case .preparation: return "準備"
            case .sending: return "送信"
            case .acceptance: return "受領"
            case .working: return "作業"
            case .reply: return "返答"
            }
        }
    }

    public enum Status: Equatable, Sendable {
        case preparing, awaitingAcceptance, awaitingReply, working, blocked, returnUnconfirmed
        case unknown, disconnected, deliveryUnknown, answered, needsInput, failed, cancelled
    }

    public let requestID: UUID
    /// 連続prefixではない。返答だけ先着した場合に未観測の受領・作業を塗らない。
    public let observedStages: Set<Stage>
    /// 最後に確認した最も先の位置。不明・切断・idleでは前回より戻さない。
    public let currentStage: Stage
    public let status: Status
    public let showsReplyProgress: Bool
    public let isHistorical: Bool
    public let sendAttemptedAt: Date?

    public var isPaused: Bool { status == .blocked }
    public var isUnknown: Bool {
        status == .unknown || status == .disconnected || status == .deliveryUnknown
    }

    /// connectionはこのrequestの宛先slotの観測を渡す。世代が違えば不明として扱い、
    /// 新しい接続のworking/blockedを古い依頼へ付けない。完了フックは入力に取らない。
    public init(question: AIQuestion, connection: AIConnectionStatus,
                connectionGeneration: Int?, isUnconfirmed: Bool = false,
                previous: AIProgress? = nil, isHistorical: Bool = false) {
        requestID = question.request.id
        self.isHistorical = isHistorical
        sendAttemptedAt = question.sendAttemptedAt
        var observed: Set<Stage> = [.preparation]
        if !isHistorical, let previous, previous.requestID == requestID, !previous.isHistorical {
            observed.formUnion(previous.observedStages)
        }
        // sendAttemptedAtは送信試行の証拠で、送信成功の証拠ではない。
        // accept・resultの到着は配達の直接の証拠。作業開始はそこから推測しない。
        if question.state == .submitted || question.acceptance != nil || question.result != nil {
            observed.insert(.sending)
        }
        if question.acceptance != nil { observed.insert(.acceptance) }

        let waiting = question.isAwaitingResult && question.state != .deliveryUnknown
        showsReplyProgress = waiting
        let sameGeneration = connectionGeneration == question.request.envelope.participant.sessionGeneration
        let connection: AIConnectionStatus = sameGeneration ? connection : .unknown
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
            next = question.acceptance == nil ? .awaitingAcceptance : .awaitingReply
        } else {
            switch connection {
            case .blocked:
                if question.acceptance != nil { observed.insert(.working) }
                next = .blocked
            case .working where question.acceptance != nil:
                observed.insert(.working)
                next = .working
            case .unknown: next = .unknown
            case .disconnected: next = .disconnected
            case .idle where isUnconfirmed: next = .returnUnconfirmed
            default: next = question.acceptance == nil ? .awaitingAcceptance : .awaitingReply
            }
        }
        observedStages = observed
        currentStage = observed.max(by: { $0.rawValue < $1.rawValue }) ?? .preparation
        status = next
    }

    public var message: String {
        // preparing・deliveryUnknown・cancelled・failedは行を作らない、または失敗行を使うため、
        // ここで返す文言は進行表示として画面には出ない。状態の分類としてケースを残す。
        let received = observedStages.contains(.acceptance)
        let prefix = received ? "受領 → " : "送信済み · "
        switch status {
        case .preparing: return "送信準備中"
        case .awaitingAcceptance: return "送信済み · 受領待ち"
        case .awaitingReply: return "受領済み · 返答待ち"
        case .working: return "受領 → AIが作業中"
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
        guard showsReplyProgress, !isHistorical, let sent = sendAttemptedAt else { return nil }
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
        showsReplyProgress && !isHistorical && sendAttemptedAt != nil && isDisplayed && !reduceMotion
    }
}
