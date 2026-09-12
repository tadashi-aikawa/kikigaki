import AppKit

/// 読み取った本文と同じfdのmtimeを表示する。受信時刻を更新時刻と取り違えない。
@MainActor final class MinutesUpdateStatus: NSView {
    let label = Washi.label("最終更新 —", size: 11, color: Washi.muted)
    private(set) var modifiedAt: Date?
    private var timer: Timer?
    var active = false { didSet { updateTimer() } }
    private let formatter: DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier: "ja_JP")
        value.dateFormat = "HH:mm:ss"; return value
    }()
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        addSubview(label); label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }
    func setDate(_ date: Date?) {
        modifiedAt = date; refresh(); updateTimer()
    }
    func refresh(now: Date = Date()) {
        guard let modifiedAt else { label.stringValue = "最終更新 —"; label.toolTip = nil; return }
        let sameDay = Calendar.current.isDate(modifiedAt, inSameDayAs: now)
        formatter.dateFormat = sameDay ? "HH:mm:ss" : "yyyy/MM/dd HH:mm:ss"
        let value = "最終更新 " + formatter.string(from: modifiedAt) + " · " + Self.relative(modifiedAt, now: now)
        if label.stringValue != value { label.stringValue = value }
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        let tooltip = "ファイルの最終更新: " + formatter.string(from: modifiedAt)
        if label.toolTip != tooltip { label.toolTip = tooltip }
    }
    static func relative(_ date: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < -10 { return "未来の更新時刻" }
        if elapsed < 10 { return "たった今" }
        if elapsed < 60 { return "\(Int(elapsed / 10) * 10)秒前" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))分前" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))時間前" }
        return "\(Int(elapsed / 86400))日前"
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateTimer() }
    private func updateTimer() {
        timer?.invalidate(); timer = nil
        guard active, modifiedAt != nil, window != nil else { return }
        refresh()
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
}
