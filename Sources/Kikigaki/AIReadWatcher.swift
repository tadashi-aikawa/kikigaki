import AppKit

/// 展開が既定になったので、印を開く操作の代わりに可視化で既読にする。
/// 行が可視域と重なった状態で、ウィンドウを見ているまま連続1秒留まったら既読。
/// 書き起こしウィンドウと過去会議ウィンドウで同じ判定を使う。
@MainActor final class AIReadWatcher {
    /// 単調時計。時計を変えても滞在時間が飛ばないようにする。
    nonisolated static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var rows: () -> [AIReplyRow] = { [] }
    var clip: () -> NSRect = { .zero }
    var isActive: () -> Bool = { false }
    var onRead: ((UUID) -> Void)?
    private var since: [String: TimeInterval] = [:]
    private var timer: Timer?
    private var observers: [any NSObjectProtocol] = []

    /// - window: 監視するウィンドウ。別のウィンドウの最小化で滞在時間を消さないため所有元へ限定する。
    init(window: @escaping () -> NSWindow?) {
        // 見ていない間の時間を数えない。次に戻ってきたら0から数え直す。
        let handler: @Sendable (Notification) -> Void = { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                // アプリ全体の非活性はどのウィンドウでも効く。ウィンドウ通知は所有元だけ見る。
                if note.name == NSApplication.didResignActiveNotification || (note.object as AnyObject?) === window() {
                    self.reset()
                }
            }
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification,
                     NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: handler))
        }
    }
    deinit {
        timer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func reset() { since.removeAll() }

    /// 未読があるときだけ監視する。スクロールのドラッグ中も止めないため common modes へ入れる。
    func refresh() {
        let hasUnread = rows().contains { $0.item.isUnread }
        if hasUnread, timer == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    // 解放後もRunLoopへ残らないよう、参照先が消えたら自分で止める。
                    guard let watcher = self else { timer.invalidate(); return }
                    watcher.evaluate()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !hasUnread {
            stop()
        }
    }
    func stop() { timer?.invalidate(); timer = nil; since.removeAll() }

    /// 可視域が変わった時点で、外れた行の滞在時間を捨てる。
    /// 0.25秒の間に出入りした行の時間を足し続けないための更新で、ここでは既読にしない。
    func noteVisibilityChanged() {
        guard !since.isEmpty else { return }
        let visible = Set(visibleRows().map(\.item.rowID))
        since = since.filter { visible.contains($0.key) }
    }

    private func visibleRows() -> [AIReplyRow] {
        guard isActive() else { return [] }
        let clip = self.clip()
        // 行と可視域の重なりで見る。上端だけを条件にすると、画面いっぱいの長い返事は
        // スクロールしながら読んでいる間ずっと対象から外れ、いつまでも既読にならない。
        return rows().filter { $0.frame.maxY > clip.minY && $0.frame.minY < clip.maxY - 8 }
    }

    func evaluate(now: TimeInterval = AIReadWatcher.now, dwell: TimeInterval = 1) {
        var seen: Set<String> = []
        var read: [UUID] = []
        // 画面の上から順に見る。辞書の順で回すと既読になる順が実行ごとに変わる。
        for row in visibleRows() where row.item.isUnread {
            seen.insert(row.item.rowID)
            let start = since[row.item.rowID] ?? now
            since[row.item.rowID] = start
            if now - start >= dwell { read.append(row.item.requestID) }
        }
        since = since.filter { seen.contains($0.key) }
        // 既読の保存は行の作り直しを呼ぶので、走査を終えてから通知する。
        for id in read { onRead?(id) }
    }
}
