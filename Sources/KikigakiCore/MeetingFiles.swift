import Foundation

/// 保存先ディレクトリ内のファイル名。Markdown と録音WAVは同じ基底名で並べる
public enum MeetingFiles {
    /// 同じ分の録音や複数プロセスで既存会議を上書きしないよう、Markdown名を排他的に予約する。
    /// WAVだけ残った会議も使用済みとする。外部プログラムによる予約後のファイル操作は対象外。
    public static func reserveMarkdownURL(in directory: URL, startedAt: Date, timeZone: TimeZone = .current) throws -> URL {
        let base = baseName(startedAt: startedAt, timeZone: timeZone)
        var suffix = 1
        while true {
            let stem = base + (suffix == 1 ? "" : "_\(suffix)")
            let url = directory.appendingPathComponent(stem + ".md")
            if [url, rawURL(for: url), wavURL(for: url)].contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                suffix += 1
                continue
            }
            do {
                // .atomic と .withoutOverwriting は併用不可。空の予約だけを排他的に作り、本文は後で原子的に更新する。
                try Data().write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                suffix += 1
            }
        }
    }

    public static func rawURL(for markdownURL: URL) -> URL {
        markdownURL.deletingPathExtension().appendingPathExtension("raw.md")
    }

    public static func wavURL(for markdownURL: URL) -> URL {
        markdownURL.deletingPathExtension().appendingPathExtension("wav")
    }

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
