import AppKit
import KikigakiCore

/// 送信ごとの宛先を選ぶポップアップ。並ぶのは設定のプロファイルだけで、
/// そのプロファイルに未紐づけの準備済みセッションがあれば行に添えて示す。
@MainActor
final class AIDestinationPicker: NSStackView {
    /// 未紐づけの準備済みセッション。プロファイルの下へ字下げして並べる
    struct Prepared: Equatable {
        let id: UUID
        /// 「Kikigaki 議事録抽出 · 13:05起動」。表題が取れないときは「13:05起動」だけ
        let label: String
    }
    /// 1行ぶんの表示。`bound` は紐づけ済みのときに閉じた表題へ添える文字列
    struct Item: Equatable {
        let slot: Int
        let name: String
        var prepared: [Prepared] = []
        var bound: String?
    }
    var onChange: ((Int) -> Void)?
    /// 準備済みを選んだ。呼び手が紐づけてから一覧を差し替える
    var onPrepared: ((Int, UUID) -> Void)?
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
            // 閉じた表題は「議事録 · 表題 · 13:05起動」。紐づけたときだけ添える。
            popup.addItem(withTitle: item.bound.map { "\(item.name) · \($0)" } ?? item.name)
            popup.lastItem?.representedObject = Choice.profile(item.slot)
            for prepared in item.prepared {
                popup.addItem(withTitle: "準備済み " + prepared.label)
                popup.lastItem?.representedObject = Choice.prepared(item.slot, prepared.id)
                popup.lastItem?.indentationLevel = 1
            }
        }
        let index = popup.itemArray.firstIndex { ($0.representedObject as? Choice) == .profile(selected) }
        popup.selectItem(at: index ?? 0)
        // 紐づけたものがあれば、選ぶ先が1つでも「何を使っているか」を出し続ける。
        isHidden = items.count <= 1 && items.allSatisfy { $0.prepared.isEmpty && $0.bound == nil }
    }

    /// ポップアップの行が指すもの。準備済みは選んだ時点で紐づける
    private enum Choice: Equatable {
        case profile(Int)
        case prepared(Int, UUID)
    }

    /// 送信を始めたら操作させない。無効時は面を足さず、既にある枠のまま色を抜く。
    func setEnabled(_ enabled: Bool) {
        popup.isEnabled = enabled
        label.textColor = enabled ? Washi.ink : Washi.muted
    }

    @objc private func changed() {
        guard let choice = popup.selectedItem?.representedObject as? Choice else { return }
        switch choice {
        case .profile(let slot): selected = slot; onChange?(slot)
        case .prepared(let slot, let id): selected = slot; onPrepared?(slot, id)
        }
    }
}
