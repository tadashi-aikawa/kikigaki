import Foundation
import KikigakiCore

/// 予約ごとに排他公開する。返送用のsessionや設定ファイルには依存しない。
public struct NextMeetingStore: Sendable {
    public let directory: URL
    private let files: AIFileStore

    /// directoryはnext階層そのもの。テストは使い捨てのディレクトリを注入する。
    public init(directory: URL) {
        self.directory = directory
        files = AIFileStore(root: directory.deletingLastPathComponent(), allowsMissingParents: true)
    }
    /// helper自身のBundleは.appの識別子を持たないため、親.appのInfo.plistを読む。
    /// アプリと同じ試験版の分離を使い、本番の予約を試験版へ取り込まない。
    public static func supportDirectory(home: URL, bundleIdentifier: String?) -> URL {
        let name = bundleIdentifier == "com.tadashi-aikawa.kikigaki.trial" ? "KIKIGAKI-Trial" : "KIKIGAKI"
        return home.appendingPathComponent("Library/Application Support/\(name)")
    }
    public static func bundledIdentifier(executable: URL) -> String? {
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: app)?.bundleIdentifier
    }
    private func parts(_ id: UUID) -> [String] { [directory.lastPathComponent, id.uuidString + ".json"] }

    public func add(_ meeting: NextMeeting) throws {
        try meeting.validate()
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.write(AIJSON.encode(meeting), to: parts(meeting.id), replacing: false)
    }
    public func load() throws -> NextMeetings {
        let folder: URL
        do { folder = try files.directory([directory.lastPathComponent], create: false) }
        catch AIFileError.missing { return NextMeetings() }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        var meetings: [NextMeeting] = []
        for name in names where name.hasSuffix(".json") {
            // 1件の壊れたJSONで、ほかの予約まで選べなくしない。危険なファイルは読まない。
            guard let meeting = try? AIJSON.decode(NextMeeting.self, from: files.read([directory.lastPathComponent, name], limit: 32 * 1024)),
                  name == meeting.id.uuidString + ".json", (try? meeting.validate()) != nil else { continue }
            meetings.append(meeting)
        }
        return NextMeetings(meetings)
    }
    public func remove(_ id: UUID) throws { try files.remove(parts(id)) }
    @discardableResult public func expire(now: Date = Date()) throws -> NextMeetings {
        var meetings = try load()
        for meeting in meetings.expire(now: now) { try removeIfPresent(meeting.id) }
        return meetings
    }
    public func consume(id: UUID) throws {
        var meetings = try load()
        for meeting in meetings.consume(id: id) { try removeIfPresent(meeting.id) }
    }
    private func removeIfPresent(_ id: UUID) throws {
        do { try remove(id) } catch AIFileError.missing { /* 他の窓が先に消費した場合も成功。 */ }
    }
}
