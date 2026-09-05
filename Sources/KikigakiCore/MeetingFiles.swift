import Foundation

/// 保存先ディレクトリ内のファイル名。Markdown と録音WAVは同じ基底名で並べる
public enum MeetingFiles {
    /// `2026-09-05_1240` の形。日付順に並び、Obsidian などでノート名としてそのまま使える文字だけにする
    public static func baseName(startedAt: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd_HHmm"
        return f.string(from: startedAt)
    }

    public static func markdownURL(in directory: URL, startedAt: Date, timeZone: TimeZone = .current) -> URL {
        directory.appendingPathComponent(baseName(startedAt: startedAt, timeZone: timeZone) + ".md")
    }

    public static func recordingURL(in directory: URL, startedAt: Date, timeZone: TimeZone = .current) -> URL {
        directory.appendingPathComponent(baseName(startedAt: startedAt, timeZone: timeZone) + ".wav")
    }
}
