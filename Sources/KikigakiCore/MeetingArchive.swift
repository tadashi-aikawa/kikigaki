import Foundation

/// 省略前の本文は不変に保持し、改名時も原文から両方のMarkdownを生成する。
public struct MeetingArchive: Codable {
    public var original: MeetingMarkdown.Meeting
    public let markdownURL: URL
    private var processed: [Utterance]?
    private var candidateCount: Int
    private var ownsRawFile = false
    /// optionalで旧archiveの欠損を読む。
    private var ownsLevelsFile: Bool?
    private var omissionDisabledAfterFailure = false

    public init(original: MeetingMarkdown.Meeting, processed: [Utterance]?, candidateCount: Int, markdownURL: URL) {
        self.original = original
        self.processed = processed
        self.candidateCount = candidateCount
        self.markdownURL = markdownURL
    }

    public struct SaveResult {
        public var utterances: [Utterance]
        public var message: String
        public var succeeded: Bool
        public var rawSucceeded: Bool = true
        public var levelsSucceeded: Bool = true
        public init(utterances: [Utterance], message: String, succeeded: Bool, rawSucceeded: Bool = true, levelsSucceeded: Bool = true) {
            self.utterances = utterances; self.message = message; self.succeeded = succeeded; self.rawSucceeded = rawSucceeded
            self.levelsSucceeded = levelsSucceeded
        }
    }

    /// 統合訂正は原トークンから再計算した結果を入れる。raw所有権と省略失敗状態は維持する。
    public mutating func replaceResult(_ result: MeetingResult) {
        let typed = original.utterances.filter { $0.kind == .typed }
        original.utterances = TranscriptEntries.merge(voice: result.utterances, typed: typed, timeline: original.timeline).utterances
        processed = result.processed.map { TranscriptEntries.merge(voice: $0, typed: typed, timeline: original.timeline).utterances }
        candidateCount = result.candidates.count
    }

    public mutating func save() -> SaveResult {
        var displayed = original
        var warning: String?
        var rawSucceeded = true
        var levelsSucceeded = true
        var levelsWarning: String?
        if let track = original.audioLevels {
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
        if let processed {
            let rawURL = MeetingFiles.rawURL(for: markdownURL)
            do {
                if !ownsRawFile {
                    try Data().write(to: rawURL, options: .withoutOverwriting)
                    ownsRawFile = true
                }
                try MeetingMarkdown.render(original).write(to: rawURL, atomically: true, encoding: .utf8)
                if !omissionDisabledAfterFailure { displayed.utterances = processed }
            } catch {
                // 原文が保存できないときに文字を省かない。この会議では改名後も原文表示を続ける。
                omissionDisabledAfterFailure = true
                rawSucceeded = false
                warning = "原文ファイルの保存に失敗。相槌の省略を中止: \(error.localizedDescription)"
            }
        }
        do {
            try MeetingMarkdown.render(displayed).write(to: markdownURL, atomically: true, encoding: .utf8)
            var message = "保存: \(markdownURL.path)"
            if processed != nil, candidateCount > 0, !omissionDisabledAfterFailure {
                message += " / 相槌候補\(candidateCount)件を省略(原文は .raw.md)"
            }
            if omissionDisabledAfterFailure, warning == nil { warning = "原文を保持。相槌の省略は適用していない" }
            if let warning { message = warning + " / " + message }
            if let levelsWarning { message = levelsWarning + " / " + message }
            return SaveResult(utterances: displayed.utterances, message: message, succeeded: true, rawSucceeded: rawSucceeded, levelsSucceeded: levelsSucceeded)
        } catch {
            var message = "保存に失敗: \(error.localizedDescription)"
            if let warning { message += " / " + warning }
            if let levelsWarning { message += " / " + levelsWarning }
            if processed != nil, warning == nil { message += " / 原文: \(MeetingFiles.rawURL(for: markdownURL).path)" }
            return SaveResult(utterances: displayed.utterances, message: message, succeeded: false, rawSucceeded: rawSucceeded, levelsSucceeded: levelsSucceeded)
        }
    }
}
