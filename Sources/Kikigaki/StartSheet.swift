import AppKit
import KikigakiCore
import UniformTypeIdentifiers

/// 録音を始める前に、その会議だけの指定をまとめて決めるシート。
///
/// `session.start` の**前**に出す。取消は録音を始めないので、会議の巻き戻し(取り止め)は要らない。
/// 並べるのは会議ごとに変えたいものだけで、保存先や話者台帳のような設定ファイルへ書くものは置かない。
/// 決めた値は設定ファイルへ書き戻さず、この録音にだけ効く。
@MainActor
final class StartSheet: NSObject, NSTextViewDelegate {
    /// シートが決めた、この録音だけの指定。
    struct Options: Equatable {
        var systemAudioMode: SystemAudioMode = .automatic
        var recordSystemAudio = false
        var diarizationEnabled = true
        /// 小音量除外のON/OFF。しきい値は次回設定のまま
        var exclusionEnabled = false
        /// 議事録の絶対パス。nilは指定なし
        var minutesPath: String?
        /// 選んだ予約のid。議事録を別のパスへ変えた場合と「指定しない」はnil。
        var nextMeetingID: UUID?
        /// 自動送信の宛先の枠。nilは「送らない」
        var scheduleSlot: Int?
        /// 会議で固定する手動送信の宛先。nilは「指定しない」。
        var manualSlot: Int?
        /// 宛先があるときの自動送信の指定
        var schedule: AIScheduleOptions?
    }

    let window: NSWindow
    var onStart: ((Options) -> Void)?
    var onCancel: (() -> Void)?
    /// 「区別する」を選んだ時点で話者モデルを先読みする。次回設定は書き換えない
    var onDiarizationPreload: (() -> Void)?
    /// 予約だけを店から削除する。失敗してもシートの候補は取り除く。
    var onRemoveNextMeeting: ((UUID) -> Void)?

    private let profiles: [ResolvedAIConfig]
    private let avatars = AvatarStore()
    /// 宛先ごとの下書き。選び直しても、その宛先で書いた文面と間隔を覚える
    private var drafts: [Int: AIScheduleSheet.Draft] = [:]
    /// 表示中の宛先。nilは「送らない」
    private(set) var selectedSlot: Int?
    private(set) var selectedManualSlot: Int?
    private let defaultManualSlot: Int?
    static let manualDefaultsKey = "KikigakiManualDestination"
    private(set) var nextMeetings: [NextMeeting]
    private var selectedNextMeetingID: UUID?
    private(set) var nextButtons: [NSButton] = []
    private(set) var nextRemoveButtons: [NSButton] = []
    private(set) var nextTitles: [NSTextField] = []
    private(set) var nextDetails: [NSTextField] = []
    private let nextChoices = NSStackView()

    private let stack = NSStackView()
    /// 本文の自然な高さとシートの高さを分け、画面下端で止めたぶんをスクロールする。
    private let bodyScroll = NSScrollView()
    /// 全宛先とエラー表示を含めて確保する本文高。表示中は窓のサイズを変更しない。
    private var reservedBodyHeight: CGFloat = 0
    private var fixedContentHeight: CGFloat?
    private var detailsSlot: Int?
    static let systemAudioDefaultsKey = "KikigakiSystemAudioMode"
    let systemAudioAutomatic = NSButton(radioButtonWithTitle: "自動(いまは取り込まない)", target: nil, action: nil)
    let systemAudioInclude = NSButton(radioButtonWithTitle: "取り込む", target: nil, action: nil)
    let systemAudioExclude = NSButton(radioButtonWithTitle: "取り込まない", target: nil, action: nil)
    private let outputKind: () -> AudioOutputKind
    private let microphoneName: () -> String
    let microphoneLabel = Washi.label(size: 13)
    private var outputTimer: Timer?
    let diarizeOn = NSButton(radioButtonWithTitle: "区別する(最大8人)", target: nil, action: nil)
    let diarizeOff = NSButton(radioButtonWithTitle: "区別しない", target: nil, action: nil)
    let exclusionSwitch = NSSwitch()
    private let exclusionText = Washi.label(size: 13)
    let minutesBox = StartSheetPathBox()
    let historyButton = NSButton()
    /// 最近表示できた議事録。新しい順
    private(set) var historyPaths: [String] = []
    /// 議事録の指定が読めないときだけ出す1行。説明文は置かない
    private let minutesHint = Washi.label(size: 11, color: Washi.gold)
    private let aiSection = NSStackView()
    let destination = StartSheetDestinationButton()
    let manualDestination = StartSheetDestinationButton()
    let interval = NSPopUpButton()
    private let cwdLabel = Washi.label(size: 12, color: Washi.muted)
    let editor = AIQuestionEditor()
    let alwaysPromptHint = AIAlwaysPromptHint()
    let manualAlwaysPromptHint = AIAlwaysPromptHint()
    let work = NSButton(checkboxWithTitle: "作業を許可する(ファイル編集・コマンド実行)", target: nil, action: nil)
    let final = NSButton(checkboxWithTitle: "録音停止時に最後の1回を送る", target: nil, action: nil)
    let aiDetails = NSStackView()
    /// 開始は録音ボタンと同じ朱の面にする。取消と並べても「始めるもの」が一目で分かる。
    let startButton = WashiActionButton()

