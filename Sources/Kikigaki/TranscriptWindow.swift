import AppKit
import KikigakiCore

/// 会話本文を主役にし、録音操作は上、AIへの受け渡しは下に固定する。
@MainActor
final class TranscriptWindowController: NSWindowController {
    var onRename: ((SpeakerNames) -> Void)?
    var onStartStop: (() -> Void)?
    var onPauseResume: (() -> Void)?
    var onCopy: ((Bool) -> Void)?
    var onRecopy: (() -> Void)?
    var onOpenMarkdown: (() -> Void)?

    private let startStopButton = NSButton(title: "", target: nil, action: nil)
    private let pauseButton = NSButton(title: "一時停止", target: nil, action: nil)
    private let openButton = NSButton(title: "Markdownを開く", target: nil, action: nil)
    private let namesButton = NSButton(title: "話者名…", target: nil, action: nil)
    private let copyButton = NSButton(title: "会話をコピー", target: nil, action: nil)
    private let moreButton = NSButton(title: "再コピー・最初から ▾", target: nil, action: nil)
    private let latestButton = NSButton(title: "最新の発言へ ↓", target: nil, action: nil)
    private let statusDot = NSTextField(labelWithString: "●")
    private let statusLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let rangeLabel = NSTextField(labelWithString: "")
    private let handoffLabel = NSTextField(wrappingLabelWithString: "")
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private var lastText = ""
    private var snapshot = SessionSnapshot()
    private var namesSheet: SpeakerNamesSheet?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 578),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "KIKIGAKI"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 460)
        window.center()
        window.setFrameAutosaveName("KikigakiTranscript")
        super.init(window: window)
        window.contentView = buildContent()
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func apply(_ value: SessionSnapshot) {
        snapshot = value
        // シート中もグローバルショートカットは動く。新会議へ古い名前を反映させない。
        if value.state == .preparing { namesSheet?.cancel() }
        startStopButton.title = value.state == .idle && value.markdownURL != nil ? "新しい録音" : value.state.startStopTitle
        startStopButton.isEnabled = value.state.canStart || value.state.canStop
        pauseButton.title = value.state.pauseResumeTitle
        pauseButton.isEnabled = value.state.canPauseOrResume
        pauseButton.isHidden = value.state == .idle && value.markdownURL != nil
        openButton.isHidden = !(value.state == .idle && value.saved)
        namesButton.isEnabled = value.canShare
        statusLabel.stringValue = value.state == .idle && value.saved ? "保存済み" : value.state.statusLabel
        statusDot.textColor = value.state == .recording ? .systemRed
            : value.state == .paused ? .systemOrange : value.saved ? .systemGreen : .secondaryLabelColor
        elapsedLabel.stringValue = TranscriptRenderer.clock(value.elapsed)
        openButton.toolTip = value.markdownURL?.path
        var message = value.message ?? ""
        // 成功は状態と開くボタンで示す。長い保存先パスを録音操作へ混ぜない。
        if value.saved, message.hasPrefix("保存:") {
            message = message.components(separatedBy: " / ").dropFirst().joined(separator: " / ")
        }
        messageLabel.stringValue = message
        messageLabel.isHidden = message.isEmpty
        messageLabel.textColor = value.state == .idle && !value.saved && !message.isEmpty ? .systemRed : .secondaryLabelColor

        copyButton.title = value.hasCopied ? "前回コピー以降をコピー" : "会話をコピー"
        copyButton.isEnabled = value.canShare && value.handoffPreview != nil
        moreButton.isEnabled = value.canShare && (value.hasCopied || !value.utterances.isEmpty)
        if let preview = value.handoffPreview {
            let end = value.state == .idle ? "終了" : "現在"
            let correction = preview.includesCorrections ? "訂正を含む · " : ""
            rangeLabel.stringValue = correction + TranscriptRenderer.clock(preview.startTime)
                + " 〜 " + end + " " + TranscriptRenderer.clock(value.elapsed)
        } else {
            rangeLabel.stringValue = value.hasCopied ? "前回コピーから変更なし" : "発言を待っています"
        }
        rangeLabel.toolTip = rangeLabel.stringValue
        handoffLabel.stringValue = value.handoffMessage ?? "AIへ貼り付け。問いは会話に含めても、貼った後に書いても。"
        handoffLabel.textColor = value.handoffFailed ? .systemRed : .secondaryLabelColor
        replaceText(with: presentation(value))
    }

    private func buildContent() -> NSView {
        configure(startStopButton, #selector(startStopPressed))
        configure(pauseButton, #selector(pausePressed))
        configure(openButton, #selector(openPressed))
        configure(namesButton, #selector(namesPressed))
        configure(copyButton, #selector(copyPressed))
        configure(moreButton, #selector(morePressed))
        configure(latestButton, #selector(latestPressed))
        copyButton.bezelColor = .controlAccentColor
        copyButton.contentTintColor = .white
        copyButton.toolTip = "会話ファイルへの参照と、今回読む範囲をクリップボードにコピー"
        latestButton.isHidden = true
        latestButton.controlSize = .small
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        elapsedLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.maximumNumberOfLines = 3
        rangeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        rangeLabel.textColor = .secondaryLabelColor
        rangeLabel.lineBreakMode = .byTruncatingMiddle
        rangeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        handoffLabel.font = .systemFont(ofSize: 12)
        handoffLabel.maximumNumberOfLines = 2
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = row([statusDot, statusLabel, elapsedLabel, spacer, pauseButton, startStopButton, openButton, namesButton], spacing: 8)
        let header = column([controls, messageLabel], spacing: 8, inset: 12)

        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        let body = NSView()
        body.addSubview(scrollView)
        body.addSubview(latestButton)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        latestButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: body.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            latestButton.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -20),
            latestButton.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -10),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
        let title = NSTextField(labelWithString: "AIへ渡す会話")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let footerTitle = row([title, NSView(), rangeLabel], spacing: 12)
        let buttons = row([copyButton, moreButton], spacing: 12)
        copyButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = column([footerTitle, buttons, handoffLabel], spacing: 8, inset: 16)
        let stack = column([header, separator(), body, separator(), footer], spacing: 0, inset: 0)
        let content = NSView()
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
        return content
    }

    private func configure(_ button: NSButton, _ action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        // Returnは名前の確定に使う。録音停止やコピーの既定ボタンにはしない。
        button.keyEquivalent = ""
    }

    private func row(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func column(_ views: [NSView], spacing: CGFloat, inset: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * inset).isActive = true }
        return stack
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    @objc private func startStopPressed() { onStartStop?() }
    @objc private func pausePressed() { onPauseResume?() }
    @objc private func openPressed() { onOpenMarkdown?() }
    @objc private func copyPressed() { onCopy?(false) }
    @objc private func recopyPressed() { onRecopy?() }
    @objc private func fullCopyPressed() { onCopy?(true) }
    @objc private func morePressed() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let recopy = NSMenuItem(title: "直前の範囲を再コピー", action: #selector(recopyPressed), keyEquivalent: "")
        recopy.target = self
        recopy.isEnabled = snapshot.hasCopied
        menu.addItem(recopy)
        let full = NSMenuItem(title: "会議の最初からコピー", action: #selector(fullCopyPressed), keyEquivalent: "")
        full.target = self
        full.isEnabled = snapshot.hasCopied || !snapshot.utterances.isEmpty
        menu.addItem(full)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.minY), in: moreButton)
    }

    @objc private func namesPressed() {
        guard namesSheet == nil, let window else { return }
        let sheet = SpeakerNamesSheet(names: snapshot.names)
        namesSheet = sheet
        sheet.present(on: window) { [weak self] names in
            self?.namesSheet = nil
            if let names { self?.onRename?(names) }
        }
    }

    @objc private func latestPressed() {
        textView.scrollToEndOfDocument(nil)
        latestButton.isHidden = true
    }

    @objc private func scrolled() {
        latestButton.isHidden = isScrolledToBottom() || snapshot.utterances.isEmpty
    }

    private func presentation(_ snapshot: SessionSnapshot) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
        let heading: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor]
        if snapshot.utterances.isEmpty {
            return NSAttributedString(string: snapshot.state == .idle
                ? "録音を開始すると、会話がここに表示されます。" : "発言を待っています…", attributes: body)
        }
        for (i, utterance) in snapshot.utterances.enumerated() {
            if let preview = snapshot.handoffPreview, snapshot.hasCopied, i + 1 == preview.startLine {
                result.append(NSAttributedString(string: "── 次にコピーする範囲 ──\n\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.controlAccentColor]))
            }
            let letter = utterance.speaker.map { SpeakerNames.letter(for: $0) + "  " } ?? ""
            let name = snapshot.names.name(for: utterance.speaker)
            result.append(NSAttributedString(string: letter + name + "    " + TranscriptRenderer.clock(utterance.start) + "\n",
                                             attributes: heading))
            result.append(NSAttributedString(string: utterance.text + "\n\n", attributes: body))
        }
        return result
    }

    private func replaceText(with text: NSAttributedString) {
        guard text.string != lastText, let storage = textView.textStorage else { return }
        let wasAtBottom = isScrolledToBottom()
        let common = ((lastText as NSString).commonPrefix(with: text.string, options: []) as NSString).length
        storage.replaceCharacters(in: NSRange(location: common, length: storage.length - common),
                                  with: text.attributedSubstring(from: NSRange(location: common, length: text.length - common)))
        lastText = text.string
        if wasAtBottom { textView.scrollToEndOfDocument(nil) }
        scrolled()
    }

    private func isScrolledToBottom() -> Bool {
        scrollView.contentView.bounds.maxY >= textView.frame.height - 24
    }
}

/// 編集中の値はライブ更新から独立させ、4枠を一度だけ反映する。
@MainActor
final class SpeakerNamesSheet: NSObject {
    let window: NSWindow
    private var fields: [NSTextField] = []
    private var completion: ((SpeakerNames?) -> Void)?

    init(names: SpeakerNames) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 285),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "話者名を編集"
        super.init()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let hint = NSTextField(labelWithString: "会話全体に反映します。停止後は保存も更新します。")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        for slot in 0..<SpeakerNames.slotCount {
            let label = NSTextField(labelWithString: SpeakerNames.letter(for: slot))
            label.widthAnchor.constraint(equalToConstant: 20).isActive = true
            let field = NSTextField(string: names.customName(for: slot) ?? "")
            field.placeholderString = SpeakerNames.defaultName(for: slot)
            field.setAccessibilityLabel("話者" + SpeakerNames.letter(for: slot) + "の名前")
            fields.append(field)
            let row = NSStackView(views: [label, field])
            row.spacing = 12
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let cancel = NSButton(title: "キャンセル", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: "反映する", target: self, action: #selector(applyPressed))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, apply])
        buttons.spacing = 10
        stack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let content = NSView()
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20)
        ])
        window.contentView = content
    }

    func present(on parent: NSWindow, completion: @escaping (SpeakerNames?) -> Void) {
        self.completion = completion
        parent.beginSheet(window) { [weak self] response in
            guard let self else { return }
            var names = SpeakerNames()
            for (i, field) in self.fields.enumerated() { names.set(field.stringValue, for: i) }
            self.completion?(response == .OK ? names : nil)
            self.completion = nil
        }
        window.makeFirstResponder(fields.first)
    }

    func cancel() { window.sheetParent?.endSheet(window, returnCode: .cancel) }
    @objc private func cancelPressed() { cancel() }
    @objc private func applyPressed() {
        window.makeFirstResponder(nil)
        window.sheetParent?.endSheet(window, returnCode: .OK)
    }
}
