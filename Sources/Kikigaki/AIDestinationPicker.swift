import AppKit
import KikigakiCore

/// 送信ごとの宛先を選ぶポップアップ。並ぶのは設定のプロファイルだけ。
@MainActor
final class AIDestinationPicker: NSStackView {
    /// 1行ぶんの表示
    struct Item: Equatable {
        let slot: Int
        let name: String
        var avatar: String?
        /// `identifySpeakers = true` の宛先。開始シートと同じ紫の札「話者を推定」を添える
        var identifySpeakers = false
        init(slot: Int, name: String, avatar: String? = nil, identifySpeakers: Bool = false) {
            self.slot = slot; self.name = name; self.avatar = avatar; self.identifySpeakers = identifySpeakers
        }
        init(profile: ResolvedAIConfig) {
            self.init(slot: profile.slot, name: profile.name, avatar: profile.avatar, identifySpeakers: profile.identifySpeakers)
        }
    }
    var onChange: ((Int) -> Void)?
    private let popup = NSPopUpButton()
    private let label = Washi.label("宛先", size: 13)
    private let avatars = AvatarStore()
    private(set) var items: [Item] = []
    private(set) var selected = 1

    init() {
        super.init(frame: .zero)
        orientation = .horizontal; spacing = 12; alignment = .centerY
        popup.target = self; popup.action = #selector(changed)
        popup.setAccessibilityLabel("送信先")
        setViews([label, popup], in: .leading)
        avatars.onChange = { [weak self] in self?.refreshAvatars() }
    }
    required init?(coder: NSCoder) { nil }

    /// プロファイルが1つなら、選ぶものが無いので行ごと隠す。
    func update(items: [Item], selected: Int) {
        self.items = items; self.selected = selected
        popup.removeAllItems()
        for item in items {
            popup.addItem(withTitle: item.name)
            popup.lastItem?.representedObject = item.slot
            // 開始シートの一覧と同じく、名前の右に札を添える。選び直すときに推定付きの宛先を見分けられる。
            if item.identifySpeakers, let entry = popup.lastItem {
                let title = NSMutableAttributedString(string: item.name, attributes: [.font: NSFont.menuFont(ofSize: 13)])
                title.append(NSAttributedString(string: "  "))
                title.append(SpeakerEstimationChip.attachment(for: entry))
                entry.attributedTitle = title
                entry.setAccessibilityLabel(item.name + " 話者名を推定")
                entry.toolTip = item.name + " 話者名を推定"
            }
        }
        let index = popup.itemArray.firstIndex { ($0.representedObject as? Int) == selected }
        popup.selectItem(at: index ?? 0)
        refreshAvatars()
        isHidden = items.count <= 1
    }

    /// AI行と同じ描画と読み込みキャッシュを使い、取得完了時は画像だけ差し替える。
    /// メニューを作り直すと、開いているメニューを失ってしまう。
    private func refreshAvatars() {
        for item in items {
            let image = AIProfileAvatar.image(name: item.name, source: item.avatar, store: avatars)
            for entry in popup.itemArray where (entry.representedObject as? Int) == item.slot {
                entry.image = image
            }
        }
    }

    /// 送信を始めたら操作させない。無効時は面を足さず、既にある枠のまま色を抜く。
    func setEnabled(_ enabled: Bool) {
        popup.isEnabled = enabled
        label.textColor = enabled ? Washi.ink : Washi.muted
    }

    @objc private func changed() {
        guard let slot = popup.selectedItem?.representedObject as? Int else { return }
        selected = slot; onChange?(slot)
    }
}
