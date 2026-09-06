import Foundation

/// 省略前の本文は不変に保持し、改名時も原文から両方のMarkdownを生成する。
public struct MeetingArchive: Codable {
    public var original: MeetingMarkdown.Meeting
    public let markdownURL: URL
    private var processed: [Utterance]?
    private var candidateCount: Int
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
        public var rawSucceeded: Bool = true
        public init(utterances: [Utterance], message: String, succeeded: Bool, rawSucceeded: Bool = true) {
            self.utterances = utterances; self.message = message; self.succeeded = succeeded; self.rawSucceeded = rawSucceeded
        }
    }

    /// 統合訂正は原トークンから再計算した結果を入れる。raw所有権と省略失敗状態は維持する。
    public mutating func replaceResult(_ result: MeetingResult) {
        original.utterances = result.utterances
        processed = result.processed
        candidateCount = result.candidates.count
    }

    public mutating func save() -> SaveResult {
        var displayed = original
        var warning: String?
        var rawSucceeded = true
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
            return SaveResult(utterances: displayed.utterances, message: message, succeeded: true, rawSucceeded: rawSucceeded)
        } catch {
            var message = "保存に失敗: \(error.localizedDescription)"
            if let warning { message += " / " + warning }
            if processed != nil, warning == nil { message += " / 原文: \(MeetingFiles.rawURL(for: markdownURL).path)" }
            return SaveResult(utterances: displayed.utterances, message: message, succeeded: false)
        }
    }
}
