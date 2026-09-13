import AppKit
import KikigakiCore

/// 行高を使い増さず、アバター左の余白に確定までの段を示す。
final class UtteranceGaugeView: NSView {
    override var isFlipped: Bool { true }
    private(set) var stage: UtteranceProgress.Stage?
    private var steps: [UtteranceProgress.Stage] = []
    private var dots: [NSView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ stage: UtteranceProgress.Stage?, steps: [UtteranceProgress.Stage]) {
        guard self.stage != stage || self.steps != steps else { return }
        self.stage = stage
        self.steps = steps
        isHidden = stage == nil
        dots.forEach { $0.removeFromSuperview() }
        dots = steps.enumerated().map { index, step in
            let dot = NSView(frame: NSRect(x: 0, y: CGFloat(index * 12), width: 10, height: 10))
            dot.toolTip = description(for: step)
            dot.setAccessibilityElement(false)
            addSubview(dot)
            return dot
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("発話の確定状況")
        setAccessibilityValue(stage.map { description(for: $0) })
        setAccessibilityChildren([])
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let stage, let current = steps.firstIndex(of: stage) else { return }
        for index in steps.indices {
            let rect = NSRect(x: 1, y: 1 + CGFloat(index * 12), width: 8, height: 8)
            let path = NSBezierPath(ovalIn: rect)
            if index <= current {
                (index == current ? Washi.red : Washi.gaugeReached).setFill()
                path.fill()
            } else {
                Washi.muted.withAlphaComponent(0.4).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    private func description(for step: UtteranceProgress.Stage) -> String {
        guard let index = steps.firstIndex(of: step) else { return step.tooltip }
        let position = "\(step.label)(\(steps.count)段中\(index + 1)段目)"
        return step == .speakerFixed ? position + "。停止時に全体を再判定します" : position
    }
}
