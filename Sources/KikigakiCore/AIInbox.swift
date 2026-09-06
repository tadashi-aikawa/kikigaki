import Darwin
import Foundation

/// 指定した保存先だけを基点にする読み取り値型。作成・監視・設定探索はしない。
public struct AIInbox: Sendable {
    public let outputDirectory: URL
    public let ownerID: UInt32
    public init(outputDirectory: URL, ownerID: UInt32 = getuid()) {
        self.outputDirectory = outputDirectory; self.ownerID = ownerID
    }

    /// fdで専用の階層を辿る。リンク・FIFO・ディレクトリ・過大ファイルを読む前に拒否する。
    public func read(filename: String, for request: AIRequest) throws -> AIReceiveEvent {
        try request.validate()
        try request.envelope.validatePaths(outputDirectory: outputDirectory)
        guard outputDirectory.isFileURL,
              ["\(request.id.uuidString).accept.json", "\(request.id.uuidString).result.json"].contains(filename) else {
            throw AIError.unsafeFile
        }
        let root = open(outputDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw AIError.unsafeFile }
        defer { close(root) }
        let context = try directory(".kikigaki-context", parent: root)
        defer { close(context) }
        let meeting = try directory(request.envelope.meetingID.uuidString, parent: context)
        defer { close(meeting) }
        let ai = try directory("ai", parent: meeting)
        defer { close(ai) }
        let inbox = try directory("inbox", parent: ai)
        defer { close(inbox) }
        let fd = openat(inbox, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw AIError.unsafeFile }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == ownerID, info.st_mode & 0o7777 == 0o600, info.st_nlink == 1 else { throw AIError.unsafeFile }
        guard info.st_size >= 0, info.st_size <= AILimits.eventBytes else { throw AIError.tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw AIError.unsafeFile }
            if count == 0 { break }
            guard data.count <= AILimits.eventBytes - count else { throw AIError.tooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
        return try Self.decode(data, filename: filename, for: request)
    }

    /// ファイルI/Oから独立してJSON・名前・サイズ・requestの対応を検証できる。
    public static func decode(_ data: Data, filename: String, for request: AIRequest) throws -> AIReceiveEvent {
        guard data.count <= AILimits.eventBytes else { throw AIError.tooLarge }
        let event = try AIJSON.decode(AIReceiveEvent.self, from: data)
        try event.validate(for: request)
        guard filename == event.filename else { throw AIError.mismatch }
        return event
    }

    private func directory(_ name: String, parent: Int32) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AIError.unsafeFile }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == ownerID, info.st_mode & 0o7777 == 0o700 else {
            close(fd)
            throw AIError.unsafeFile
        }
        return fd
    }
}
