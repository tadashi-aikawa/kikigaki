import Foundation
import Testing
import KikigakiCore

struct NextMeetingsTests {
    private func meeting(_ number: Int, at: String? = nil, created: TimeInterval = 0, path: String? = nil) throws -> NextMeeting {
        try NextMeeting(minutesPath: path ?? "/会議/\(number).md", at: at, createdAt: Date(timeIntervalSince1970: created))
    }
    @Test func 時刻順の後に登録順で並び先頭三件だけを表示する() throws {
        let first = try meeting(1, created: 1), second = try meeting(2, created: 2)
        let later = try meeting(3, at: "2026-10-10T17:30", created: 3)
        let earlier = try meeting(4, at: "2026-10-10T09:00", created: 4)
        let meetings = NextMeetings([second, later, first, earlier])
        #expect(meetings.meetings == [earlier, later, first, second])
        #expect(meetings.candidates == [earlier, later, first])
        #expect(NextMeetings().candidates.isEmpty)
        #expect(NextMeetings([first]).candidates == [first])
    }
    @Test func 同時刻は登録順で同じ登録時刻なら入力順を保つ() throws {
        let a = try meeting(1, at: "2026-10-10T12:00", created: 1)
        let b = try meeting(2, at: "2026-10-10T12:00", created: 2)
        let c = try meeting(3, at: "2026-10-10T12:00", created: 2)
        #expect(NextMeetings([c, b, a]).meetings == [a, c, b])
    }
    @Test func 登録から二十四時間で失効し予定時刻と未来の登録は寿命を変えない() throws {
        let old = try meeting(1, at: "2027-01-01T00:00")
        let recent = try meeting(2, created: 1), future = try meeting(3, created: 100_000)
        var meetings = NextMeetings([recent, old, future])
        #expect(meetings.expire(now: Date(timeIntervalSince1970: 86_399.999)).isEmpty)
        #expect(meetings.expire(now: Date(timeIntervalSince1970: 86_400)) == [old])
        #expect(meetings.meetings == [recent, future])
    }
    @Test func 消費は表示上限の外もidで判定し同じパスの別予約を残す() throws {
        let entries = try (1...4).map { try meeting($0, created: Double($0)) }
        let duplicate = try meeting(5, path: "/会議/4.md")
        var meetings = NextMeetings(entries + [duplicate])
        #expect(meetings.consume(id: UUID()).isEmpty)
        #expect(meetings.consume(id: entries[3].id) == [entries[3]])
        #expect(meetings.meetings == NextMeetings(Array(entries.prefix(3)) + [duplicate]).meetings)
        #expect(meetings.consume(id: entries[3].id).isEmpty)
    }
    @Test func 時分は今日で日付付きはそのまま解釈する() throws {
        let now = Date(timeIntervalSince1970: 0)
        let japan = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let west = try #require(TimeZone(secondsFromGMT: -8 * 3600))
        #expect(try NextMeeting.resolveAt("08:05", now: now, timeZone: japan) == "1970-01-01T08:05")
        #expect(try NextMeeting.resolveAt("08:05", now: now, timeZone: west) == "1969-12-31T08:05")
        #expect(try NextMeeting.resolveAt("2028-02-29T23:59", now: now, timeZone: japan) == "2028-02-29T23:59")
    }
    @Test(arguments: ["9:00", "09:0", "24:00", "12:60", "2026-02-29T12:00", "2026-10-10 12:00", "2026-10-10T12:00Z", "2026-10-10T12:00:00", "", " 12:00", "2026-13-01T00:00"])
    func 読めない日時は拒否する(_ value: String) {
        #expect(throws: (any Error).self) { try NextMeeting.resolveAt(value) }
    }
    @Test func JSONはローカル日時と登録時刻の精度を保ち不正な値を復元しない() throws {
        let original = try NextMeeting(minutesPath: "/会議/定例.md", title: "定例", at: "2026-10-10T12:00",
                                       ai: "未設定の宛先", manual: "スライド", createdAt: Date(timeIntervalSince1970: 1000.000125))
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(NextMeeting.self, from: data) == original)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["at"] as? String == "2026-10-10T12:00")
        #expect(json["minutes_path"] as? String == "/会議/定例.md")
        #expect(json["manual"] as? String == "スライド")
        var old = json; old.removeValue(forKey: "manual")
        #expect(try JSONDecoder().decode(NextMeeting.self, from: JSONSerialization.data(withJSONObject: old)).manual == nil)
        var invalidManual = json; invalidManual["manual"] = "\n"
        #expect(throws: (any Error).self) { try JSONDecoder().decode(NextMeeting.self, from: JSONSerialization.data(withJSONObject: invalidManual)) }
        var bad = json; bad["minutes_path"] = "relative.md"
        #expect(throws: (any Error).self) { try JSONDecoder().decode(NextMeeting.self, from: JSONSerialization.data(withJSONObject: bad)) }
    }
}