    init(profiles: [ResolvedAIConfig], diarizationEnabled: Bool, exclusion: AudioExclusion,
         minutesPath: String? = nil, minutesHistory: [String] = [],
         nextMeetings: [NextMeeting] = [],
         defaults: UserDefaults = .standard,
         systemAudioMode: SystemAudioMode = .automatic,
         outputKind: @escaping () -> AudioOutputKind = { .unknown },
         microphoneName: @escaping () -> String = { MicrophoneDevice.currentName }) {
        self.profiles = profiles
        if let remembered = defaults.string(forKey: Self.manualDefaultsKey) {
            defaultManualSlot = remembered.isEmpty ? nil : profiles.first(where: { $0.name == remembered })?.slot ?? profiles.first?.slot
        } else { defaultManualSlot = profiles.first?.slot }
        self.nextMeetings = NextMeetings(nextMeetings).candidates
        self.outputKind = outputKind
        self.microphoneName = microphoneName
        window = StartSheetWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = Washi.paper
        avatars.onChange = { [weak self] in
            self?.refreshDestinationImages()
            self?.refreshNextImages()
        }

        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        Washi.surface(stack, color: Washi.paper)
        // 幅は固定し、高さだけを中身に合わせる。議事録の長いパスがそのまま読める幅にする。
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true

        let rows = NSStackView()
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 0

        if !self.nextMeetings.isEmpty {
            let choices = buildNextMeetings()
            let nextRow = row("次の会議", choices)
            // 横向き・上揃えのstackは下側のedgeInsetsを高さへ含めない。
            // 複数行の値が仕切り線まで伸びないよう、上下10ptを高さでも保証する。
            nextRow.heightAnchor.constraint(greaterThanOrEqualTo: choices.heightAnchor, constant: 20).isActive = true
            add(nextRow, to: rows)
            add(separator(), to: rows)
        }

        // 前回値の保存は開始確定側だけが行う。シート内の選び直しと取消は記憶しない。
        let audioRadios = [systemAudioAutomatic, systemAudioInclude, systemAudioExclude]
        for radio in audioRadios { radio.target = self; radio.action = #selector(systemAudioChanged) }
        selectSystemAudio(systemAudioMode)
        refreshSystemAudioOutput()
        let audioChoices = NSStackView(views: audioRadios)
        audioChoices.orientation = .horizontal; audioChoices.spacing = 14
        add(row("システム音声", audioChoices), to: rows)
        add(separator(), to: rows)
        microphoneLabel.usesSingleLineMode = true
        microphoneLabel.lineBreakMode = .byTruncatingTail
        microphoneLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        microphoneLabel.setAccessibilityLabel("マイク")
        refreshMicrophone()
        add(row("マイク", microphoneLabel), to: rows)
        add(separator(), to: rows)

        // 話者判別。録音開始で会議へ固定するので、始めてからは変えられない。
        for radio in [diarizeOn, diarizeOff] { radio.target = self; radio.action = #selector(diarizationChanged) }
        diarizeOn.state = diarizationEnabled ? .on : .off
        diarizeOff.state = diarizationEnabled ? .off : .on
        let radios = NSStackView(views: [diarizeOn, diarizeOff])
        radios.orientation = .horizontal; radios.spacing = 20
        add(row("話者判別", radios), to: rows)

        // 小音量除外はON/OFFだけ。しきい値は音を聞いて決めるものなので、録音中の「話者」ポップアップに残す。
        add(separator(), to: rows)
        exclusionSwitch.controlSize = .small
        exclusionSwitch.state = exclusion.enabled ? .on : .off
        exclusionSwitch.target = self; exclusionSwitch.action = #selector(exclusionChanged)
        exclusionSwitch.setAccessibilityLabel("小音量発話を除外")
        exclusionText.stringValue = String(format: "%.0f dBFS未満を除外", exclusion.thresholdDBFS)
        let exclusionRow = NSStackView(views: [exclusionSwitch, exclusionText])
        exclusionRow.orientation = .horizontal; exclusionRow.spacing = 10; exclusionRow.alignment = .centerY
        add(row("小音量除外", exclusionRow), to: rows)
        applyExclusionState()

        // 議事録。指定すると開始と同時に右のペインへ出す。
        add(separator(), to: rows)
        minutesBox.font = .systemFont(ofSize: 12)
        minutesBox.placeholderString = "議事録の絶対パス"
        // 1行で横に流す。折り返すと欄の高さが変わらず2行目が見えなくなる。
        minutesBox.usesSingleLineMode = true
        minutesBox.lineBreakMode = .byClipping
        minutesBox.cell?.isScrollable = true
        minutesBox.cell?.wraps = false
        minutesBox.setAccessibilityLabel("議事録のパス")
        minutesBox.stringValue = minutesPath ?? ""
        minutesBox.onDrop = { [weak self] path in self?.setMinutesPath(path) }
        // 欄はボタンを除いた幅いっぱいに伸ばす。
        minutesBox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        minutesBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // 履歴はNSComboBoxの一覧ではなく自前のメニューで出す。一覧は1行に切り詰めるので、
        // 長い絶対パスの肝心なファイル名から欠ける。ファイル名とディレクトリの2行にする。
        historyPaths = minutesHistory
        historyButton.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "最近の議事録")
        historyButton.bezelStyle = .rounded; historyButton.imagePosition = .imageOnly
        historyButton.target = self; historyButton.action = #selector(showHistory)
        historyButton.isEnabled = !minutesHistory.isEmpty
        historyButton.setAccessibilityLabel("最近の議事録")
        historyButton.setContentHuggingPriority(.required, for: .horizontal)
        let choose = NSButton(title: "ファイルを選ぶ…", target: self, action: #selector(chooseMinutes))
        choose.bezelStyle = .rounded
        choose.setContentHuggingPriority(.required, for: .horizontal)
        let minutesRow = NSStackView(views: [minutesBox, historyButton, choose])
        minutesRow.orientation = .horizontal; minutesRow.spacing = 8; minutesRow.distribution = .fill
        minutesHint.isHidden = true
        add(row("議事録", column([minutesRow, minutesHint], spacing: 4)), to: rows)

        // 自動送信。`[[ai]]` が無ければ区画ごと出さない。
        if !profiles.isEmpty {
            add(separator(), to: rows)
            let automaticRow = row("自動送信", buildAISection())
            add(automaticRow, to: rows)
            // 複数行の自動送信の末尾にも、次の区切り線まで10ptの余白を取る。
            rows.setCustomSpacing(10, after: automaticRow)
            manualDestination.font = .systemFont(ofSize: 13)
            manualDestination.setAccessibilityLabel("手動送信の宛先")
            manualDestination.target = self; manualDestination.action = #selector(manualDestinationChanged)
            add(separator(), to: rows)
            // 指示が無い宛先でも1行分を残し、選び直しても操作部の位置を変えない。
            let manualChoices = column([manualDestination, manualAlwaysPromptHint], spacing: 6, detachesHiddenViews: false)
            add(row("手動送信", manualChoices), to: rows)
            rebuildDestinationMenu(manual: true)
        }
        stack.addArrangedSubview(Washi.label("録音を開始", size: 17, weight: .semibold))
        stack.addArrangedSubview(rows)

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        startButton.title = "開始 ⏎"; startButton.emphasis = .primary; startButton.isBordered = false
        startButton.target = self; startButton.action = #selector(startPressed)
        startButton.keyEquivalent = "\r"
        startButton.focusRingType = .none
        startButton.setAccessibilityLabel("録音を開始")
        startButton.refreshStyle()
        startButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        startButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        let actions = NSStackView(views: [NSView(), cancel, startButton])
        actions.orientation = .horizontal; actions.spacing = 12
        stack.addArrangedSubview(actions)
        for view in [rows, actions] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        bodyScroll.borderType = .noBorder
        bodyScroll.drawsBackground = false
        bodyScroll.scrollerStyle = .overlay
        bodyScroll.hasHorizontalScroller = false
        bodyScroll.documentView = stack
        window.contentView = bodyScroll
        (window as? StartSheetWindow)?.onDismiss = { [weak self] in self?.cancelPressed() }
        (window as? StartSheetWindow)?.onCommandReturn = { [weak self] in self?.startPressed() }
        editor.onSubmit = { [weak self] in self?.startPressed() }
        editor.onCancel = { [weak self] in self?.cancelPressed() }
        minutesHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // 「送らない」で開いても、最初の宛先の下書きを無効表示する。
        selectDestination(profiles.first?.slot)
        selectDestination(profiles.first(where: \.autoStart)?.slot)
        selectManualDestination(defaultManualSlot)
        if !self.nextMeetings.isEmpty { selectNextMeeting(at: 0) }
        reserveBodyHeight()
        fit()
    }

    // MARK: - 組み立て

    private var nextImages: [NSImageView] = []

    /// 全候補を見せる。ポップアップへ隠すと、次の議事録の取り違えを開始前に見つけにくい。
    private func buildNextMeetings() -> NSView {
        for view in nextChoices.arrangedSubviews {
            nextChoices.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        nextButtons = []; nextRemoveButtons = []; nextTitles = []; nextDetails = []; nextImages = []
        var choices: [NSView] = []
        for (index, meeting) in nextMeetings.enumerated() {
            let title = Washi.label(Self.nextTitle(meeting), size: 13)
            title.lineBreakMode = .byTruncatingTail
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let profile = meeting.ai.flatMap { name in profiles.first { $0.name == name } }
            let unknown = (meeting.ai != nil && profile == nil)
                || (meeting.manual != nil && !profiles.contains { $0.name == meeting.manual })
            let missing = !FileManager.default.fileExists(atPath: meeting.minutesPath)
            var details = [meeting.ai ?? "送らない"]
            if let manual = meeting.manual { details.append("手動: " + manual) }
            details.append((meeting.minutesPath as NSString).lastPathComponent)
            if unknown { details.append("設定にありません") }
            if missing { details.append("見つかりません") }
            let label = Washi.label(details.joined(separator: " · "), size: 11,
                                   color: unknown || missing ? Washi.gold : Washi.muted)
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let image = NSImageView()
            image.widthAnchor.constraint(equalToConstant: 16).isActive = true
            image.heightAnchor.constraint(equalToConstant: 16).isActive = true
            image.isHidden = meeting.ai == nil
            nextImages.append(image)
            let detailRow = NSStackView(views: [image, label])
            detailRow.orientation = .horizontal; detailRow.alignment = .centerY; detailRow.spacing = 5
            let text = column([title, detailRow], spacing: 2)
            let radio = NSButton(radioButtonWithTitle: "", target: self, action: #selector(nextMeetingChanged(_:)))
            radio.tag = index
            radio.setAccessibilityLabel(title.stringValue + " " + label.stringValue)
            radio.setContentHuggingPriority(.required, for: .horizontal)
            let remove = NextMeetingRemoveButton()
            remove.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "この予約を削除")
            remove.imagePosition = .imageOnly; remove.imageScaling = .scaleProportionallyDown
            remove.isBordered = false; remove.contentTintColor = Washi.muted
            remove.toolTip = "この予約を削除"; remove.setAccessibilityLabel("この予約を削除")
            remove.target = self; remove.action = #selector(removeNextMeeting(_:)); remove.isHidden = true
            // ×を隠しても置き場を残す。ホバーで題の幅やシート高が変わらないようにする。
            let removeSlot = NSView()
            removeSlot.widthAnchor.constraint(equalToConstant: 16).isActive = true
            removeSlot.heightAnchor.constraint(equalToConstant: 16).isActive = true
            removeSlot.addSubview(remove); remove.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                remove.centerXAnchor.constraint(equalTo: removeSlot.centerXAnchor),
                remove.centerYAnchor.constraint(equalTo: removeSlot.centerYAnchor),
                remove.widthAnchor.constraint(equalToConstant: 16),
                remove.heightAnchor.constraint(equalToConstant: 16)
            ])
            let choice = NextMeetingChoiceRow(views: [radio, text, removeSlot])
            choice.removeButton = remove
            choice.onChoose = { [weak self] in self?.selectNextMeeting(at: index) }
            choice.orientation = .horizontal; choice.alignment = .top; choice.spacing = 6
            text.setContentHuggingPriority(.defaultLow, for: .horizontal)
            removeSlot.trailingAnchor.constraint(equalTo: choice.trailingAnchor).isActive = true
            choice.toolTip = meeting.minutesPath
            choices.append(choice)
            nextRemoveButtons.append(remove)
            nextButtons.append(radio); nextTitles.append(title); nextDetails.append(label)
        }
        let none = NSButton(radioButtonWithTitle: "指定しない", target: self, action: #selector(nextMeetingChanged(_:)))
        none.tag = nextMeetings.count; nextButtons.append(none)
        choices.append(none)
        refreshNextImages()
        nextChoices.orientation = .vertical; nextChoices.alignment = .leading; nextChoices.spacing = 8
        for view in choices { add(view, to: nextChoices) }
        return nextChoices
    }
    private func refreshNextImages() {
        for (index, image) in nextImages.enumerated() {
            guard let name = nextMeetings[index].ai else { continue }
            image.image = AIProfileAvatar.image(name: name,
                source: profiles.first(where: { $0.name == name })?.avatar, store: avatars)
        }
    }
    /// 議事録は大きくなり得るので、話者候補と同じく先頭64KiBだけ読む。
    static func nextTitle(_ meeting: NextMeeting) -> String {
        let url = URL(fileURLWithPath: meeting.minutesPath)
        var title = meeting.title
        if title == nil, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
           let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let bytes = try? handle.read(upToCount: 64 * 1024) {
                title = String(decoding: bytes, as: UTF8.self).split(separator: "\n")
                    .first(where: { $0.hasPrefix("# ") })
                    .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines) }
                if title?.isEmpty == true { title = nil }
            }
        }
        let time = meeting.at.map { String($0.suffix(5)) + " " } ?? ""
        return time + (title ?? url.lastPathComponent)
    }
    @objc func nextMeetingChanged(_ sender: NSButton) { selectNextMeeting(at: sender.tag) }

    @objc func removeNextMeeting(_ sender: NSButton) {
        guard let index = nextRemoveButtons.firstIndex(where: { $0 === sender }) else { return }
        let id = nextMeetings[index].id
        (sender as? NextMeetingRemoveButton)?.afterPress { self.removeNextMeeting(id: id) }
    }

    private func removeNextMeeting(id: UUID) {
        guard let index = nextMeetings.firstIndex(where: { $0.id == id }) else { return }
        let meeting = nextMeetings.remove(at: index)
        let wasSelected = selectedNextMeetingID == meeting.id
        // 最後の1件を消しても「指定しない」は残す。選び直した状態を見せ、区画を急に消さない。
        _ = buildNextMeetings()
        if wasSelected {
            selectNextMeeting(at: 0)
        } else {
            // 未選択の候補を消しても、議事録や宛先の手編集は保持する。
            let selected = nextMeetings.firstIndex(where: { $0.id == selectedNextMeetingID }) ?? nextMeetings.count
            for (offset, button) in nextButtons.enumerated() { button.state = offset == selected ? .on : .off }
        }
        // 初回に確保した高さを使う。候補が減ってもreserveBodyHeightで測り直さない。
        fit()
        onRemoveNextMeeting?(meeting.id)
    }

    func selectNextMeeting(at index: Int) {
        guard nextButtons.indices.contains(index) else { return }
        for (offset, button) in nextButtons.enumerated() { button.state = offset == index ? .on : .off }
        if let previous = selectedSlot { drafts[previous] = currentDraft }
        if nextMeetings.indices.contains(index) {
            let meeting = nextMeetings[index]
            selectedNextMeetingID = meeting.id
            minutesBox.stringValue = meeting.minutesPath
            selectDestination(meeting.ai.flatMap { name in profiles.first { $0.name == name }?.slot })
            selectManualDestination(meeting.manual.flatMap { name in profiles.first { $0.name == name }?.slot } ?? defaultManualSlot)
        } else {
            selectedNextMeetingID = nil
            minutesBox.stringValue = ""
            selectDestination(profiles.first(where: \.autoStart)?.slot)
            selectManualDestination(defaultManualSlot)
        }
        showMinutesHint(nil)
    }

    private func add(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    private func row(_ title: String, _ value: NSView) -> NSStackView {
        let label = Washi.label(title, size: 12, weight: .semibold)
        label.widthAnchor.constraint(equalToConstant: 68).isActive = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [label, value])
        stack.orientation = .horizontal; stack.alignment = .top; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        value.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // 値の側は見出しの右から右端まで使う。パスや依頼を縮めない。
        value.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        return stack
    }
    private func column(_ views: [NSView], spacing: CGFloat, detachesHiddenViews: Bool = true) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        stack.detachesHiddenViews = detachesHiddenViews
        for view in views { add(view, to: stack) }
        return stack
    }
    private func separator() -> NSView {
        let line = NSView()
        Washi.surface(line, color: Washi.rule)
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func buildAISection() -> NSView {
        destination.target = self; destination.action = #selector(destinationChanged)
        destination.setAccessibilityLabel("自動送信の宛先")
        destination.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        destination.setContentHuggingPriority(.defaultLow, for: .horizontal)
        (destination.cell as? NSPopUpButtonCell)?.usesItemFromMenu = false
        interval.target = self; interval.action = #selector(draftChanged)
        interval.setAccessibilityLabel("送信間隔")
        interval.setContentHuggingPriority(.required, for: .horizontal)
        let intervalLabel = Washi.label("間隔", size: 13)
        intervalLabel.setContentHuggingPriority(.required, for: .horizontal)
        let intervalRow = NSStackView(views: [intervalLabel, interval])
        intervalRow.orientation = .horizontal; intervalRow.spacing = 8; intervalRow.alignment = .centerY

        // 作業ディレクトリ。フォルダの記号を添え、パスだけの行に見えないようにする。
        cwdLabel.lineBreakMode = .byTruncatingHead
        cwdLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let folder = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: "作業ディレクトリ") ?? NSImage())
        folder.contentTintColor = Washi.muted
        folder.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        folder.setContentHuggingPriority(.required, for: .horizontal)
        let cwdRow = NSStackView(views: [folder, cwdLabel])
        cwdRow.orientation = .horizontal; cwdRow.spacing = 5; cwdRow.alignment = .centerY

        // プロンプトは畳まず、幅いっぱいの欄でそのまま書ける。長い依頼でも中を読めるよう数行ぶん見せる。
        editor.font = .systemFont(ofSize: 12); editor.textColor = Washi.ink
        editor.backgroundColor = .white; editor.isRichText = false; editor.delegate = self
        editor.textContainerInset = NSSize(width: 4, height: 5)
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.placeholder = "毎回送る依頼"
        editor.setAccessibilityLabel("毎回送るプロンプト")
        editor.frame = NSRect(x: 0, y: 0, width: 400, height: Self.promptHeight)
        let scroll = NSScrollView(); scroll.documentView = editor; scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: Self.promptHeight).isActive = true

        for control in [work, final] { control.target = self; control.action = #selector(draftChanged) }
        aiDetails.orientation = .vertical; aiDetails.alignment = .leading; aiDetails.spacing = 6
        for view in [cwdRow, scroll, alwaysPromptHint] { add(view, to: aiDetails) }
        aiDetails.addArrangedSubview(intervalRow)
        aiDetails.addArrangedSubview(work)
        aiDetails.addArrangedSubview(final)
        aiSection.orientation = .vertical; aiSection.alignment = .leading; aiSection.spacing = 6
        add(destination, to: aiSection); add(aiDetails, to: aiSection)
        rebuildDestinationMenu()
        return aiSection
    }
    /// プロンプト欄の高さ。12ptの文字で6行ほど見える。
    static let promptHeight: CGFloat = 100

    // MARK: - 宛先

    /// 宛先メニュー。行はavatar・name・cli+model+effort・プロンプトの3行で、「送らない」だけ1行。
    /// プロンプトも並べるのは、同じ名前と型のプロファイルを依頼の中身で見分けるため。
    private func rebuildDestinationMenu(manual: Bool = false) {
        let menu = NSMenu()
        let none = NSMenuItem(title: manual ? "指定しない" : "送らない", action: nil, keyEquivalent: "")
        none.tag = 0
        menu.addItem(none)
        for profile in profiles {
            let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
            item.tag = profile.slot
            let title = NSMutableAttributedString(string: profile.name,
                attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
            if profile.identifySpeakers {
                // 名前だけを先に縮め、一覧でも札を欠かさない。標準メニューの選択操作はそのまま使う。
                let name = SpeakerEstimationChip.truncated(profile.name, font: .systemFont(ofSize: 13, weight: .semibold),
                    width: 440 - SpeakerEstimationChip.size.width - 6)
                title.mutableString.setString(name)
                title.append(NSAttributedString(string: "  "))
                title.append(SpeakerEstimationChip.attachment(for: item))
                item.setAccessibilityLabel(profile.name + " 話者名を推定 " + Self.meta(profile))
                item.toolTip = profile.name + " 話者名を推定"
            }
            title.append(NSAttributedString(string: "\n" + Self.meta(profile), attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            if let prompt = Self.promptLine(profile.board.map { BoardPrompt.summary(heading: $0) } ?? profile.initialPrompt) {
                title.append(NSAttributedString(string: "\n" + prompt, attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            }
            item.attributedTitle = title
            menu.addItem(item)
        }
        (manual ? manualDestination : destination).menu = menu
        refreshDestinationImages()
    }
    private func refreshDestinationImages() {
        for profile in profiles {
            for popup in [destination, manualDestination] {
                popup.menu?.items.first(where: { $0.tag == profile.slot })?.image =
                    AIProfileAvatar.image(name: profile.name, source: profile.avatar, store: avatars)
            }
        }
        refreshDestinationTitle()
        refreshManualDestinationTitle()
    }
    @objc private func manualDestinationChanged() {
        selectManualDestination(manualDestination.selectedTag() == 0 ? nil : manualDestination.selectedTag())
    }
    func selectManualDestination(_ slot: Int?) {
        selectedManualSlot = slot
        manualDestination.selectItem(withTag: slot ?? 0)
        manualAlwaysPromptHint.update(profiles.first(where: { $0.slot == slot })?.alwaysPrompt ?? "")
        refreshManualDestinationTitle()
    }
    private func refreshManualDestinationTitle() {
        let item = NSMenuItem(title: "指定しない", action: nil, keyEquivalent: "")
        if let profile = profiles.first(where: { $0.slot == selectedManualSlot }) {
            item.title = profile.name + AIModelLabel.separator + Self.meta(profile)
            item.image = AIProfileAvatar.image(name: profile.name, source: profile.avatar, store: avatars)
        }
        (manualDestination.cell as? NSPopUpButtonCell)?.menuItem = item
        manualDestination.showsSpeakerEstimation = profiles.first { $0.slot == selectedManualSlot }?.identifySpeakers == true
        manualDestination.setAccessibilityValue(item.title + (manualDestination.showsSpeakerEstimation ? " 話者名を推定" : ""))
        manualDestination.toolTip = item.title
        manualDestination.needsDisplay = true
    }
    /// 閉じた状態の1行。メニューの2行をそのまま出すとボタンが伸びるので、別の項目を描く。
    private func refreshDestinationTitle() {
        let item = NSMenuItem(title: "送らない", action: nil, keyEquivalent: "")
        if let slot = selectedSlot, let profile = profiles.first(where: { $0.slot == slot }) {
            item.title = profile.name + AIModelLabel.separator + Self.meta(profile)
            item.image = AIProfileAvatar.image(name: profile.name, source: profile.avatar, store: avatars)
        }
        (destination.cell as? NSPopUpButtonCell)?.menuItem = item
        destination.showsSpeakerEstimation = profiles.first { $0.slot == selectedSlot }?.identifySpeakers == true
        destination.setAccessibilityValue(item.title + (destination.showsSpeakerEstimation ? " 話者名を推定" : ""))
        destination.toolTip = item.title
        destination.needsDisplay = true
    }
    /// 「Codex · gpt-5.4 (high)」。未設定の項目は黙って飛ばす。
    /// effortは括弧でモデルに掛ける。`·` で並べると独立した項目に見え、何のhighか読めない。
    static func meta(_ profile: ResolvedAIConfig) -> String {
        var text = [profile.cli.rawValue.capitalized, profile.model]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: AIModelLabel.separator)
        if let effort = profile.effort, !effort.isEmpty { text += " (\(effort))" }
        return text
    }
    /// メニューへ載せるプロンプトの1行。改行は空白にし、長ければ切る。空なら載せない。
    static func promptLine(_ prompt: String, limit: Int = 48) -> String? {
        let flat = prompt.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { return nil }
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
    /// 閉じた宛先ポップアップに出ている1行。
    var destinationTitle: String { (destination.cell as? NSPopUpButtonCell)?.menuItem?.title ?? "" }

    private func draft(for slot: Int) -> AIScheduleSheet.Draft {
        if let saved = drafts[slot] { return saved }
        guard let profile = profiles.first(where: { $0.slot == slot }) else {
            return .init(prompt: "", minutes: 3, workAllowed: true)
        }
        return .init(prompt: profile.scheduledPrompt, minutes: profile.autoIntervalMinutes,
                     workAllowed: profile.allowWork, sendFinal: true)
    }
    private var currentDraft: AIScheduleSheet.Draft {
        .init(prompt: editor.string, minutes: interval.selectedTag(),
              workAllowed: work.state == .on, sendFinal: final.state == .on)
    }
    private func selectDestination(_ slot: Int?) {
        selectedSlot = slot
        destination.selectItem(withTag: slot ?? 0)
        alwaysPromptHint.update(profiles.first(where: { $0.slot == slot })?.alwaysPrompt ?? "")
        // 高さを保ったまま、送らない設定は薄くして操作を止める。
        aiDetails.alphaValue = slot == nil ? 0.4 : 1
        for control in [interval, work, final] { control.isEnabled = slot != nil }
        editor.isSelectable = slot != nil
        guard let slot, let profile = profiles.first(where: { $0.slot == slot }) else {
            editor.isEditable = false
            refreshPromptState(); refreshDestinationTitle(); return
        }
        detailsSlot = slot
        let draft = draft(for: slot)
        editor.isEditable = profile.board == nil
        cwdLabel.stringValue = Self.shortPath(profile.cwd)
        editor.unmarkText(); editor.string = draft.prompt
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.needsDisplay = true
        interval.removeAllItems()
        for minute in AIScheduleOptions.minuteChoices(including: draft.minutes) {
            interval.addItem(withTitle: "\(minute)分"); interval.lastItem?.tag = minute
        }
        interval.selectItem(withTag: draft.minutes)
        work.state = draft.workAllowed ? .on : .off
        final.state = draft.sendFinal ? .on : .off
        refreshPromptState()
        refreshDestinationTitle()
    }
    /// 依頼が空のままでは自動送信を始められない。録音そのものは止めず、理由はツールチップだけに出す。
    private func refreshPromptState() {
        let empty = editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        startButton.toolTip = selectedSlot != nil && empty ? "依頼が空のため、自動送信は始めません" : nil
    }
    private static func shortPath(_ url: URL) -> String { shortPath(url.path) }
    static func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - 操作

    @objc private func diarizationChanged() {
        if diarizeOn.state == .on { onDiarizationPreload?() }
    }
    @objc private func exclusionChanged() { applyExclusionState() }
    /// OFFのときはしきい値を薄墨にし、効いていないことを色で見せる。
    private func applyExclusionState() {
        exclusionText.textColor = exclusionSwitch.state == .on ? Washi.ink : Washi.muted
    }
    /// ポップアップで選び直したとき。表示中の宛先の下書きを先に保存する。
    @objc func destinationChanged() {
        if let previous = selectedSlot { drafts[previous] = currentDraft }
        let tag = destination.selectedTag()
        selectDestination(tag == 0 ? nil : tag)
        fit()
    }
    @objc private func draftChanged() {
        if let slot = selectedSlot { drafts[slot] = currentDraft }
    }
    func textDidChange(_ notification: Notification) {
        editor.needsDisplay = true; draftChanged(); refreshPromptState()
    }
    @objc private func chooseMinutes() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.setMinutesPath(url.path)
        }
    }

    /// 履歴のメニュー。1項目はファイル名(墨)とディレクトリ(薄墨)の2行で、`~` に縮めたパスを出す。
    func historyMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, path) in historyPaths.enumerated() {
            let item = NSMenuItem(title: path, action: #selector(historyChosen(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.toolTip = path
            let title = NSMutableAttributedString(string: (path as NSString).lastPathComponent,
                attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
            title.append(NSAttributedString(string: "\n" + Self.shortPath((path as NSString).deletingLastPathComponent),
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = title
            menu.addItem(item)
        }
        return menu
    }
    @objc private func showHistory() {
        let menu = historyMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: historyButton.bounds.height + 4), in: historyButton)
    }
    @objc private func historyChosen(_ sender: NSMenuItem) {
        guard historyPaths.indices.contains(sender.tag) else { return }
        setMinutesPath(historyPaths[sender.tag])
    }

    /// ファイル選択・履歴・ドロップから、開いている最中に議事録を差し替える入口。
    func setMinutesPath(_ path: String) {
        minutesBox.stringValue = path
        showMinutesHint(nil)
    }
    /// パス欄の下の1行。指定が読めないときだけ出し、普段は空ける。
    /// 議事録の指定に問題があるとき、パス欄は触らず理由を出す。
    func showMinutesHint(_ problem: String?) {
        minutesHint.stringValue = problem ?? ""
        minutesHint.isHidden = problem == nil
        fit()
    }
    /// パス欄の下にいま出ている1行。
    var minutesHintText: String { minutesHint.stringValue }

    /// 表示前に全宛先と議事録のエラー行を測る。選択中の下書きは測定後に戻す。
    private func reserveBodyHeight() {
        let selected = selectedSlot
        let displayed = detailsSlot
        if let displayed { drafts[displayed] = currentDraft }
        let savedDrafts = drafts
        let hint = minutesHint.stringValue
        let hidden = minutesHint.isHidden
        minutesHint.stringValue = "議事録は絶対パスの.mdを指定してください"
        minutesHint.isHidden = false
        reservedBodyHeight = 0
        for slot in [Int?](profiles.map { $0.slot }) + [nil] {
            selectDestination(slot)
            stack.layoutSubtreeIfNeeded()
            reservedBodyHeight = max(reservedBodyHeight, ceil(stack.fittingSize.height))
        }
        drafts = savedDrafts
        if let displayed { selectDestination(displayed) }
        selectDestination(selected)
        minutesHint.stringValue = hint
        minutesHint.isHidden = hidden
    }

    /// 本文だけを再配置する。表示中のシート高は変えず、超過分をスクロールする。
    private func fit() {
        stack.layoutSubtreeIfNeeded()
        let bodySize = NSSize(width: Self.width, height: max(reservedBodyHeight, ceil(stack.fittingSize.height)))
        stack.setFrameSize(bodySize)
        if window.sheetParent == nil {
            window.setContentSize(NSSize(width: Self.width, height: fixedContentHeight ?? bodySize.height))
        }
        bodyScroll.hasVerticalScroller = bodySize.height > bodyScroll.contentSize.height
        bodyScroll.layoutSubtreeIfNeeded()
        stack.layoutSubtreeIfNeeded()
        // 非反転のスタックは上端がmaxY。高さの変更後も本文の先頭を見せる。
        stack.scroll(NSPoint(x: 0, y: max(0, bodySize.height - bodyScroll.contentSize.height)))
        bodyScroll.reflectScrolledClipView(bodyScroll.contentView)
    }
    /// シートの幅。既定のウィンドウ(600pt)より広いが、議事録の絶対パスを縮めずに読めることを優先する。
    static let width: CGFloat = 640
    static let screenMargin: CGFloat = 20

    func present(on parent: NSWindow) {
        guard window.sheetParent == nil else { focus(); return }
        reserveBodyHeight()
        let visibleFrame = (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame
        fixedContentHeight = min(reservedBodyHeight, max(1, floor(visibleFrame.height - Self.screenMargin * 2)))
        fit()
        // 開いているシートだけ追従する。開始後の会議の音源モードは固定する。
        outputTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSystemAudioOutput()
                self?.refreshMicrophone()
            }
        }
        parent.beginSheet(window)
        (window as? AIQuestionWindow)?.monitorOutsideClicks()
        window.makeFirstResponder(nextMeetings.isEmpty ? nil : startButton)
    }
    func close() {
        outputTimer?.invalidate(); outputTimer = nil
        // 親を閉じる経路でも、ファイル選択パネルを残さない。
        if let panel = window.attachedSheet { window.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }
        if let parent = window.sheetParent { parent.endSheet(window) }
        window.orderOut(nil)
        fixedContentHeight = nil
    }
    func focus() { (window.attachedSheet ?? window).makeKeyAndOrderFront(nil) }

    /// パス欄の入力。確定を待たず、いま書かれている文字を読む。
    private var minutesInput: String? {
        let input = minutesBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return input.isEmpty ? nil : (input as NSString).expandingTildeInPath
    }

    /// 画面の値。開始できない入力があれば nil。
    var options: Options? {
        var result = Options(diarizationEnabled: diarizeOn.state == .on, exclusionEnabled: exclusionSwitch.state == .on)
        result.systemAudioMode = selectedSystemAudioMode
        result.recordSystemAudio = selectedSystemAudioMode.includes(outputKind())
        result.manualSlot = selectedManualSlot
        if let path = minutesInput {
            guard (try? MinutesPath.validate(path)) != nil else { return nil }
            result.minutesPath = path
        }
        // 最終的な議事録パスも選んだ予約と一致するときだけ、その1件を使ったとみなす。
        // symlinkの解決や実在は判定へ混ぜない。「指定しない」からの手入力も予約を使わない。
        if let id = selectedNextMeetingID,
           let meeting = nextMeetings.first(where: { $0.id == id }),
           meeting.minutesPath == result.minutesPath {
            result.nextMeetingID = id
        }
        if let slot = selectedSlot {
            let draft = currentDraft
            if profiles.first(where: { $0.slot == slot })?.boardStartIssue(minutesPath: minutesInput) != nil { return nil }
            // 依頼が空・間隔が不正なら自動送信は始めない。録音そのものは始める。
            if let options = try? AIScheduleOptions(prompt: draft.prompt, interval: Double(draft.minutes) * 60,
                                                   workAllowed: draft.workAllowed, sendFinal: draft.sendFinal) {
                result.scheduleSlot = slot
                result.schedule = options
            }
        }
        return result
    }

    @objc func startPressed() {
        guard !editor.hasMarkedText(), !minutesBox.hasMarkedTextForStart else { return }
        guard let value = options else {
            showMinutesHint(minutesInput == nil && selectedSlot.flatMap { slot in profiles.first { $0.slot == slot } }?.board != nil
                ? BoardPrompt.missingLocation : "絶対パスの.mdファイルを指定してください")
            return
        }
        showMinutesHint(nil)
        close()
        onStart?(value)
    }
    @objc func cancelPressed() {
        close()
        onCancel?()
    }

    var selectedSystemAudioMode: SystemAudioMode {
        systemAudioInclude.state == .on ? .include : systemAudioExclude.state == .on ? .exclude : .automatic
    }
    func selectSystemAudio(_ mode: SystemAudioMode) {
        systemAudioAutomatic.state = mode == .automatic ? .on : .off
        systemAudioInclude.state = mode == .include ? .on : .off
        systemAudioExclude.state = mode == .exclude ? .on : .off
    }
    @objc private func systemAudioChanged(_ sender: NSButton) {
        selectSystemAudio(sender === systemAudioInclude ? .include : sender === systemAudioExclude ? .exclude : .automatic)
    }
    func refreshSystemAudioOutput() {
        systemAudioAutomatic.title = SystemAudioMode.automatic.includes(outputKind())
            ? "自動(いまは取り込む)" : "自動(いまは取り込まない)"
    }
    func refreshMicrophone() {
        microphoneLabel.stringValue = microphoneName()
        microphoneLabel.toolTip = microphoneLabel.stringValue
    }
}

/// 削除で外されるボタンと親行を、AppKitの押下処理全体が戻るまで保持する。
/// 次のメインキュー処理はperformClick内のイベントループでも実行され得るため、
/// 実マウスとperformClickの両方でAppKitから戻ってから作り直す保持方式を選ぶ。
@MainActor private final class NextMeetingRemoveButton: NSButton {
    private var handlingPress = false
    private var pendingRemoval: (@MainActor () -> Void)?

    func afterPress(_ removal: @escaping @MainActor () -> Void) {
        if handlingPress { pendingRemoval = removal }
        else { DispatchQueue.main.async { removal() } }
    }

    override func mouseDown(with event: NSEvent) {
        withExtendedLifetime((self, superview?.superview)) {
            handlingPress = true
            super.mouseDown(with: event)
            finishPress()
        }
    }

    override func performClick(_ sender: Any?) {
        withExtendedLifetime((self, superview?.superview)) {
            handlingPress = true
            super.performClick(sender)
            finishPress()
        }
    }

    private func finishPress() {
        handlingPress = false
        let removal = pendingRemoval
        pendingRemoval = nil
        removal?()
    }
}

/// ラジオの標準操作を残し、題・宛先・行内の余白も同じ選択として受ける。
@MainActor private final class NextMeetingChoiceRow: NSStackView {
    var onChoose: (() -> Void)?
    weak var removeButton: NSButton?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { removeButton?.isHidden = false }
    override func mouseExited(with event: NSEvent) { removeButton?.isHidden = true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // ×は行の選択へ転送せず、ラジオと同様にボタン自身へ渡す。
        return hit is NSButton ? hit : self
    }

    override func mouseDown(with event: NSEvent) { onChoose?() }
}

/// ⌘⏎でも開始する。焦点がどこにあっても同じ操作で始められるようにする。
/// 素の⏎は既定ボタンが受け、プロンプト編集中だけ `AIQuestionWindow` が改行へ回す。
final class StartSheetWindow: AIQuestionWindow {
    var onCommandReturn: (() -> Void)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
           event.modifierFlags.intersection([.command, .shift, .control, .option]) == .command,
           (firstResponder as? NSTextView)?.hasMarkedText() != true {
            onCommandReturn?()
            return
        }
        super.sendEvent(event)
    }
}

/// 議事録パス欄。`.md` のファイルをドロップしても指定できる。履歴は隣のボタンのメニューから選ぶ。
final class StartSheetPathBox: NSTextField {
    var onDrop: ((String) -> Void)?
    /// 変換中のEnterで開始しないための確認。
    var hasMarkedTextForStart: Bool { (currentEditor() as? NSTextView)?.hasMarkedText() == true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    func droppedPath(_ pasteboard: NSPasteboard) -> String? {
        guard let url = NSURL(from: pasteboard) as URL?, url.isFileURL,
              url.pathExtension.lowercased() == "md" else { return nil }
        return url.path
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedPath(sender.draggingPasteboard) == nil ? [] : .copy
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedPath(sender.draggingPasteboard) == nil ? [] : .copy
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let path = droppedPath(sender.draggingPasteboard) else { return false }
        onDrop?(path)
        return true
    }
}
