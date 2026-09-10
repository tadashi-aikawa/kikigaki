import Darwin
import Foundation
import KikigakiCore

struct MinutesFileStamp: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let seconds: Int
    let nanos: Int
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; size = value.st_size
        seconds = value.st_mtimespec.tv_sec; nanos = value.st_mtimespec.tv_nsec
    }
    static func at(_ path: String) -> Self? {
        var value = stat()
        return stat(path, &value) == 0 ? Self(value) : nil
    }
}

enum MinutesFileResult: Sendable {
    case body(String, [MarkdownBlock])
    case missing, cloud, changed
    case failure(String)

    static func read(_ path: String) -> Self {
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
           values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == .notDownloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return .cloud
        }
        // O_NONBLOCKによりFIFOの待ちを避け、fdを得てから通常ファイルを確認する。
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT || errno == ENOTDIR { return .missing }
            if errno == EACCES || errno == EPERM { return .failure("アクセス許可がなく読めません。システム設定の「ファイルとフォルダ」を確認してください") }
            return .failure("ファイルを読めません。パスとアクセス権を確認してください")
        }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { return .failure("通常のファイルを指定してください") }
        guard before.st_size <= MinutesPath.bodyBytes else {
            let size = String(format: "%.2f", Double(before.st_size) / 1_048_576)
            return .failure("大きすぎるため表示しません: \(size) MiB。上限は4 MiBです")
        }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            if Task.isCancelled { return .changed }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; return .failure("ファイルの読み取りに失敗しました") }
            guard bytes.count <= MinutesPath.bodyBytes - count else { return .failure("大きすぎるため表示しません: 4 MiB超") }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, MinutesFileStamp(before) == MinutesFileStamp(after),
              MinutesFileStamp.at(path) == MinutesFileStamp(after) else { return .changed }
        guard let text = String(data: bytes, encoding: .utf8) else { return .failure("UTF-8のファイルとして読めません") }
        return .body(text, MarkdownBlocks.parse(text, minutes: true))
    }
}

/// 元パスと解決先の親も監視する。symlinkの付け替え・rename保存・親の交換はTimerでも補う。
@MainActor final class MinutesFileMonitor {
    private let path: String
    private let receive: (MinutesFileResult) -> Void
    private let read: @Sendable (String) async -> MinutesFileResult
    private var sources: [DispatchSourceFileSystemObject] = []
    private var watched: [String: MinutesFileStamp] = [:]
    private var stamp: MinutesFileStamp?
    private var timer: Timer?
    private var pending: Task<Void, Never>?
    private var reader: Task<MinutesFileResult, Never>?
    private var generation = 0
    private var stopped = false
    private var retry = true

    init(path: String, interval: TimeInterval = 2,
         read: @escaping @Sendable (String) async -> MinutesFileResult = { MinutesFileResult.read($0) },
         receive: @escaping (MinutesFileResult) -> Void) {
        self.path = path; self.receive = receive; self.read = read
        scan(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
    }

    func scan(force: Bool = false) {
        guard !stopped else { return }
        attach()
        let current = MinutesFileStamp.at(path)
        guard force || retry || stamp != current else { return }
        stamp = current; retry = false; generation += 1
        let ticket = generation, path = path
        pending?.cancel(); reader?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            let readBody = self.read
            let read = Task.detached(priority: .utility) { await readBody(path) }
            self.reader = read
            let result = await read.value
            guard !Task.isCancelled, !self.stopped, ticket == self.generation else { return }
            switch result {
            case .changed: self.retry = true; self.scan(force: true); return
            case .cloud, .missing: self.retry = true
            case .body, .failure: break
            }
            self.receive(result)
        }
    }

    private func attach() {
        let url = URL(fileURLWithPath: path), resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let paths = Set([path, url.deletingLastPathComponent().path, resolved.path, resolved.deletingLastPathComponent().path])
        let next = Dictionary(uniqueKeysWithValues: paths.compactMap { name in MinutesFileStamp.at(name).map { (name, $0) } })
        // 通常のwriteでは再接続不要。監視先のinodeが変わった場合だけ差し替える。
        let same = next.count == watched.count && next.allSatisfy { name, value in
            watched[name].map { $0.device == value.device && $0.inode == value.inode } ?? false
        }
        guard !same else { return }
        sources.forEach { $0.cancel() }; sources = []; watched = next
        for name in next.keys {
            var value = stat()
            guard stat(name, &value) == 0, [S_IFREG, S_IFDIR].contains(value.st_mode & S_IFMT) else { continue }
            let fd = open(name, O_EVTONLY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .revoke, .extend, .attrib], queue: .main)
            source.setEventHandler { [weak self] in self?.scan() }
            source.setCancelHandler { close(fd) }
            sources.append(source); source.activate()
        }
    }

    func stop() {
        stopped = true; generation += 1; timer?.invalidate(); timer = nil
        pending?.cancel(); reader?.cancel(); sources.forEach { $0.cancel() }; sources = []
    }
    deinit { timer?.invalidate(); pending?.cancel(); reader?.cancel(); sources.forEach { $0.cancel() } }
}
