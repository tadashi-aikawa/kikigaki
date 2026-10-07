import Darwin
import Foundation

/// 通常の会議保存物のI/O。専用階層を検証するAIFileStoreはCoreに依存するため、
/// ここから呼べない。同じopen(0600)→fsync→rename/linkの手順を使う。
public enum PrivateFileIO {
    private static func failure(_ code: Int32 = errno) -> NSError {
        if code == EEXIST { return CocoaError(.fileWriteFileExists) as NSError }
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    /// 利用者指定の既存ディレクトリはchmodしない。欠けた要素だけを0700で作る。
    public static func createDirectory(at url: URL) throws {
        var info = stat()
        if stat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw failure(ENOTDIR) }
            return
        }
        guard errno == ENOENT else { throw failure() }
        try createDirectory(at: url.deletingLastPathComponent())
        if mkdir(url.path, 0o700) != 0 {
            guard errno == EEXIST else { throw failure() }
            // 他プロセスが先に作った要素にもchmodしない。
            guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw failure(ENOTDIR) }
            return
        }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        guard fchmod(fd, 0o700) == 0 else { throw failure() }
    }

    /// 一時ファイルも作成時点から0600。既存inodeの権限を変えず、新しいinodeを公開する。
    public static func write(_ bytes: Data, to url: URL, replacing: Bool = true) throws {
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw failure() }
        defer { close(parent) }
        let temporary = ".writing-" + UUID().uuidString
        var fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure() }
        defer { if fd >= 0 { close(fd) }; unlinkat(parent, temporary, 0) }
        guard fchmod(fd, 0o600) == 0 else { throw failure() }
        try bytes.withUnsafeBytes { memory in
            var written = 0
            while written < memory.count {
                let size = Darwin.write(fd, memory.baseAddress!.advanced(by: written), memory.count - written)
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else { throw failure() }
                written += size
            }
        }
        guard fsync(fd) == 0 else { throw failure() }
        let closed = close(fd); fd = -1
        guard closed == 0 else { throw failure() }
        let name = url.lastPathComponent
        if replacing {
            var previous = stat()
            if fstatat(parent, name, &previous, AT_SYMLINK_NOFOLLOW) == 0 {
                guard previous.st_mode & S_IFMT == S_IFREG else { throw failure(EINVAL) }
            } else if errno != ENOENT { throw failure() }
            guard renameat(parent, temporary, parent, name) == 0 else { throw failure() }
        } else {
            guard linkat(parent, temporary, parent, name, 0) == 0 else { throw failure() }
            guard unlinkat(parent, temporary, 0) == 0 else { throw failure() }
        }
        guard fsync(parent) == 0 else { throw failure() }
    }
}
