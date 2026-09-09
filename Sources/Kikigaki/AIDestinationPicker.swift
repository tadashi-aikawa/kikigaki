import AppKit
import KikigakiCore

/// 送信ごとの宛先を選ぶポップアップ。並ぶのは設定のプロファイルだけで、
/// そのプロファイルに未紐づけの準備済みセッションがあれば行に添えて示す。
@MainActor
final class AIDestinationPicker: NSStackView {
    /// 1行ぶんの表示。`prepared` は名前に続けて出す「Kikigaki 議事録抽出 · 13:05起動」の部分で、
    /// ペインの表題が取れないときは「13:05起動」だけになる。組み立ては呼び手が行う
    struct Item: Equatable {
        let slot: Int
        let name: String
        var prepared: String?
    }
    var onChange: ((Int) -> Void)?
    private let popup = NSPopUpButton()
    private let label = Washi.label("宛先", size: 13)
    private(set) var items: [Item] = []
    private(set) var selected = 1

    init() {
        super.init(frame: .zero)
        orientation = .horizontal; spacing = 12; alignment = .centerY
        popup.target = self; popup.action = #selector(changed)
        popup.setAccessibilityLabel("送信先")
        setViews([label, popup], in: .leading)
    }
    required init?(coder: NSCoder) { nil }

    /// プロファイルが1つで準備済みも無ければ、選ぶものが無いので行ごと隠す。
    func update(items: [Item], selected: Int) {
        self.items = items; self.selected = selected
        popup.removeAllItems()
        for item in items {
            popup.addItem(withTitle: item.prepared.map { "\(item.name) · \($0)" } ?? item.name)
            popup.lastItem?.representedObject = item.slot
        }
        let index = popup.itemArray.firstIndex { ($0.representedObject as? Int) == selected }
        popup.selectItem(at: index ?? 0)
        isHidden = items.count <= 1 && items.allSatisfy { $0.prepared == nil }
    }

    /// 送信を始めたら操作させない。無効時は面を足さず、既にある枠のまま色を抜く。
    func setEnabled(_ enabled: Bool) {
        popup.isEnabled = enabled
        label.textColor = enabled ? Washi.ink : Washi.muted
    }

    @objc private func changed() {
        guard let slot = popup.selectedItem?.representedObject as? Int else { return }
        selected = slot
        onChange?(slot)
    }
}
