import Darwin
import Foundation
import KikigakiCore

/// アプリ専用の保存。基点は呼び手が予約した保存先で、相対パスは生成済みIDだけから作る。
/// 中間要素もfdで辿り、0700の既存ディレクトリだけを受け入れる。
struct AIFileStore {
    let root: URL

    func directory(_ components: [String], create: Bool = true) throws -> URL {
        let fd = try openDirectory(components, create: create)
        close(fd)
        return components.reduce(root) { $0.appendingPathComponent($1) }
    }

    func read(_ components: [String], limit: Int = 32 * 1024 * 1024) throws -> Data {
        guard let name = components.last else { throw AIError.unsafeFile }
        try validate(name)
        let parent = try openDirectory(Array(components.dropLast()), create: false)
        defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw AIError.unsafeFile }
        defer { close(fd) }
        try validateFile(fd)
        var info = stat(); guard fstat(fd, &info) == 0, info.st_size >= 0, info.st_size <= limit else { throw AIError.tooLarge }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw AIError.unsafeFile }
            if count == 0 { return data }
            guard count <= limit - data.count else { throw AIError.tooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    func write(_ data: Data, to components: [String], replacing: Bool = true) throws {
        guard let name = components.last else { throw AIError.unsafeFile }
        try validate(name)
        let parent = try openDirectory(Array(components.dropLast()), create: true)
        defer { close(parent) }
        let temporary = ".writing-" + UUID().uuidString
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AIError.unsafeFile }
        defer { close(fd); unlinkat(parent, temporary, 0) }
        guard fchmod(fd, 0o600) == 0 else { throw AIError.unsafeFile }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw AIError.unsafeFile }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw AIError.unsafeFile }
        if replacing {
            let previous = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if previous >= 0 {
                defer { close(previous) }
                try validateFile(previous)
            } else if errno != ENOENT { throw AIError.unsafeFile }
            guard renameat(parent, temporary, parent, name) == 0 else { throw AIError.unsafeFile }
        } else {
            // 既存requestを上書きしない。完成済みのinodeだけを排他公開する。
            guard linkat(parent, temporary, parent, name, 0) == 0 else { throw AIError.conflict }
            guard unlinkat(parent, temporary, 0) == 0 else { throw AIError.unsafeFile }
        }
        guard fsync(parent) == 0 else { throw AIError.unsafeFile }
    }

    private func validate(_ component: String) throws {
        guard !component.isEmpty, component != ".", component != "..",
              !component.contains("/"), !component.contains("\0") else { throw AIError.unsafeFile }
    }

    private func validateFile(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o7777 == 0o600, info.st_nlink == 1 else { throw AIError.unsafeFile }
    }

    private func openDirectory(_ components: [String], create: Bool) throws -> Int32 {
        guard root.isFileURL else { throw AIError.unsafeFile }
        var parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw AIError.unsafeFile }
        do {
            for component in components {
                try validate(component)
                if create, mkdirat(parent, component, 0o700) != 0, errno != EEXIST { throw AIError.unsafeFile }
                let child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw AIError.unsafeFile }
                var info = stat()
                guard fstat(child, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else {
                    close(child); throw AIError.unsafeFile
                }
                close(parent); parent = child
            }
            return parent
        } catch { close(parent); throw error }
    }
}
