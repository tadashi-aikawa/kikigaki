import AppKit
import UniformTypeIdentifiers
import KikigakiCore

private final class MinutesPathCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var result = super.drawingRect(forBounds: rect).insetBy(dx: 6, dy: 0)
        let height = min(result.height, ceil((font?.ascender ?? 10) - (font?.descender ?? -3)) + 2)
        result.origin.y += (result.height - height) / 2; result.size.height = height
        return result
    }
}

private final class MinutesPathField: NSTextField {
    var focused = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        Washi.paper.setFill(); bounds.fill()
        super.draw(dirtyRect)
        (focused ? Washi.ink : Washi.rule).setStroke()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        outline.lineWidth = 1; outline.stroke()
    }
}

/// パス編集と本文閲読を分離する。通知が来てもfield editorのドラフトは変更しない。
@MainActor final class MinutesPreviewView: NSView, NSSearchFieldDelegate {
    let pathField: NSTextField = MinutesPathField(string: "")
    let headerBar = NSView()
    let document = MinutesWebView(frame: .zero)
    let updateStatus = MinutesUpdateStatus(frame: .zero)
    private var pendingModifiedAt: Date?
    private var rendering = false
    let searchField = NSSearchField()
    private let searchBar = NSStackView()
    private let searchCount = Washi.label("", size: 11)
    private let neovimButton = HoverButton(title: "", target: nil, action: nil)
    private let obsidianButton = HoverButton(title: "", target: nil, action: nil)
    private var editorTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var resetNextRender = true
    let message = NSTextField(wrappingLabelWithString: "")
    let notice = NSTextField(wrappingLabelWithString: "")
    private let retryButton = HoverButton(title: "再読込", target: nil, action: nil)
    private let cancelButton = HoverButton(title: "読込を取り消す", target: nil, action: nil)
    private let emptyChoose = HoverButton(title: "ファイルを選ぶ…", target: nil, action: nil)
    var onSelect: ((String?) throws -> Void)?
    var onClose: (() -> Void)?
    var herdrCommand: () -> String? = { nil }
    private var path: String?
    private var source: MinutesState.Source?
    private var editing = false
    private var commitError: String?
    private var contextGeneration = 0
    private var active = false
    private var monitor: MinutesFileMonitor?
    private var body: String?
    override init(frame: NSRect) {
        super.init(frame: frame)
        Washi.surface(self, color: Washi.paper)
        pathField.cell = MinutesPathCell(textCell: "")
        pathField.isEditable = true; pathField.isSelectable = true
        pathField.cell?.isScrollable = true
        pathField.placeholderString = "議事録の絶対パス"
        pathField.font = .systemFont(ofSize: 12)
        pathField.isBezeled = false; pathField.isBordered = false; pathField.drawsBackground = false
        pathField.focusRingType = .none; pathField.textColor = Washi.ink
        pathField.delegate = self
        pathField.target = self; pathField.action = #selector(commitPath)
        pathField.setAccessibilityLabel("議事録のパス")
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let choose = HoverButton(title: "ファイルを選ぶ…", target: self, action: #selector(chooseFile))
        let close = HoverButton(title: "", target: self, action: #selector(closePreview))
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "議事録を隠す")
        close.toolTip = "議事録を隠す"; close.setAccessibilityLabel("議事録を隠す")
        neovimButton.target = self; neovimButton.action = #selector(openNeovim)
        obsidianButton.target = self; obsidianButton.action = #selector(openObsidian)
        for (button, asset, label) in [(neovimButton, "neovim", "Neovimで開く"), (obsidianButton, "obsidian", "Obsidianで開く")] {
            button.image = NSImage(contentsOf: MinutesResourceHandler.assets.appendingPathComponent(asset + ".svg"))
            button.image?.size = NSSize(width: 18, height: 18)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.setAccessibilityLabel(label)
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        neovimButton.toolTip = "Neovimで開く — herdrの新しいタブ"
        obsidianButton.toolTip = "議事録をObsidianで開く"
        neovimButton.isEnabled = false; obsidianButton.isEnabled = false
        let top = row([pathField, neovimButton, obsidianButton, choose, close], spacing: 8)
        headerBar.addSubview(top); top.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerBar.heightAnchor.constraint(equalToConstant: 56),
            top.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 24),
            top.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -24),
            top.topAnchor.constraint(equalTo: headerBar.topAnchor, constant: 12),
            top.heightAnchor.constraint(equalToConstant: 32),
            pathField.heightAnchor.constraint(equalToConstant: 24)
        ])
        notice.font = .systemFont(ofSize: 11); notice.textColor = Washi.muted; notice.isHidden = true
        Washi.surface(headerBar)
        searchField.placeholderString = "議事録を検索"; searchField.font = .systemFont(ofSize: 12)
        searchField.delegate = self
        searchField.setAccessibilityLabel("議事録を検索")
        searchField.sendsSearchStringImmediately = true
        let previous = HoverButton(title: "↑", target: self, action: #selector(previousMatch))
        let next = HoverButton(title: "↓", target: self, action: #selector(nextMatch))
        let dismiss = HoverButton(title: "閉じる", target: self, action: #selector(closeSearch))
        previous.setAccessibilityLabel("前の一致"); next.setAccessibilityLabel("次の一致")
        searchBar.orientation = .horizontal; searchBar.spacing = 8
        searchBar.heightAnchor.constraint(equalToConstant: 36).isActive = true
        searchBar.edgeInsets = NSEdgeInsets(top: 6, left: 24, bottom: 6, right: 24)
        for view in [searchField, searchCount, previous, next, dismiss] { searchBar.addArrangedSubview(view) }
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchCount.setContentHuggingPriority(.required, for: .horizontal)
        searchBar.isHidden = true
        document.onRendered = { [weak self] text in
            guard let self, self.active else { return }
            self.rendering = false
            self.updateStatus.setDate(self.pendingModifiedAt)
            if text.isEmpty { self.showMessage("議事録はまだ空です") } else { self.showBody() }
            if !self.searchBar.isHidden { self.search(reveal: false) }
        }
        document.onError = { [weak self] text in self?.cancelRender(); self?.showMessage(text, retry: true) }
        message.font = .systemFont(ofSize: 14); message.textColor = Washi.muted; message.alignment = .center
        message.setAccessibilityLabel("議事録の状態")
        retryButton.target = self; retryButton.action = #selector(reload)
        cancelButton.target = self; cancelButton.action = #selector(cancelRead)
        emptyChoose.target = self; emptyChoose.action = #selector(chooseFile)
        let status = NSStackView(views: [message, emptyChoose, retryButton, cancelButton])
        status.orientation = .vertical; status.alignment = .centerX; status.spacing = 16
        status.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        message.widthAnchor.constraint(equalTo: status.widthAnchor, constant: -48).isActive = true
        let bodyView = NSView()
        bodyView.setContentHuggingPriority(.defaultLow, for: .vertical)
        bodyView.addSubview(document); bodyView.addSubview(status)
        for view in [document, status] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: bodyView.leadingAnchor), document.trailingAnchor.constraint(equalTo: bodyView.trailingAnchor),
            document.topAnchor.constraint(equalTo: bodyView.topAnchor), document.bottomAnchor.constraint(equalTo: bodyView.bottomAnchor),
            status.centerXAnchor.constraint(equalTo: bodyView.centerXAnchor),
            status.widthAnchor.constraint(equalTo: bodyView.widthAnchor, constant: -48),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: bodyView.leadingAnchor, constant: 20),
            status.trailingAnchor.constraint(lessThanOrEqualTo: bodyView.trailingAnchor, constant: -20)
        ])
        // 案内の先頭を上から1/3へ。本文スクロールとは独立させる。
        let guide = NSLayoutGuide(); bodyView.addLayoutGuide(guide)
        guide.topAnchor.constraint(equalTo: bodyView.topAnchor).isActive = true
        guide.heightAnchor.constraint(equalTo: bodyView.heightAnchor, multiplier: 0.28).isActive = true
        status.topAnchor.constraint(equalTo: guide.bottomAnchor).isActive = true
        let bodyColumn = column([notice, bodyView], spacing: 0, inset: 0)
        bodyColumn.setContentHuggingPriority(.defaultLow, for: .vertical)
        let layout = column([headerBar, separator(), searchBar, bodyColumn, separator(), updateStatus], spacing: 0, inset: 0)
        addSubview(layout); layout.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: leadingAnchor), layout.trailingAnchor.constraint(equalTo: trailingAnchor),
            layout.topAnchor.constraint(equalTo: topAnchor), layout.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        showMessage("議事録のファイルを指定するか、AIに書かせると表示します")
    }
    required init?(coder: NSCoder) { fatalError() }
    func resetContext() {
        stop(); path = nil; body = nil; editing = false; commitError = nil; contextGeneration += 1
        window?.makeFirstResponder(nil)
        document.clear(); document.setFile(nil); resetNextRender = true
        closeSearch(); editorTask?.cancel(); editorTask = nil
    }

    private func row(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = spacing
        return stack
    }
    private func column(_ views: [NSView], spacing: CGFloat, inset: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * inset).isActive = true }
        return stack
    }
    private func separator() -> NSView {
        let line = NSView(); Washi.surface(line, color: Washi.rule); line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    func update(path: String?, source: MinutesState.Source?, active: Bool, warning: String? = nil) {
        let changed = self.path != path
        let start = active && (!self.active || changed || self.source != source)
        self.path = path; self.source = source; self.active = active
        updateStatus.active = active
        if changed { document.setFile(path.map { URL(fileURLWithPath: $0) }); resetNextRender = true }
        neovimButton.isEnabled = path != nil && editorTask == nil
        obsidianButton.isEnabled = path != nil
        if editing || pathField.currentEditor() != nil {
            if changed { notice.stringValue = "表示対象が変わりました。編集中のパスは保持しています"; notice.isHidden = false }
        } else { pathField.stringValue = path ?? ""; pathField.toolTip = path; notice.isHidden = warning == nil; notice.stringValue = warning ?? "" }
        if let commitError { notice.stringValue = commitError; notice.isHidden = false }
        if !active { cancelRender(); monitor?.stop(); monitor = nil; return }
        if start { beginRead(reset: changed) }
    }

    private func beginRead(reset: Bool) {
        cancelRender()
        monitor?.stop(); monitor = nil
        if reset { body = nil; document.clear(); resetNextRender = true }
        guard let path else { showMessage("議事録のファイルを指定するか、AIに書かせると表示します"); return }
        showMessage("読み込んでいます…", cancel: true)
        monitor = MinutesFileMonitor(path: path) { [weak self] result in self?.receive(result) }
    }

    func receive(_ result: MinutesFileResult) {
        switch result {
        case .body(let source, _, let modifiedAt):
            pendingModifiedAt = modifiedAt
            guard body != source else {
                if !rendering { updateStatus.setDate(modifiedAt); showBody() }
                return
            }
            body = source
            rendering = true
            document.render(source, reset: resetNextRender)
            resetNextRender = false
        case .missing: cancelRender(); showMessage(source == .ai ? "AIが通知したファイルはまだありません。作成されると自動で表示します" : "指定したファイルはまだありません。作成されると自動で表示します", retry: true)
        case .cloud: cancelRender(); showMessage("iCloudからのダウンロードを待っています…", cancel: true)
        case .failure(let reason): cancelRender(); showMessage(reason, retry: true)
        case .changed: break
        }
    }

    private func cancelRender() { body = nil; rendering = false; pendingModifiedAt = nil; updateStatus.setDate(nil); document.invalidate() }
    private func showBody() {
        message.isHidden = true; emptyChoose.isHidden = true; retryButton.isHidden = true; cancelButton.isHidden = true; document.isHidden = false
    }

    private func showMessage(_ value: String, retry: Bool = false, cancel: Bool = false) {
        message.stringValue = value; message.isHidden = false; document.isHidden = true
        emptyChoose.isHidden = path != nil
        retryButton.isHidden = !retry; cancelButton.isHidden = !cancel
    }
    func controlTextDidBeginEditing(_ obj: Notification) {
        guard obj.object as? NSTextField === pathField else { return }
        editing = true; (pathField as? MinutesPathField)?.focused = true
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as? NSTextField === pathField else { return }
        editing = false; pathField.stringValue = path ?? ""; notice.isHidden = commitError == nil
        (pathField as? MinutesPathField)?.focused = false
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === searchField {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { closeSearch(); return true }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                search(direction: NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1); return true
            }
            return false
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { commitPath(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            editing = false; commitError = nil; window?.makeFirstResponder(nil); pathField.stringValue = path ?? ""; notice.isHidden = true
            (pathField as? MinutesPathField)?.focused = false
            return true
        }
        return false
    }
    @objc func commitPath() {
        do {
            let input = pathField.stringValue
            let path: String? = input.isEmpty ? nil : (input as NSString).expandingTildeInPath
            if let path, !path.hasPrefix("/") { throw AIError.invalid("absolute path") }
            let normalized = path.map { value in
                var parts: [Substring] = []
                for part in value.split(separator: "/") {
                    if part == "." { continue }
                    if part == ".." { if !parts.isEmpty { parts.removeLast() } }
                    else { parts.append(part) }
                }
                return "/" + parts.joined(separator: "/")
            }
            if let normalized { try MinutesPath.validate(normalized) }
            try onSelect?(normalized)
            editing = false; commitError = nil; window?.makeFirstResponder(nil)
            (pathField as? MinutesPathField)?.focused = false
            pathField.stringValue = self.path ?? normalized ?? ""; notice.isHidden = true
        } catch { commitError = "パスを保存できません。絶対パスの.mdファイルを指定してください"; notice.stringValue = commitError!; notice.isHidden = false }
    }
    @objc private func chooseFile() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        let generation = contextGeneration
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, self.contextGeneration == generation, let url = panel.url else { return }
            self.pathField.stringValue = url.path; self.commitPath()
        }
    }
    @objc private func closePreview() { onClose?() }
    @objc private func reload() { body = nil; beginRead(reset: false) }
    @objc private func cancelRead() { cancelRender(); monitor?.stop(); monitor = nil; showMessage("読み込みを取り消しました", retry: true) }
    func stop() { cancelRender(); active = false; updateStatus.active = false; body = nil; monitor?.stop(); monitor = nil; editorTask?.cancel(); editorTask = nil }
    var hasSearchFocus: Bool {
        guard !isHidden, let responder = window?.firstResponder else { return false }
        if responder === searchField.currentEditor() || responder === pathField.currentEditor() { return true }
        return (responder as? NSView)?.isDescendant(of: self) == true
    }
    func showSearch() {
        searchBar.isHidden = false; layoutSubtreeIfNeeded()
        window?.makeFirstResponder(searchField); searchField.selectText(nil); search()
    }
    @objc func closeSearch() {
        searchGeneration += 1
        searchBar.isHidden = true; searchField.stringValue = ""
        document.search("") { _, _ in }
        if let editor = searchField.currentEditor(), window?.firstResponder === editor {
            window?.makeFirstResponder(document.webView)
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === searchField { search() }
    }
    func search(direction: Int = 0, reveal: Bool = true) {
        if searchBar.isHidden { showSearch(); return }
        searchGeneration += 1; let current = searchGeneration
        document.search(searchField.stringValue, direction: direction, reveal: reveal) { [weak self] at, count in
            guard let self, self.searchGeneration == current else { return }
            self.searchCount.stringValue = count == 0 ? "一致なし" : "\(at) / \(count)"
        }
    }
    @objc private func previousMatch() { search(direction: -1) }
    @objc private func nextMatch() { search(direction: 1) }
    @objc private func openNeovim() {
        guard let path, editorTask == nil else { return }
        let generation = contextGeneration
        neovimButton.isEnabled = false
        editorTask = Task { [weak self] in
            do { try await MinutesExternalEditor.openNeovim(path: path, herdrCommand: self?.herdrCommand()) }
            catch {
                guard let self, !Task.isCancelled, self.contextGeneration == generation else { return }
                self.notice.stringValue = error.localizedDescription; self.notice.isHidden = false
            }
            guard let self, self.contextGeneration == generation else { return }
            self.editorTask = nil; self.neovimButton.isEnabled = self.path != nil
        }
    }
    @objc private func openObsidian() {
        guard let path else { return }
        openObsidianFile(path)
    }
    private func openObsidianFile(_ path: String) {
        do {
            _ = try MinutesExternalEditor.existingFile(path)
            guard NSWorkspace.shared.open(MinutesExternalEditor.obsidianURL(path: path)) else {
                throw MinutesEditorError.failed("Obsidianを開けません。インストールを確認してください")
            }
        } catch { notice.stringValue = error.localizedDescription; notice.isHidden = false }
    }
}
