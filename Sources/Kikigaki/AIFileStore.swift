import Darwin
import Foundation
import KikigakiCore

enum AIFileError: Error { case missing }

/// 専用階層は0700、通常ファイルは0600。既存ファイルへの追記はせず、
/// 完成した一時ファイルをcloseしてから公開する。outputDir自体の権限は変えない。
struct AIFileStore: Sendable {
    let root: URL
    func directory(_ parts: [String], create: Bool = true) throws -> URL {
        try withDirectory(parts, create: create) { _ in }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }
    func read(_ parts: [String], limit: Int = 32 * 1024 * 1024) throws -> Data {
        guard let name = parts.last, limit >= 0 else { throw AIError.unsafeFile }
        try checkName(name)
        return try withDirectory(Array(parts.dropLast()), create: false) { parent in
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { if errno == ENOENT { throw AIFileError.missing }; throw AIError.unsafeFile }
            defer { close(fd) }
            let info = try regularFile(fd)
            guard info.st_size >= 0, info.st_size <= limit else { throw AIError.tooLarge }
            var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let size = Darwin.read(fd, &buffer, buffer.count)
                if size < 0 && errno == EINTR { continue }
                guard size >= 0 else { throw AIError.unsafeFile }
                if size == 0 { return result }
                guard size <= limit - result.count else { throw AIError.tooLarge }
                result.append(contentsOf: buffer.prefix(size))
            }
        }
    }
    func write(_ bytes: Data, to parts: [String], replacing: Bool = true) throws {
        guard let name = parts.last else { throw AIError.unsafeFile }
        try checkName(name)
        try withDirectory(Array(parts.dropLast()), create: true) { parent in
            let temporary = ".writing-" + UUID().uuidString
            var fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw AIError.unsafeFile }
            defer { if fd >= 0 { close(fd) }; unlinkat(parent, temporary, 0) }
            guard fchmod(fd, 0o600) == 0 else { throw AIError.unsafeFile }
            try bytes.withUnsafeBytes { memory in
                var written = 0
                while written < memory.count {
                    let size = Darwin.write(fd, memory.baseAddress!.advanced(by: written), memory.count - written)
                    if size < 0 && errno == EINTR { continue }
                    guard size > 0 else { throw AIError.unsafeFile }
                    written += size
                }
            }
            guard fsync(fd) == 0 else { throw AIError.unsafeFile }
            let closed = close(fd); fd = -1
            guard closed == 0 else { throw AIError.unsafeFile }
            if replacing {
                // dangling symlinkも未存在と読み替えない。renameは既存名だけを置き換え、リンク先を辿らない。
                var previous = stat()
                if fstatat(parent, name, &previous, AT_SYMLINK_NOFOLLOW) == 0 {
                    try checkRegular(previous)
                } else if errno != ENOENT { throw AIError.unsafeFile }
                guard renameat(parent, temporary, parent, name) == 0 else { throw AIError.unsafeFile }
            } else {
                guard linkat(parent, temporary, parent, name, 0) == 0 else {
                    if errno == EEXIST { throw AIError.conflict }; throw AIError.unsafeFile
                }
                guard unlinkat(parent, temporary, 0) == 0 else { throw AIError.unsafeFile }
            }
            guard fsync(parent) == 0 else { throw AIError.unsafeFile }
        }
    }
    private func checkName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw AIError.unsafeFile }
    }
    private func checkRegular(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o600, info.st_nlink == 1 else { throw AIError.unsafeFile }
    }
    private func regularFile(_ fd: Int32) throws -> stat {
        var info = stat(); guard fstat(fd, &info) == 0 else { throw AIError.unsafeFile }
        try checkRegular(info); return info
    }
    private func withDirectory<T>(_ parts: [String], create: Bool, body: (Int32) throws -> T) throws -> T {
        guard root.isFileURL else { throw AIError.unsafeFile }
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AIError.unsafeFile }
        defer { close(fd) }
        for part in parts {
            try checkName(part)
            if create, mkdirat(fd, part, 0o700) != 0, errno != EEXIST { throw AIError.unsafeFile }
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw AIError.unsafeFile }
            var info = stat()
            guard fstat(next, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else { close(next); throw AIError.unsafeFile }
            close(fd); fd = next
        }
        return try body(fd)
    }
}
