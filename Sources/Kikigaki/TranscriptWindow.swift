import AppKit
import KikigakiCore

/// 書き起こしウィンドウ。上段に状態と話者名の枡(A〜D)、下段に `[mm:ss] 話者名: テキスト` を流す
@MainActor
final class TranscriptWindowController: NSWindowController, NSTextFieldDelegate {
    var onRename: ((Int, String) -> Void)?
    var onStartStop: (() -> Void)?
    var onPauseResume: (() -> Void)?

    private let startStopButton = NSButton(title: "", target: nil, action: nil)
    private let pauseResumeButton = NSButton(title: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private var nameFields: [NSTextField] = []
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private var lastText = ""
    private let bodyFont = NSFont.systemFont(ofSize: 14)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "KIKIGAKI"
        // 閉じても破棄せず、次に表示するときに同じ内容を出す
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("KikigakiTranscript")
        super.init(window: window)
        window.contentView = buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func apply(_ snapshot: SessionSnapshot) {
        startStopButton.title = snapshot.state.startStopTitle
        startStopButton.isEnabled = snapshot.state.canStart || snapshot.state.canStop
        pauseResumeButton.title = snapshot.state.pauseResumeTitle
        pauseResumeButton.isEnabled = snapshot.state.canPauseOrResume
        var status = "\(snapshot.state.statusLabel)  \(TranscriptRenderer.clock(snapshot.elapsed))"
        if let url = snapshot.markdownURL { status += "   \(url.path)" }
        statusLabel.stringValue = status
        messageLabel.stringValue = snapshot.message ?? ""
        messageLabel.isHidden = snapshot.message == nil

        for (slot, field) in nameFields.enumerated() {
            // 入力中の枡は触らない(打ちかけの文字を消さないため)
            guard field.currentEditor() == nil else { continue }
            field.stringValue = snapshot.names.customName(for: slot) ?? ""
        }
        replaceText(with: TranscriptRenderer.text(snapshot.utterances, names: snapshot.names))
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let slot = nameFields.firstIndex(of: field) else { return }
        onRename?(slot, field.stringValue)
    }

    // MARK: - 構築

    @objc private func startStopPressed() { onStartStop?() }
    @objc private func pauseResumePressed() { onPauseResume?() }

    private func buildContent() -> NSView {
        startStopButton.target = self
        startStopButton.action = #selector(startStopPressed)
        startStopButton.bezelStyle = .rounded
        // Enter は名前欄の確定に使うので、ボタンにキー割り当てはしない(誤って停止しないため)
        pauseResumeButton.target = self
        pauseResumeButton.action = #selector(pauseResumePressed)
        pauseResumeButton.bezelStyle = .rounded
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let controlRow = NSStackView(views: [startStopButton, pauseResumeButton, statusLabel])
        controlRow.orientation = .horizontal
        controlRow.spacing = 12
        controlRow.alignment = .centerY
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingMiddle

        let namesRow = NSStackView()
        namesRow.orientation = .horizontal
        namesRow.spacing = 8
        for slot in 0..<SpeakerNames.slotCount {
            let label = NSTextField(labelWithString: SpeakerNames.letter(for: slot))
            label.font = .boldSystemFont(ofSize: 12)
            let field = NSTextField()
            field.placeholderString = SpeakerNames.defaultName(for: slot)
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 120).isActive = true
            nameFields.append(field)
            namesRow.addArrangedSubview(label)
            namesRow.addArrangedSubview(field)
        }
        let hint = NSTextField(labelWithString: "枡に名前を付けると表示と保存した Markdown に反映")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        // 窓が狭いときは枡ではなくヒントを縮める
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        namesRow.addArrangedSubview(hint)

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = bodyFont
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let stack = NSStackView(views: [controlRow, messageLabel, namesRow, scrollView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            namesRow.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor),
            controlRow.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            messageLabel.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
        return content
    }

    /// 前回と共通の先頭部分は触らず、変わった末尾だけ差し替える。8秒より古い行の話者判定は凍結済みで
    /// 文字列も変わらないため、全文を置き換えるより選択や描画が安定する
    private func replaceText(with text: String) {
        guard text != lastText, let storage = textView.textStorage else { return }
        let old = lastText as NSString
        let common = (old.commonPrefix(with: text, options: []) as NSString).length
        let attributes: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.textColor]
        let tail = (text as NSString).substring(from: common)
        let wasAtBottom = isScrolledToBottom()
        storage.replaceCharacters(
            in: NSRange(location: common, length: storage.length - common),
            with: NSAttributedString(string: tail, attributes: attributes))
        lastText = text
        if wasAtBottom { textView.scrollToEndOfDocument(nil) }
    }

    private func isScrolledToBottom() -> Bool {
        let visible = scrollView.contentView.bounds
        let docHeight = textView.frame.height
        return visible.maxY >= docHeight - 24
    }
}
