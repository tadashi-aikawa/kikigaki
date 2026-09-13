import Foundation

/// 表示成功した絶対パスのMRU。存在確認・描画成否・永続化はアプリ側が担う。
public struct MinutesHistory: Equatable, Sendable {
    public static let limit = 10
    public private(set) var paths: [String]

    /// 保存順は新しい順。不正値を除き、最初の同一パスを保持する。
    public init(paths: [String] = []) {
        var seen = Set<String>()
        self.paths = paths.filter { path in
            (try? MinutesPath.validate(path)) != nil && seen.insert(path).inserted
        }.prefix(Self.limit).map { $0 }
    }

    public mutating func record(_ path: String) {
        guard (try? MinutesPath.validate(path)) != nil else { return }
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > Self.limit { paths.removeLast(paths.count - Self.limit) }
    }
}
