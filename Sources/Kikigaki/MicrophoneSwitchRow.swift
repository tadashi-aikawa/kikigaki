import AppKit

final class MicrophoneSwitchRow: NSView, DocumentRow {
    override var isFlipped: Bool { true }
    let event: MicrophoneSwitch
    let label = Washi.label(size: 11, color: Washi.muted)
    init(_ event: MicrophoneSwitch) {
        self.event = event
        super.init(frame: .zero)
        label.stringValue = event.text
        label.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = event.text
        label.setAccessibilityLabel(event.text)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    func height(for width: CGFloat) -> CGFloat { 30 }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 54, y: 9, width: max(0, bounds.width - 74), height: 16)
    }
    override func draw(_ dirtyRect: NSRect) {
        Washi.rule.setFill()
        NSRect(x: 54, y: 2, width: max(0, bounds.width - 74), height: 0.5).fill()
    }
}
