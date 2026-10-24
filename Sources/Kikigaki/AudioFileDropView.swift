import AppKit

/// 書き起こし窓の左ペインで、音声ファイルのドロップを受ける。録音していないときだけ受け付ける。
/// 手入力欄の画像のドロップは手入力欄が先に受けるので、録音中に奪わない。仕様は docs/audio-file.md
///
/// 左ペインの縦並びそのものに受けさせる。別のビューで包むと分割ビューの中で並びの高さが崩れ、ヘッダーが消えた。
@MainActor
final class AudioFileDropView: NSStackView {
    var accepts: () -> Bool = { false }
    var onDrop: ((URL) -> Void)?
    private let overlay = NSView()
    private let border = CAShapeLayer()
    private(set) var isHighlighted = false

    /// 並びを組み終えてから呼ぶ。覆いは並びの外に置き、高さの計算へ入れない。
    func installOverlay() {
        registerForDraggedTypes([.fileURL])
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = Washi.paper.withAlphaComponent(0.92).cgColor
        border.fillColor = nil
        border.strokeColor = Washi.red.cgColor
        border.lineWidth = 2
        border.lineDashPattern = [6, 4]
        overlay.layer?.addSublayer(border)
        let label = Washi.label("ここで離すと書き起こす", size: 15, color: Washi.red, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(label)
        overlay.isHidden = true
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: topAnchor), overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor), overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor), label.centerYAnchor.constraint(equalTo: overlay.centerYAnchor)
        ])
    }

    override func layout() {
        super.layout()
        border.frame = overlay.bounds
        border.path = CGPath(roundedRect: overlay.bounds.insetBy(dx: 10, dy: 10), cornerWidth: 10, cornerHeight: 10, transform: nil)
    }

    func audioURL(_ pasteboard: NSPasteboard) -> URL? {
        guard let url = NSURL(from: pasteboard) as URL?, AudioFileProbe.isAudio(url) else { return nil }
        return url
    }

    private func highlight(_ on: Bool) {
        isHighlighted = on
        overlay.isHidden = !on
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard accepts(), audioURL(sender.draggingPasteboard) != nil else { highlight(false); return [] }
        highlight(true)
        return .copy
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isHighlighted ? .copy : []
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { highlight(false) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { highlight(false) }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        highlight(false)
        guard accepts(), let url = audioURL(sender.draggingPasteboard) else { return false }
        onDrop?(url)
        return true
    }
}
