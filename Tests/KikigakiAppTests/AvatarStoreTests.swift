import AppKit
import CryptoKit
import Darwin
import Testing
@testable import Kikigaki

private final class AvatarProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let kind = request.url!.lastPathComponent
        let headers = kind == "length" ? ["Content-Length": String(AvatarStore.maxBytes + 1)] : [:]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: kind == "status" ? 404 : 200,
                                                          httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if kind == "overflow" {
            for _ in 0..<161 { client?.urlProtocol(self, didLoad: Data(count: 65536)) }
        } else {
            client?.urlProtocol(self, didLoad: kind == "valid" ? AvatarStoreTests.png : Data("not an image".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.timeLimit(.minutes(1))) struct AvatarStoreTests {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH1sAAAAASUVORK5CYII=")!
    static let dummyUserinfo = "user:password@"
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func cache(_ source: String, in root: URL) -> URL {
        root.appendingPathComponent(SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined())
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AvatarProtocol.self]
        return URLSession(configuration: config)
    }

    @Test(arguments: [
        ("https://" + AvatarStoreTests.dummyUserinfo + "avatar.test:8443/images/me.png?token=secret#private", "https://avatar.test/images/me.png"),
        ("HTTP://" + AvatarStoreTests.dummyUserinfo + "avatar.test/images/me%20icon.png?token=secret#private", "HTTP://avatar.test/images/me%20icon.png"),
        ("https://avatar.test", "https://avatar.test"),
        ("https://[::1]:8443/avatar.png?token=secret#private", "https://[::1]/avatar.png"),
        ("https://[invalid?token=secret#private", "<不正な画像URL>")
    ])
    func 取得失敗ログはschemeとhostとpathだけを残す(_ source: String, _ expected: String) {
        let error = NSError(domain: NSURLErrorDomain, code: URLError.badServerResponse.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Failed to load " + source])
        let message = AvatarStore.failureMessage(source: source, error: error)
        #expect(message == "アバターを読み込めません: \(expected): NSURLErrorDomain -1011")
        for secret in ["user", "password", "token", "secret", "private", "8443"] {
            #expect(!message.contains(secret))
        }
    }

    @Test func ローカル画像の失敗はパスと理由を残す() {
        let path = "~/Pictures/avatar.png"
        let error = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [NSLocalizedDescriptionKey: "見つかりません"])
        #expect(AvatarStore.failureMessage(source: path, error: error) == "アバターを読み込めません: \(path): 見つかりません")
    }

    @Test @MainActor func 実際の取得失敗ログにも不正URLの秘密を残さない() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var logged = ""
        let store = AvatarStore(cacheDirectory: root, log: { logged = $0 })
        #expect(store.image(for: "https://[invalid?token=secret#private") == nil)
        for _ in 0..<100 where logged.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(logged == "アバターを読み込めません: <不正な画像URL>: NSURLErrorDomain -1000")
    }

    @Test func 応答を検証してから保存し不正キャッシュは取り直す() async throws {
        let root = try root(), session = session(), source = "https://avatar.test/valid"
        defer { try? FileManager.default.removeItem(at: root); session.invalidateAndCancel() }
        let cached = cache(source, in: root)
        try Data("broken".utf8).write(to: cached)
        #expect(try await AvatarStore.load(source, cacheDirectory: root, session: session) == Self.png)
        #expect(try Data(contentsOf: cached) == Self.png)
        #expect(try await AvatarStore.load(source, cacheDirectory: root, session: session) == Self.png)
    }

    @Test(arguments: ["overflow", "length", "invalid", "status"])
    func 取得失敗ではキャッシュを残さない(_ kind: String) async throws {
        let root = try root(), session = session(), source = "https://avatar.test/" + kind
        defer { try? FileManager.default.removeItem(at: root); session.invalidateAndCancel() }
        let cached = cache(source, in: root)
        try Data("old invalid cache".utf8).write(to: cached)
        await #expect(throws: (any Error).self) { try await AvatarStore.load(source, cacheDirectory: root, session: session) }
        #expect(!FileManager.default.fileExists(atPath: cached.path))
    }

    @Test func 通常ファイルとバイト境界を開いたfdで検証する() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image")
        try Self.png.write(to: file)
        #expect(try await AvatarStore.load(file.path, cacheDirectory: root) == Self.png)
        try Data(count: AvatarStore.maxBytes).write(to: file)
        #expect(try AvatarStore.readFile(file).count == AvatarStore.maxBytes)
        try Data(count: AvatarStore.maxBytes + 1).write(to: file)
        #expect(throws: (any Error).self) { try AvatarStore.readFile(file) }
        #expect(throws: (any Error).self) { try AvatarStore.readFile(root) }
        let fifo = root.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try AvatarStore.readFile(fifo) }
    }

    @Test func 巨大寸法は展開前に拒否する() throws {
        // 1bitの白黒TIFFなら約5MiBで、バイト上限内の過大な寸法を実画像で試せる。
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10_000, pixelsHigh: 4_001,
            bitsPerSample: 1, samplesPerPixel: 1, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceWhite, bytesPerRow: 0, bitsPerPixel: 0))
        let oversized = try #require(bitmap.representation(using: .tiff, properties: [:]))
        #expect(oversized.count <= AvatarStore.maxBytes)
        try AvatarStore.validate(Self.png)
        #expect(throws: CocoaError(.fileReadTooLarge)) { try AvatarStore.validate(oversized) }
    }
}
