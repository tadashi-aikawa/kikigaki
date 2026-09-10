import AppKit
import KikigakiCore
import KikigakiAIIO

/// 録音開始時に、どの準備済みセッションを使うかプロファイルごとに選ぶシート。
/// 未紐づけが1件も無ければ出さない。取消は録音を始めない。
@MainActor
final class AIAttachSheet: NSObject {
    struct Choice {
        let slot: Int
        let name: String
        /// 古い順。先頭が既定の選択になる
        let prepared: [(id: UUID, label: String)]
    }
    /// 出す枠を決める。**候補が尽きた枠も `includingEmpty` で残す。**
    /// 選び直しでは、選ぶものが無くても「新規に起動する」を利用者に選ばせる。
    static func choices(profiles: [(slot: Int, name: String)], slots: Set<Int>? = nil,
                        includingEmpty: Bool = false,
                        prepared: (Int) -> [(id: UUID, label: String)]) -> [Choice] {
        profiles.filter { slots?.contains($0.slot) ?? true }.compactMap { profile in
            let rows = prepared(profile.slot)
            guard !rows.isEmpty || includingEmpty else { return nil }
            return Choice(slot: profile.slot, name: profile.name, prepared: rows)
        }
    }

    let window: NSWindow
    /// 枠ごとの選択。値が nil なら「新規に起動する」
    var onStart: (([Int: UUID?]) -> Void)?
    var onCancel: (() -> Void)?

    private var groups: [Int: [NSButton]] = [:]
    private var choices: [Choice] = []
    private let avatars = AvatarStore()
    private var avatarSources: [Int: String] = [:]

    init(choices: [Choice], warning: String? = nil, avatarSources: [Int: String] = [:]) {
        self.choices = choices
        window = AIQuestionWindow(contentRect: NSRect(x: 0, y: 0, width: 504, height: 360),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        self.avatarSources = avatarSources
        avatars.onChange = { [weak self] in self?.refreshAvatars() }
        window.appearance = NSAppearance(named: .aqua); window.backgroundColor = Washi.paper
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        var views: [NSView] = [Washi.label("準備済みのAIセッション", size: 17, weight: .semibold),
                               Washi.label("この録音で使うセッションをプロファイルごとに選んでください", size: 12, color: Washi.muted)]
        // 引き継ぎに失敗して選び直すときは、理由を先に出す。
        if let warning { views.append(Washi.label(warning, size: 12, color: Washi.gold)) }
        for (index, choice) in choices.enumerated() {
            if index > 0 { let line = NSBox(); line.boxType = .separator; views.append(line) }
            views.append(Washi.label(choice.name, size: 13, weight: .semibold))
            var buttons: [NSButton] = []
            // 既定は最も古い1件。連続する会議では用意した順に使うのが自然。
            for (position, prepared) in choice.prepared.enumerated() {
                let radio = NSButton(radioButtonWithTitle: "準備済み \(prepared.label) を使う", target: self, action: #selector(pick))
                radio.state = position == 0 ? .on : .off
                radio.identifier = NSUserInterfaceItemIdentifier(prepared.id.uuidString)
                buttons.append(radio); views.append(indented(radio))
            }
            let fresh = NSButton(radioButtonWithTitle: "新規に起動する", target: self, action: #selector(pick))
            fresh.state = choice.prepared.isEmpty ? .on : .off
            buttons.append(fresh); views.append(indented(fresh))
            groups[choice.slot] = buttons
        }
        refreshAvatars()
        views.append(Washi.label("使わなかった準備済みセッションは残ります。次の録音でも選べます", size: 11, color: Washi.muted))
        let start = NSButton(title: "開始", target: self, action: #selector(startPressed))
        start.bezelStyle = .rounded; start.keyEquivalent = "\r"
        let cancel = NSButton(title: "取消 (録音を始めない)", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let actions = NSStackView(views: [NSView(), cancel, start])
        actions.orientation = .horizontal; actions.spacing = 12
        views.append(actions)
        for view in views {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        window.contentView = stack
        // 枠と候補の数で高さが変わる。余った高さを行間へ配らないよう、中身に合わせて詰める。
        stack.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 504, height: max(240, stack.fittingSize.height)))
    }

    private func indented(_ view: NSView) -> NSView {
        let row = NSStackView(views: [view])
        row.orientation = .horizontal
        row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        return row
    }

    private func refreshAvatars() {
        for choice in choices {
            let image = AIProfileAvatar.image(name: choice.name, source: avatarSources[choice.slot], store: avatars)
            for button in groups[choice.slot] ?? [] where button.identifier != nil {
                // radioのimageは選択印。上書きせず、タイトル内に画像を添える。
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = NSRect(x: 0, y: -5, width: 20, height: 21)
                let title = NSMutableAttributedString(attachment: attachment)
                let prepared = choice.prepared.first { $0.id.uuidString == button.identifier?.rawValue }
                title.append(NSAttributedString(string: " 準備済み \(prepared?.label ?? "") を使う",
                                                attributes: [.font: button.font ?? NSFont.systemFont(ofSize: 13)]))
                button.attributedTitle = title
            }
        }
    }

    /// いまの選択。値が nil の枠は新規に起動する。
    var selection: [Int: UUID?] {
        var result: [Int: UUID?] = [:]
        for (slot, buttons) in groups {
            let chosen = buttons.first { $0.state == .on }
            result[slot] = chosen?.identifier.flatMap { UUID(uuidString: $0.rawValue) }
        }
        return result
    }

    func present(on parent: NSWindow) { parent.beginSheet(window) }
    func close() { if let parent = window.sheetParent { parent.endSheet(window) }; window.orderOut(nil) }
    /// 同じ枠のラジオは1つだけ入にする。NSButtonのradioは同じ親でしか排他にならない。
    @objc private func pick(_ sender: NSButton) {
        for buttons in groups.values where buttons.contains(sender) {
            for button in buttons { button.state = button == sender ? .on : .off }
        }
    }
    @objc private func startPressed() { let value = selection; close(); onStart?(value) }
    @objc private func cancelPressed() { close(); onCancel?() }
}
