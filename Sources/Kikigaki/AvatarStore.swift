import AppKit
import CryptoKit
import Darwin
import ImageIO

/// 読み込みの成否を起動中は記憶する。同じURLを行数ぶん取得しない。
@MainActor
final class AvatarStore {
    nonisolated static let maxBytes = 10 * 1024 * 1024
    nonisolated static let maxPixels = 40_000_000
    private nonisolated static let networkSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
    private var images: [String: NSImage] = [:]
    private var requested = Set<String>()
    var onChange: (() -> Void)?
    private let cacheDirectory: URL
    private let log: (String) -> Void

    init(cacheDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/kikigaki/avatars"),
         log: @escaping (String) -> Void = { NSLog("%@", $0) }) {
        self.cacheDirectory = cacheDirectory
        self.log = log
    }

    func image(for source: String?) -> NSImage? {
        guard let source else { return nil }
        if let image = images[source] { return image }
        guard requested.insert(source).inserted else { return nil }
        let directory = cacheDirectory
        Task { [weak self] in
            do {
                let data = try await Task.detached(priority: .utility) {
                    try await Self.load(source, cacheDirectory: directory)
                }.value
                guard let self else { return }
                guard let image = NSImage(data: data), image.isValid else { throw CocoaError(.fileReadCorruptFile) }
                images[source] = image
                onChange?()
            } catch {
                self?.log(Self.failureMessage(source: source, error: error))
            }
        }
        return nil
    }

    nonisolated static func failureMessage(source: String, error: Error) -> String {
        guard source.lowercased().hasPrefix("https://") || source.lowercased().hasPrefix("http://") else {
            return "アバターを読み込めません: \(source): \(error.localizedDescription)"
        }
        var identifier = "<不正な画像URL>"
        if let components = URLComponents(string: source), let host = components.host, !host.isEmpty {
            var safe = URLComponents()
            safe.scheme = components.scheme
            safe.host = host
            safe.percentEncodedPath = components.percentEncodedPath
            identifier = safe.string ?? identifier
        }
        // localizedDescriptionにも失敗URLが含まれ得るため、URL取得のエラーはdomainとcodeだけ残す。
        let failure = error as NSError
        return "アバターを読み込めません: \(identifier): \(failure.domain) \(failure.code)"
    }

    nonisolated static func load(_ source: String, cacheDirectory: URL, session: URLSession = networkSession) async throws -> Data {
        guard source.lowercased().hasPrefix("https://") || source.lowercased().hasPrefix("http://") else {
            let data = try readFile(URL(fileURLWithPath: (source as NSString).expandingTildeInPath))
            try validate(data)
            return data
        }
        guard let url = URL(string: source) else { throw URLError(.badURL) }
        let key = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        let cached = cacheDirectory.appendingPathComponent(key)
        do {
            let data = try readFile(cached)
            try validate(data)
            return data
        } catch {
            // 旧版で保存した不正・過大なキャッシュも次の起動へ残さない。
            try? FileManager.default.removeItem(at: cached)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // URLSession自身のディスクキャッシュにも未検証の本文を残さない。
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard response.expectedContentLength <= maxBytes else { throw CocoaError(.fileReadTooLarge) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maxBytes else { throw CocoaError(.fileReadTooLarge) }
            data.append(byte)
        }
        try validate(data)
        // キャッシュ書き込みの失敗だけで表示を諦めない。
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cached, options: .atomic)
        return data
    }

    /// openした同じfdを検証する。FIFO等で待たず、読み取り中の増大にも上限を適用する。
    nonisolated static func readFile(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard info.st_size >= 0, info.st_size <= maxBytes else { throw CocoaError(.fileReadTooLarge) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
            if count == 0 { return data }
            guard count <= maxBytes - data.count else { throw CocoaError(.fileReadTooLarge) }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    nonisolated static func validate(_ data: Data) throws {
        guard data.count <= maxBytes else { throw CocoaError(.fileReadTooLarge) }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw CocoaError(.fileReadCorruptFile) }
        // NSImageは複数フレームも展開し得るため、各画像の合計画素数をデコード前に調べる。
        var remaining = maxPixels
        for index in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0 else { throw CocoaError(.fileReadCorruptFile) }
            guard width <= remaining / height else { throw CocoaError(.fileReadTooLarge) }
            remaining -= width * height
        }
        guard let image = NSImage(data: data), image.isValid else { throw CocoaError(.fileReadCorruptFile) }
    }
}
