import AppKit
import KikigakiCore

/// 送信ごとの宛先を選ぶポップアップ。上段が設定のプロファイル、区切りの下が稼働中のherdrペイン。
/// 稼働中の一覧は後から届くので、選択中の項目を保ったまま差し替える。
@MainActor
final class AIDestinationPicker: NSStackView {
    enum Choice: Equatable {
        case profile(slot: Int)
        case agent(paneID: String)
    }
    var onChange: ((Choice) -> Void)?
    private let popup = NSPopUpButton()
    private let label = Washi.label("宛先", size: 13)
    private var profiles: [(slot: Int, name: String)] = []
    private var agents: [AIAgentCandidate] = []
    private(set) var selected: Choice = .profile(slot: 1)

    init() {
        super.init(frame: .zero)
        orientation = .horizontal; spacing = 12; alignment = .centerY
        popup.target = self; popup.action = #selector(changed)
        popup.setAccessibilityLabel("送信先")
        setViews([label, popup], in: .leading)
    }
    required init?(coder: NSCoder) { nil }

    /// プロファイルが1つで稼働中の候補も無ければ、選ぶものが無いので行ごと隠す。
    func update(profiles: [(slot: Int, name: String)], selected: Choice, agents: [AIAgentCandidate] = []) {
        self.profiles = profiles; self.agents = agents; self.selected = selected
        popup.removeAllItems()
        for profile in profiles {
            popup.addItem(withTitle: profile.name)
            popup.lastItem?.representedObject = Choice.profile(slot: profile.slot)
        }
        let known = Set(profiles.map(\.name))
        let extra = agents.filter { !known.contains(Self.title(for: $0)) }
        if !extra.isEmpty {
            popup.menu?.addItem(.separator())
            for agent in extra {
                popup.addItem(withTitle: Self.title(for: agent))
                popup.lastItem?.representedObject = Choice.agent(paneID: agent.paneID)
                popup.lastItem?.toolTip = [agent.cwd, agent.title].compactMap { $0 }.joined(separator: " · ")
            }
        }
        let index = popup.itemArray.firstIndex { ($0.representedObject as? Choice) == selected }
        popup.selectItem(at: index ?? 0)
        isHidden = profiles.count <= 1 && extra.isEmpty
    }

    func agent(for paneID: String) -> AIAgentCandidate? { agents.first { $0.paneID == paneID } }

    /// 表題は表示名を主にし、同じ表示名のペインが並ぶときだけ pane ID で見分ける。
    static func title(for agent: AIAgentCandidate) -> String {
        let name = agent.displayAgent?.trimmingCharacters(in: .whitespaces)
        return (name?.isEmpty == false ? name! : agent.paneID) + " (" + agent.paneID + ")"
    }

    @objc private func changed() {
        guard let choice = popup.selectedItem?.representedObject as? Choice else { return }
        selected = choice
        onChange?(choice)
    }
}
