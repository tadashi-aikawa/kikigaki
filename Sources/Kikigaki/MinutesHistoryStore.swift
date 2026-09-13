import Foundation
import KikigakiCore

/// 会議ごとのパスとは別のアプリ設定。ビューごとに古い配列を保持しない。
@MainActor final class MinutesHistoryStore {
    static let key = "KikigakiMinutesHistory"
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    var paths: [String] { MinutesHistory(paths: defaults.stringArray(forKey: Self.key) ?? []).paths }
    func record(_ path: String) {
        let current = paths
        guard current.first != path else { return }
        var history = MinutesHistory(paths: current)
        history.record(path)
        defaults.set(history.paths, forKey: Self.key)
    }
}
