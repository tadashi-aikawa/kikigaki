import Foundation
import KikigakiCore
import KikigakiAIIO

struct NextCommand {
    enum Failure: Error { case arguments, invalidPath, invalidAt, missing }
    static let usage = "kikigaki-cli next add --minutes <path> [--title <題>] [--at <HH:mm|YYYY-MM-DDTHH:mm>] [--ai <name>] [--manual <name>] | next list | next remove <id>"
    enum Action { case add, list, remove(UUID) }
    let action: Action
    private let values: [String: String]

    init(_ arguments: [String]) throws {
        guard arguments.first == "next", arguments.count >= 2 else { throw Failure.arguments }
        switch arguments[1] {
        case "list":
            guard arguments.count == 2 else { throw Failure.arguments }
            action = .list; values = [:]
        case "remove":
            guard arguments.count == 3, let id = UUID(uuidString: arguments[2]) else { throw Failure.arguments }
            action = .remove(id); values = [:]
        case "add":
            var options: [String: String] = [:]
            var index = 2
            while index < arguments.count {
                let key = arguments[index]
                guard ["--minutes", "--title", "--at", "--ai", "--manual"].contains(key),
                      options[key] == nil, index + 1 < arguments.count else { throw Failure.arguments }
                options[key] = arguments[index + 1]; index += 2
            }
            guard options["--minutes"] != nil else { throw Failure.arguments }
            action = .add; values = options
        default: throw Failure.arguments
        }
    }

    /// 店と現在時刻を注入し、試験から本番のApplication Supportへ書かせない。
    func execute(store: NextMeetingStore, now: Date = Date(), timeZone: TimeZone = .current) throws -> [String] {
        switch action {
        case .add:
            let raw = values["--minutes"]!.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = raw.hasPrefix("~/") ? (raw as NSString).expandingTildeInPath : raw
            do { try MinutesPath.validate(path) } catch { throw Failure.invalidPath }
            let at: String?
            do { at = try values["--at"].map { try NextMeeting.resolveAt($0, now: now, timeZone: timeZone) } }
            catch { throw Failure.invalidAt }
            let meeting = try NextMeeting(minutesPath: path, title: values["--title"], at: at,
                                          ai: values["--ai"], manual: values["--manual"], createdAt: now)
            try store.add(meeting)
            return [meeting.id.uuidString]
        case .list:
            return try store.load().meetings.map { meeting in
                [meeting.id.uuidString, meeting.at ?? "-", meeting.title ?? "-", meeting.ai ?? "-", meeting.minutesPath, meeting.manual ?? "-"].joined(separator: "\t")
            }
        case let .remove(id):
            do { try store.remove(id) } catch AIFileError.missing { throw Failure.missing }
            return []
        }
    }
}
