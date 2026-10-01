import Foundation

/// 会議の本文と設定を保持し、改名・再判定・AIの更新でMarkdownを生成し直す。
public struct MeetingArchive: Codable {
    /// 旧archiveとの保存形式の互換のためoriginalというキーを維持する。
    /// 旧processedは読み飛ばし、相槌を省略する前の発話列を使う。
    public var original: MeetingMarkdown.Meeting
    public let markdownURL: URL
    /// optionalで旧archiveの欠損を読む。
    private var ownsLevelsFile: Bool?

    public init(original: MeetingMarkdown.Meeting, markdownURL: URL) {
        self.original = original
        self.markdownURL = markdownURL
    }

    public struct SaveResult {
        public var utterances: [Utterance]
        public var message: String
        public var succeeded: Bool
        public var levelsSucceeded: Bool = true
        public init(utterances: [Utterance], message: String, succeeded: Bool, levelsSucceeded: Bool = true) {
            self.utterances = utterances; self.message = message; self.succeeded = succeeded
            self.levelsSucceeded = levelsSucceeded
        }
    }

    /// 統合訂正は原トークンから再計算した結果を入れる。手入力は保持する。
    public mutating func replaceResult(_ result: MeetingResult) {
        let typed = original.utterances.filter { $0.kind == .typed }
        original.utterances = TranscriptEntries.merge(voice: result.utterances, typed: typed, timeline: original.timeline).utterances
    }

    public mutating func save() -> SaveResult {
        var levelsSucceeded = true
        var levelsWarning: String?
        if original.displaysAudioLevels, let track = original.audioLevels {
            do {
                let url = MeetingFiles.levelsURL(for: markdownURL)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(AudioLevelReport(meeting: original, track: track))
                if ownsLevelsFile != true {
                    do {
                        // 完全な内容を同一ディレクトリへ書いてから排他的なhard linkで公開する。
                        // 初回書き込みが途中で落ちても、正式名には不完全な内容を残さない。
                        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
                        defer { try? FileManager.default.removeItem(at: temporary) }
                        try data.write(to: temporary, options: .withoutOverwriting)
                        try FileManager.default.linkItem(at: temporary, to: url)
                    }
                    catch let error as CocoaError where error.code == .fileWriteFileExists {
                        // archiveを先に永続化し、計測を書いた直後に落ちた場合の復旧。
                        // 同一内容の通常ファイルだけを引き継ぐ。別内容・リンク・FIFOは上書きしない。
                        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == data.count,
                              try Data(contentsOf: url) == data else { throw error }
                    }
                    ownsLevelsFile = true
                } else { try data.write(to: url, options: .atomic) }
            } catch {
                levelsSucceeded = false
                levelsWarning = "音量記録の保存に失敗: \(error.localizedDescription)"
            }
        }
        do {
            try MeetingMarkdown.render(original).write(to: markdownURL, atomically: true, encoding: .utf8)
            var message = "保存: \(markdownURL.path)"
            if let levelsWarning { message = levelsWarning + " / " + message }
            return SaveResult(utterances: original.utterances, message: message, succeeded: true, levelsSucceeded: levelsSucceeded)
        } catch {
            var message = "保存に失敗: \(error.localizedDescription)"
            if let levelsWarning { message += " / " + levelsWarning }
            return SaveResult(utterances: original.utterances, message: message, succeeded: false, levelsSucceeded: levelsSucceeded)
        }
    }
}
