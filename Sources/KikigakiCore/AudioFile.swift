import Foundation

/// 音声ファイルの書き起こしで、会議の音源にしたファイル。仕様は docs/audio-file.md
public struct AudioFile: Equatable, Sendable {
    public let url: URL
    /// 音声の長さ(秒)
    public let duration: Double
    /// 会議の開始時刻にする録音日時
    public let recordedAt: Date

    public init(url: URL, duration: Double, recordedAt: Date) {
        self.url = url
        self.duration = duration
        self.recordedAt = recordedAt
    }

    public var name: String { url.lastPathComponent }

    /// 録音日時。メタデータの作成日時を優先し、無ければファイルの作成日時を使う。
    /// どちらも書き出しの時刻のことがあるが、推測で補正しない。
    public static func recordedAt(metadata: Date?, fileCreation: Date?, fallback: Date) -> Date {
        metadata ?? fileCreation ?? fallback
    }

    /// 開始シートの1行。「32:15 · 10/20 10:00 録音」
    public func summary(timeZone: TimeZone = .current) -> String {
        TranscriptRenderer.elapsed(duration) + " · " + Self.date(recordedAt, format: "M/d HH:mm", timeZone: timeZone) + " 録音"
    }

    /// 書き起こし中の状態の数字。「12:30 / 32:15」
    public func progress(at elapsed: Double) -> String {
        TranscriptRenderer.elapsed(min(elapsed, duration)) + " / " + TranscriptRenderer.elapsed(duration)
    }

    /// 時刻帯の先頭に添える日付。録音の会議と違い、当日とは限らないため。「10/20 」
    public static func datePrefix(_ startedAt: Date, timeZone: TimeZone = .current) -> String {
        date(startedAt, format: "M/d", timeZone: timeZone) + " "
    }

    private static func date(_ value: Date, format: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: value)
    }
}
