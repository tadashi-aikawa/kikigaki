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
            if [url, wavURL(for: url), levelsURL(for: url)].contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                suffix += 1
                continue
            }
            do {
                // 0600の空ファイルを排他的に公開し、本文は後で原子的に更新する。
                try PrivateFileIO.write(Data(), to: url, replacing: false)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                suffix += 1
            }
        }
    }

    public static func wavURL(for markdownURL: URL) -> URL {
        markdownURL.deletingPathExtension().appendingPathExtension("wav")
    }

    public static func levelsURL(for markdownURL: URL) -> URL {
        markdownURL.deletingPathExtension().appendingPathExtension("levels.json")
    }

    /// 手入力の添付画像の置き場 `<会議名>.attachments/`。
    public static func attachmentsDirectory(for markdownURL: URL) -> URL {
        markdownURL.deletingPathExtension().appendingPathExtension("attachments")
    }

    /// AIへ渡す `image_dirs`。その会議の画像の置き場の絶対パスを、手入力の添付・画面の記録の順に並べる。
    /// 「会話をコピー」と会議参加モードの手動送信・自動送信が同じ値を使う。仕様は docs/ai-handoff.md の「画像の参照」
    ///
    /// ディレクトリがまだ無い会議でも、存在を確かめずに両方を列挙する。
    /// - 理由: AIが読んでよいのは会話の行が参照する画像だけで、空のディレクトリを渡しても読めるものは増えない
    /// - 理由: 存在で省くと、送信の値を固めた直後に最初の1枚が保存された場合に、行は画像を指すのに置き場が渡らない。
    ///   自動送信の依頼は送信の時点で固定するので、後から足せない
    ///
    /// `standardizedFileURL` は通さない。`/private/tmp` の `/private` を、ファイルが在るときだけ外すので、
    /// 会議Markdownを書く前と後で値が変わり、回収したrequestとの完全一致の照合が崩れる。
    public static func imageDirectories(for markdownURL: URL) -> [String] {
        [attachmentsDirectory(for: markdownURL).path, ScreenCaptureFiles.directory(for: markdownURL).path]
    }

    /// `2026-09-05_1240` の形。日付順に並び、Obsidian などでノート名としてそのまま使える文字だけにする
    public static func baseName(startedAt: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd_HHmm"
        return f.string(from: startedAt)
    }
}
