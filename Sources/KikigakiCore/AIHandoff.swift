import Darwin
import Foundation

public struct HandoffPreview: Equatable, Sendable {
    public let startLine: Int
    public let lineCount: Int
    public let totalLineCount: Int
    public let startTime: Double
    public let includesCorrections: Bool
    public let isFull: Bool
}

public struct HandoffCopy: Equatable, Sendable {
    public let preview: HandoffPreview
    public let prompt: String
    public let fileURL: URL
    public let meetingID: UUID
    public let snapshotID: UUID
    public let sequence: Int
}

public enum HandoffError: LocalizedError {
    case saveFailed(String)
    case clipboardFailed
    case snapshotUnavailable

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let reason): return "AI用の会話ファイルを保存できませんでした: \(reason)"
        case .clipboardFailed: return "クリップボードにコピーできませんでした。もう一度お試しください。"
        case .snapshotUnavailable: return "前回コピーした会話ファイルを読み取れません。会議の最初からコピーしてください。"
        }
    }
}

/// 会議ごとに作り直す。ファイルとクリップボードの両方が成功した時だけ基準を進める。
public struct HandoffHistory {
    public private(set) var lastCopy: HandoffCopy?
    private let meetingID = UUID()
    private var previousLines: [String] = []
    private var previousStarts: [Double] = []

    public init() {}

    public func preview(utterances: [Utterance], names: SpeakerNames, full: Bool = false) -> HandoffPreview? {
        preview(lines: TranscriptRenderer.lines(utterances, names: names), starts: utterances.map(\.start), full: full)
    }

    private func preview(lines: [String], starts: [Double], full: Bool) -> HandoffPreview? {
        guard lastCopy != nil || !lines.isEmpty else { return nil }
        let isFull = full || lastCopy == nil
        var common = 0
        while common < min(lines.count, previousLines.count), lines[common] == previousLines[common] {
            common += 1
        }
        guard isFull || lines != previousLines else { return nil }
        let start = isFull ? 0 : common
        // 削除だけの更新には今回の開始行がないため、削除された旧行の時刻を使う。
        let time = starts.indices.contains(start) ? starts[start]
            : (previousStarts.indices.contains(start) ? previousStarts[start] : 0)
        return HandoffPreview(startLine: start + 1, lineCount: lines.count - start,
                              totalLineCount: lines.count, startTime: time,
                              includesCorrections: lastCopy != nil && common < previousLines.count,
                              isFull: isFull)
    }

    public mutating func copy(
        utterances: [Utterance], names: SpeakerNames, outputDirectory: URL,
        full: Bool = false, writeClipboard: (String) -> Bool
    ) throws -> HandoffCopy? {
        let lines = TranscriptRenderer.lines(utterances, names: names)
        let starts = utterances.map(\.start)
        guard let preview = preview(lines: lines, starts: starts, full: full) else { return nil }
        let snapshotID = UUID()
        let sequence = (lastCopy?.sequence ?? 0) + 1
        let root = outputDirectory.standardizedFileURL
        let url = root.appendingPathComponent(".kikigaki-context", isDirectory: true)
            .appendingPathComponent(meetingID.uuidString, isDirectory: true)
            .appendingPathComponent(snapshotID.uuidString + ".md")
        let metadata = Metadata(
            meetingID: meetingID.uuidString, snapshotID: snapshotID.uuidString, sequence: sequence,
            previousSnapshotID: preview.isFull ? nil : lastCopy?.snapshotID.uuidString,
            kind: preview.isFull ? "full" : "update", transcriptPath: url.path,
            readStartLine: preview.startLine, readLineCount: preview.lineCount, totalLineCount: lines.count)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(metadata), as: UTF8.self)
            .replacingOccurrences(of: "`", with: "\\u0060")
        let prompt = "$kikigaki\n\nKIKIGAKI_CONTEXT\n```json\n\(json)\n```"
        do {
            try Self.save(lines: lines, root: root, meeting: meetingID.uuidString, filename: url.lastPathComponent)
        } catch {
            throw HandoffError.saveFailed(error.localizedDescription)
        }
        guard writeClipboard(prompt) else { throw HandoffError.clipboardFailed }
        let result = HandoffCopy(preview: preview, prompt: prompt, fileURL: url,
                                 meetingID: meetingID, snapshotID: snapshotID, sequence: sequence)
        previousLines = lines
        previousStarts = starts
        lastCopy = result
        return result
    }

    public func recopy(writeClipboard: (String) -> Bool) throws -> HandoffCopy? {
        guard let lastCopy else { return nil }
        // ファイル種別と読み取り可能性を確認する。存在するだけのディレクトリは受け付けない。
        let root = lastCopy.fileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { throw HandoffError.snapshotUnavailable }
        defer { close(rootFD) }
        let contextFD = openat(rootFD, ".kikigaki-context", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard contextFD >= 0 else { throw HandoffError.snapshotUnavailable }
        defer { close(contextFD) }
        let meetingFD = openat(contextFD, lastCopy.meetingID.uuidString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard meetingFD >= 0 else { throw HandoffError.snapshotUnavailable }
        defer { close(meetingFD) }
        let fd = openat(meetingFD, lastCopy.fileURL.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw HandoffError.snapshotUnavailable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw HandoffError.snapshotUnavailable
        }
        guard writeClipboard(lastCopy.prompt) else { throw HandoffError.clipboardFailed }
        return lastCopy
    }

    private struct Metadata: Encodable {
        let schemaVersion = 1
        let meetingID: String
        let snapshotID: String
        let sequence: Int
        let previousSnapshotID: String?
        let kind: String
        let transcriptPath: String
        let readStartLine: Int
        let readLineCount: Int
        let totalLineCount: Int

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case meetingID = "meeting_id"
            case snapshotID = "snapshot_id"
            case sequence
            case previousSnapshotID = "previous_snapshot_id"
            case kind
            case transcriptPath = "transcript_path"
            case readStartLine = "read_start_line"
            case readLineCount = "read_line_count"
            case totalLineCount = "total_line_count"
        }
    }

    /// 専用ディレクトリをfdで辿り、シンボリックリンク経由の保存・権限変更を避ける。
    /// O_EXCLで新規作成したfdへ直接書き、既存のスナップショットは上書きしない。
    private static func save(lines: [String], root: URL, meeting: String, filename: String) throws {
        guard root.isFileURL else { throw HandoffError.saveFailed("保存先がローカルファイルではありません") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { throw posixError() }
        defer { close(rootFD) }
        let contextFD = try privateDirectory(".kikigaki-context", parent: rootFD)
        defer { close(contextFD) }
        let meetingFD = try privateDirectory(meeting, parent: contextFD)
        defer { close(meetingFD) }
        let fd = openat(meetingFD, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw posixError() }
        var needsClose = true
        defer { if needsClose { close(fd) } }
        guard fchmod(fd, mode_t(0o600)) == 0 else { throw posixError() }
        let data = Data((lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n").utf8)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw posixError() }
        needsClose = false
        guard close(fd) == 0 else { throw posixError() }
    }

    private static func privateDirectory(_ name: String, parent: Int32) throws -> Int32 {
        if mkdirat(parent, name, mode_t(0o700)) != 0, errno != EEXIST { throw posixError() }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        guard fchmod(fd, mode_t(0o700)) == 0 else {
            let error = posixError()
            close(fd)
            throw error
        }
        return fd
    }

    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
