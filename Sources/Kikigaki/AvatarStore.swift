import AppKit
import CryptoKit

/// 読み込みの成否を起動中は記憶する。同じURLを行数ぶん取得しない。
@MainActor
final class AvatarStore {
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
                self?.log("アバターを読み込めません: \(source): \(error.localizedDescription)")
            }
        }
        return nil
    }

    nonisolated static func load(_ source: String, cacheDirectory: URL, session: URLSession = .shared) async throws -> Data {
        guard source.lowercased().hasPrefix("https://") || source.lowercased().hasPrefix("http://") else {
            return try Data(contentsOf: URL(fileURLWithPath: (source as NSString).expandingTildeInPath))
        }
        guard let url = URL(string: source) else { throw URLError(.badURL) }
        let key = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        let cached = cacheDirectory.appendingPathComponent(key)
        if let data = try? Data(contentsOf: cached) { return data }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        // キャッシュ書き込みの失敗だけで表示を諦めない。
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cached, options: .atomic)
        return data
    }
}
