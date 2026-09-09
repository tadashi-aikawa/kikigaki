import Foundation

/// 開始時に固定する設定。秒単位の注入はreplayでも同じ状態機械を使うため。
public struct AIScheduleOptions: Equatable, Sendable {
    public let prompt: String
    public let interval: TimeInterval
    public let workAllowed: Bool
    public let sendFinal: Bool

    public init(prompt: String, interval: TimeInterval = 180, workAllowed: Bool = true, sendFinal: Bool = true) throws {
        try AIValidation.text(prompt, limit: AILimits.questionBytes, nonempty: true)
        guard interval.isFinite, interval > 0 else { throw AIError.invalid("schedule interval") }
        self.prompt = prompt; self.interval = interval; self.workAllowed = workAllowed; self.sendFinal = sendFinal
    }

    public static func minuteChoices(including configured: Int) -> [Int] {
        Array(Set([1, 2, 3, 5, 10] + ((1...60).contains(configured) ? [configured] : []))).sorted()
    }
}

/// 接続不可と返事待ちを区別する。working中・手動編集中・準備中はbusy。
public enum AIScheduleAvailability: Equatable, Sendable {
    case ready, awaitingResult, busy, confirmation, disconnected
}

public struct AIScheduleState: Sendable {
    public enum Phase: Equatable, Sendable { case stopped, running, awaitingSave, awaitingFinal }
    public enum Skip: Equatable, Sendable { case unavailable, noChange, saveFailed, disconnected }
    public enum Effect: Equatable, Sendable { case none, send(final: Bool), skipped(Skip), stoppedAfterFailures }
    public enum Outcome: Equatable, Sendable { case failed, deliveryUnknown, answered, needsInput }

    public let meetingID: UUID
    public private(set) var runID: UUID?
    public private(set) var options: AIScheduleOptions?
    public private(set) var phase: Phase = .stopped
    public private(set) var nextFire: Date?
    public private(set) var consecutiveFailures = 0
    private var requests: [UUID] = []
    private var outcomes: [UUID: Outcome] = [:]

    public init(meetingID: UUID) { self.meetingID = meetingID }

    public mutating func start(options: AIScheduleOptions, now: Date, runID: UUID) throws {
        guard phase == .stopped, now.timeIntervalSince1970.isFinite,
              now.addingTimeInterval(options.interval).timeIntervalSince1970.isFinite else {
            throw AIError.invalid("schedule start")
        }
        self.options = options; self.runID = runID
        phase = .running; nextFire = now.addingTimeInterval(options.interval)
        requests = []; outcomes = [:]; consecutiveFailures = 0
    }

    /// 新会議は新しい値を作る。終了・利用者の停止は待機中の最終回も破棄する。
    public mutating func stop() { phase = .stopped; nextFire = nil }

    /// 開始・利用者の即時実行。変更なしでも操作時点から1間隔待つ。
    public mutating func fireNow(now: Date, availability: AIScheduleAvailability, hasChanges: Bool) -> Effect {
        guard phase == .running, let options, now.timeIntervalSince1970.isFinite,
              now.addingTimeInterval(options.interval).timeIntervalSince1970.isFinite else { return .none }
        guard availability == .ready else { return .skipped(.unavailable) }
        nextFire = now.addingTimeInterval(options.interval)
        guard hasChanges else { return .skipped(.noChange) }
        return .send(final: false)
    }

    /// 接続待ちを周期に含めず、実際のCLI入力試行から次の期限を数える。
    /// 登録前・別会議・前回実行の後着通知では期限を変えない。最終回は期限なし。
    public mutating func didBeginSending(requestID: UUID, meetingID: UUID, runID: UUID, at now: Date) {
        guard phase == .running, self.meetingID == meetingID, self.runID == runID,
              requests.contains(requestID), let options, now.timeIntervalSince1970.isFinite,
              now.addingTimeInterval(options.interval).timeIntervalSince1970.isFinite else { return }
        nextFire = now.addingTimeInterval(options.interval)
    }

    public mutating func tick(now: Date, availability: AIScheduleAvailability, hasChanges: Bool) -> Effect {
        guard phase == .running, let deadline = nextFire, let options,
              now.timeIntervalSince1970.isFinite, now >= deadline else { return .none }
        // 過去の期限を1件ずつ消化しない。浮動小数の除算が極端な値になる場合も連打しない。
        let elapsed = now.timeIntervalSince(deadline)
        let remainder = elapsed.truncatingRemainder(dividingBy: options.interval)
        let next = now.addingTimeInterval(options.interval - remainder)
        nextFire = next > now ? next : now.addingTimeInterval(max(0.001, options.interval))
        guard availability == .ready else { return .skipped(.unavailable) }
        return hasChanges ? .send(final: false) : .skipped(.noChange)
    }

    public mutating func recordingStopped() {
        guard phase == .running else { return }
        nextFire = nil
        phase = options?.sendFinal == true ? .awaitingSave : .stopped
    }

    public mutating func finalSaveCompleted(succeeded: Bool) -> Effect {
        guard phase == .awaitingSave else { return .none }
        phase = succeeded ? .awaitingFinal : .stopped
        return succeeded ? .none : .skipped(.saveFailed)
    }

    /// 返事と接続状態の更新時に再評価する。期限なし。sendを返す前に権利を消費する。
    /// 最終回はneeds_input到着後も締めを送る。通常tickだけがconfirmationでスキップする。
    public mutating func finalDecision(availability: AIScheduleAvailability, hasChanges: Bool) -> Effect {
        guard phase == .awaitingFinal else { return .none }
        switch availability {
        case .awaitingResult, .busy: return .none
        case .disconnected:
            stop(); return .skipped(.disconnected)
        case .ready, .confirmation:
            stop()
            return hasChanges ? .send(final: true) : .skipped(.noChange)
        }
    }

    /// 自動実行が発行したrequestだけを登録する。手動・旧会議・前回実行は数えない。
    public mutating func register(requestID: UUID, meetingID: UUID, runID: UUID) {
        guard self.meetingID == meetingID, self.runID == runID, !requests.contains(requestID) else { return }
        requests.append(requestID)
    }

    /// send終了後の送達不明と確定resultだけを渡す。beginSending中の暫定状態は入力しない。
    /// 後着resultは送達不明を置き換え、同じrequestを二度数えない。
    public mutating func observe(requestID: UUID, meetingID: UUID, runID: UUID, outcome: Outcome) -> Effect {
        guard self.meetingID == meetingID, self.runID == runID, requests.contains(requestID) else { return .none }
        if let previous = outcomes[requestID] {
            guard previous == .deliveryUnknown, outcome != .deliveryUnknown else { return .none }
        }
        outcomes[requestID] = outcome
        consecutiveFailures = 0
        for id in requests.reversed() {
            guard let result = outcomes[id] else { continue }
            if result == .answered || result == .needsInput { break }
            consecutiveFailures += 1
        }
        if consecutiveFailures >= 3, phase != .stopped {
            stop(); return .stoppedAfterFailures
        }
        return .none
    }
}
