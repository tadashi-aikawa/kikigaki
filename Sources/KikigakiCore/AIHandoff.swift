import Darwin
import Foundation

public struct HandoffCopy: Equatable, Sendable {
    public let lineCount: Int
    public let prompt: String
    public let fileURL: URL
    public let meetingID: UUID
    public let snapshotID: UUID
    public let sequence: Int
}

public enum HandoffError: LocalizedError {
    case saveFailed(String)
    case clipboardFailed

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let reason): return "AI用の会話ファイルを保存できませんでした: \(reason)"
        case .clipboardFailed: return "クリップボードにコピーできませんでした。もう一度お試しください。"
        }
    }
}

/// 会議ごとに作り直す。コピーは毎回会話の全体を渡し、成功した回だけ連番を進める。
/// 差分を渡さないのは、受け取るAIに前回の受領を覚えさせずに済ませるため。
public struct HandoffHistory {
    public private(set) var lastCopy: HandoffCopy?
    public let meetingID: UUID
    private let startedAt: Date

    public init(startedAt: Date = Date(), meetingID: UUID = UUID()) {
        self.startedAt = startedAt
        self.meetingID = meetingID
    }

    /// 議事録は本文を写さずパスだけ渡す。会話と違い、AIや人が書き換え続けるため。
    public mutating func copy(
        utterances: [Utterance], names: SpeakerNames, outputDirectory: URL,
        timeline: MeetingTimeline? = nil, minutesPath: String? = nil, writeClipboard: (String) -> Bool
    ) throws -> HandoffCopy? {
        let lines = TranscriptRenderer.lines(utterances, names: names, timeline: timeline ?? MeetingTimeline(startedAt: startedAt))
        guard !lines.isEmpty else { return nil }
        let snapshotID = UUID()
        let sequence = (lastCopy?.sequence ?? 0) + 1
        let root = outputDirectory.standardizedFileURL
        let url = root.appendingPathComponent(".kikigaki-context", isDirectory: true)
            .appendingPathComponent(meetingID.uuidString, isDirectory: true)
            .appendingPathComponent(snapshotID.uuidString + ".md")
        let metadata = Metadata(
            meetingID: meetingID.uuidString, snapshotID: snapshotID.uuidString, sequence: sequence,
            transcriptPath: url.path, readLineCount: lines.count, totalLineCount: lines.count,
            minutesPath: minutesPath)
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
        let result = HandoffCopy(lineCount: lines.count, prompt: prompt, fileURL: url,
                                 meetingID: meetingID, snapshotID: snapshotID, sequence: sequence)
        lastCopy = result
        return result
    }

    /// 会議参加モードと同じ範囲の形を保ち、Skillの読み方を共有する。手動コピーは常に全文。
    private struct Metadata: Encodable {
        let schemaVersion = 1
        let meetingID: String
        let snapshotID: String
        let sequence: Int
        let kind = "full"
        let transcriptPath: String
        let readStartLine = 1
        let readLineCount: Int
        let totalLineCount: Int
        let minutesPath: String?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case meetingID = "meeting_id"
            case snapshotID = "snapshot_id"
            case sequence
            case kind
            case transcriptPath = "transcript_path"
            case readStartLine = "read_start_line"
            case readLineCount = "read_line_count"
            case totalLineCount = "total_line_count"
            case minutesPath = "minutes_path"
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
