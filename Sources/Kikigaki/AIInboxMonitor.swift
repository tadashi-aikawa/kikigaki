import Darwin
import Foundation

/// 監視は再走査のきっかけだけ。完成ファイルの検証・重複排除はCoreで行う。
/// イベント通知の欠落と、監視ディレクトリの置換を定期タイマーで補う。
@MainActor
final class AIInboxMonitor {
    private let directory: URL
    private let onScan: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var identity: (dev_t, ino_t)?

    init(directory: URL, interval: TimeInterval = 2, onScan: @escaping () -> Void) {
        self.directory = directory; self.onScan = onScan
        attach()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        onScan()
    }

    func scan() {
        var info = stat()
        let exists = lstat(directory.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
        if !exists || identity?.0 != info.st_dev || identity?.1 != info.st_ino {
            source?.cancel(); source = nil; identity = nil
            if exists { attach() }
        }
        onScan()
    }

    private func attach() {
        let fd = open(directory.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { close(fd); return }
        identity = (info.st_dev, info.st_ino)
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .revoke], queue: .main)
        source.setEventHandler { [weak self] in self?.scan() }
        // Apple Dispatchの契約: closeはcancel完了後。先に閉じてfd再利用と競合させない。
        source.setCancelHandler { close(fd) }
        self.source = source
        source.activate()
    }

    func stop() { timer?.invalidate(); timer = nil; source?.cancel(); source = nil; identity = nil }
    deinit { timer?.invalidate(); source?.cancel() }
}
