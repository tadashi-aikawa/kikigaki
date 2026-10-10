import Foundation

/// 次の会議へ渡す指定。設定の正本は読まず、宛先名の照合は開始シートに任せる。
public struct NextMeeting: Codable, Equatable, Sendable {
    public let id: UUID
    public let minutesPath: String
    public let title: String?
    /// タイムゾーンを付けないローカル日時。登録時の「今日」を保存し、翌日に読み替えない。
    public let at: String?
    public let ai: String?
    public let createdAt: Date

    public init(id: UUID = UUID(), minutesPath: String, title: String? = nil, at: String? = nil,
                ai: String? = nil, createdAt: Date = Date()) throws {
        self.id = id; self.minutesPath = minutesPath; self.title = title
        self.at = at; self.ai = ai; self.createdAt = createdAt
        try validate()
    }

    public func validate() throws {
        try MinutesPath.validate(minutesPath)
        guard createdAt.timeIntervalSince1970.isFinite else { throw AIError.invalid("next date") }
        for value in [title, ai].compactMap({ $0 }) {
            guard !value.trimmingCharacters(in: .whitespaces).isEmpty,
                  value.utf8.count <= 4096,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw AIError.invalid("next text")
            }
        }
        if let at {
            guard at.count == 16, try Self.resolveAt(at, timeZone: TimeZone(secondsFromGMT: 0)!) == at else { throw AIError.invalid("next at") }
        }
    }

    /// 厳密な2形式だけを受ける。日付の繰り上げや秒の暗黙補完は予約の取り違えになる。
    public static func resolveAt(_ input: String, now: Date = Date(), timeZone: TimeZone = .current) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone; formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let value: String
        if input.range(of: "^[0-9]{2}:[0-9]{2}$", options: .regularExpression) != nil {
            value = String(formatter.string(from: now).prefix(10)) + "T" + input
        } else { value = input }
        guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}$", options: .regularExpression) != nil,
              let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw AIError.invalid("next at")
        }
        return value
    }

    enum CodingKeys: String, CodingKey {
        case id, title, at, ai, minutesPath = "minutes_path", createdAt = "created_at"
    }
    /// 登録順の精度をISOのミリ秒へ丸めない。連続登録した候補の順序も再読込で保つ。
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(minutesPath, forKey: .minutesPath)
        try values.encodeIfPresent(title, forKey: .title)
        try values.encodeIfPresent(at, forKey: .at)
        try values.encodeIfPresent(ai, forKey: .ai)
        try values.encode(createdAt.timeIntervalSince1970, forKey: .createdAt)
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id),
                      minutesPath: values.decode(String.self, forKey: .minutesPath),
                      title: values.decodeIfPresent(String.self, forKey: .title),
                      at: values.decodeIfPresent(String.self, forKey: .at),
                      ai: values.decodeIfPresent(String.self, forKey: .ai),
                      createdAt: Date(timeIntervalSince1970: values.decode(Double.self, forKey: .createdAt)))
    }
}

/// 並び・寿命・消費はI/Oと切り離し、表示上限を削除の範囲へ混ぜない。
public struct NextMeetings: Equatable, Sendable {
    public static let limit = 3
    public static let lifetime: TimeInterval = 24 * 60 * 60
    public private(set) var meetings: [NextMeeting]

    public init(_ meetings: [NextMeeting] = []) {
        self.meetings = meetings.enumerated().sorted { lhs, rhs in
            if lhs.element.at != rhs.element.at {
                switch (lhs.element.at, rhs.element.at) {
                case let (a?, b?): return a < b
                case (_?, nil): return true
                default: return false
                }
            }
            if lhs.element.createdAt != rhs.element.createdAt { return lhs.element.createdAt < rhs.element.createdAt }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
    public var candidates: [NextMeeting] { Array(meetings.prefix(Self.limit)) }

    @discardableResult public mutating func expire(now: Date) -> [NextMeeting] {
        let removed = meetings.filter { now.timeIntervalSince($0.createdAt) >= Self.lifetime }
        meetings.removeAll { now.timeIntervalSince($0.createdAt) >= Self.lifetime }
        return removed
    }
    /// symlinkや実在は同一性へ混ぜない。手で欄を編集した場合も最終的なパスで消費する。
    @discardableResult public mutating func consume(minutesPath: String) -> [NextMeeting] {
        let removed = meetings.filter { $0.minutesPath == minutesPath }
        meetings.removeAll { $0.minutesPath == minutesPath }
        return removed
    }
}
