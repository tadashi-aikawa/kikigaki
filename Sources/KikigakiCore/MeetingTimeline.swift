import Foundation

/// 音声上の位置を壁時計へ変換する。一時停止の境界は表示側ではなく収録側で記録する。
public struct MeetingTimeline: Equatable, Sendable {
    public struct Pause: Codable, Equatable, Sendable {
        public let audioTime: Double
        public let duration: TimeInterval

        public init(audioTime: Double, duration: TimeInterval) {
            self.audioTime = audioTime
            self.duration = duration
        }
    }

    public let startedAt: Date
    public var pauses: [Pause]

    public init(startedAt: Date, pauses: [Pause] = []) {
        self.startedAt = startedAt
        self.pauses = pauses
    }

    /// 境界ちょうどの位置は再開後。停止直前までの発言の開始位置には影響しない。
    public func date(at audioTime: Double) -> Date {
        let position = max(0, audioTime)
        let delay = pauses.filter { $0.audioTime <= position }.reduce(0) { $0 + $1.duration }
        return startedAt.addingTimeInterval(position + delay)
    }

    public func clock(at audioTime: Double, seconds: Bool = false, timeZone: TimeZone = .current) -> String {
        ClockFormatters.shared.string(from: date(at: audioTime), seconds: seconds, timeZone: timeZone)
    }
}

/// 辞書の生成と整形を同じロックで保護し、並行する保存と表示でも共有できる。
final class ClockFormatters: @unchecked Sendable {
    static let shared = ClockFormatters()
    private struct Key: Hashable { let seconds: Bool; let timeZone: TimeZone }
    private let lock = NSLock()
    private var formatters: [Key: DateFormatter] = [:]

    func string(from date: Date, seconds: Bool, timeZone: TimeZone) -> String {
        lock.withLock {
            let key = Key(seconds: seconds, timeZone: timeZone)
            let formatter: DateFormatter
            if let cached = formatters[key] {
                formatter = cached
            } else {
                formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = timeZone
                formatter.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
                formatters[key] = formatter
            }
            return formatter.string(from: date)
        }
    }
}

/// 収録時の受け入れ位置と一時停止を同じ状態で扱う。呼び出し側で音声スレッドとの排他を行う。
/// 消費タスクが遅れていても境界は収録済みサンプル数から決まる。replayの速度には依存しない。
public struct RecordedAudioClock: Sendable {
    public private(set) var timeline: MeetingTimeline
    public private(set) var acceptedSamples = 0
    private var pausedAt: Date?
    public var isPaused: Bool { pausedAt != nil }

    public init(startedAt: Date) { timeline = MeetingTimeline(startedAt: startedAt) }

    @discardableResult
    public mutating func accept(sampleCount: Int) -> Bool {
        guard !isPaused else { return false }
        acceptedSamples += sampleCount
        return true
    }

    public mutating func pause(at date: Date) {
        if pausedAt == nil { pausedAt = date }
    }

    public mutating func resume(at date: Date) {
        guard let pausedAt else { return }
        timeline.pauses.append(.init(audioTime: Double(acceptedSamples) / 16000,
                                     duration: max(0, date.timeIntervalSince(pausedAt))))
        self.pausedAt = nil
    }
}
