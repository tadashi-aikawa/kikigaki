import Foundation

/// 省略前の本文は不変に保持し、改名時も原文から両方のMarkdownを生成する。
public struct MeetingArchive {
    public var original: MeetingMarkdown.Meeting
    public let markdownURL: URL
    private let processed: [Utterance]?
    private let candidateCount: Int
    private var ownsRawFile = false
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
    }

    public mutating func save() -> SaveResult {
        var displayed = original
        var warning: String?
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
                warning = "原文ファイルの保存に失敗。相槌の省略を中止: \(error.localizedDescription)"
            }
        }
        do {
            try MeetingMarkdown.render(displayed).write(to: markdownURL, atomically: true, encoding: .utf8)
            var message = "保存: \(markdownURL.path)"
            if processed != nil, !omissionDisabledAfterFailure {
                message += " / 相槌候補\(candidateCount)件を省略。原文: \(MeetingFiles.rawURL(for: markdownURL).path)"
            }
            if omissionDisabledAfterFailure, warning == nil { warning = "原文を保持。相槌の省略は適用していない" }
            if let warning { message = warning + " / " + message }
            return SaveResult(utterances: displayed.utterances, message: message, succeeded: true)
        } catch {
            var message = "保存に失敗: \(error.localizedDescription)"
            if let warning { message += " / " + warning }
            if processed != nil, warning == nil { message += " / 原文: \(MeetingFiles.rawURL(for: markdownURL).path)" }
            return SaveResult(utterances: displayed.utterances, message: message, succeeded: false)
        }
    }
}
