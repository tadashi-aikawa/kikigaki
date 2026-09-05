import AppKit
import KikigakiCore

/// メニューバー常駐アイコン。録音の開始・停止・一時停止・再開と、ウィンドウ・保存先・設定・終了の入口
@MainActor
final class StatusItem {
    private let item: NSStatusItem
    private let statusMenuItem: NSMenuItem
    private let startStopItem: NSMenuItem
    private let pauseResumeItem: NSMenuItem

    var onStartStop: (() -> Void)?
    var onPauseResume: (() -> Void)?
    var onShowWindow: (() -> Void)?
    var onOpenOutputDir: (() -> Void)?
    var onReloadConfig: (() -> Void)?

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
        }

        statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        startStopItem = NSMenuItem(title: "", action: #selector(startStop), keyEquivalent: "")
        pauseResumeItem = NSMenuItem(title: "", action: #selector(pauseResume), keyEquivalent: "")
        startStopItem.target = self
        pauseResumeItem.target = self

        let menu = NSMenu()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let versionItem = NSMenuItem(title: "KIKIGAKI \(version ?? "0.0.0-development")", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(startStopItem)
        menu.addItem(pauseResumeItem)
        menu.addItem(.separator())

        let showItem = NSMenuItem(title: "書き起こしを表示", action: #selector(showWindow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        let openItem = NSMenuItem(title: "保存先を開く", action: #selector(openOutputDir), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        let reloadItem = NSMenuItem(title: "設定を再読込", action: #selector(reloadConfig), keyEquivalent: "")
        reloadItem.target = self
        menu.addItem(reloadItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit KIKIGAKI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        update(state: .idle, elapsed: 0)
    }

    func update(state: RecordingState, elapsed: Double) {
        statusMenuItem.title = state.canStop ? "\(state.statusLabel)  \(TranscriptRenderer.clock(elapsed))" : state.statusLabel
        startStopItem.title = state.startStopTitle
        startStopItem.isEnabled = state.canStart || state.canStop
        pauseResumeItem.title = state.pauseResumeTitle
        pauseResumeItem.isEnabled = state.canPauseOrResume
        item.button?.image = Self.icon(for: state)
    }

    @objc private func startStop() { onStartStop?() }
    @objc private func pauseResume() { onPauseResume?() }
    @objc private func showWindow() { onShowWindow?() }
    @objc private func openOutputDir() { onOpenOutputDir?() }
    @objc private func reloadConfig() { onReloadConfig?() }

    private static func icon(for state: RecordingState) -> NSImage? {
        let name: String
        switch state {
        case .idle: name = "waveform"
        case .preparing, .finishing: name = "waveform.circle"
        case .recording: name = "record.circle.fill"
        case .paused: name = "pause.circle.fill"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "KIKIGAKI \(state.statusLabel)")
        image?.isTemplate = true
        return image
    }
}
