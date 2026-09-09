import Foundation
import KikigakiCore

struct AIScheduleViewState {
    var active = false
    var text = ""
    var warning: String?
    var tone: AINoticeTone = .normal
    var toolTip = ""
    private static let clock: DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.dateFormat = "HH:mm"; return value
    }()

    init(schedule: AIScheduleState? = nil, warning: String? = nil, destination: String? = nil) {
        self.warning = warning
        // 宛先は複数プロファイルのときだけ添える。1つしか無い会議で行を伸ばさない。
        let target = destination.map { " · " + $0 + "へ" } ?? ""
        guard let schedule, schedule.phase != .stopped else {
            text = warning ?? ""; toolTip = text; tone = warning == nil ? .normal : .warning; return
        }
        active = true
        toolTip = schedule.options?.prompt ?? ""
        switch schedule.phase {
        case .running:
            let seconds = schedule.options?.interval ?? 180
            let interval = seconds < 60 ? "\(Int(seconds))秒" : "\(Int(seconds / 60))分"
            text = "自動送信 \(interval) · 次 " + (schedule.nextFire.map(Self.clock.string) ?? "—") + target
        case .awaitingSave: text = "最後の1回 · 保存を待っています" + target
        case .awaitingFinal: text = "最後の1回 · 返事を待っています" + target
        case .stopped: break
        }
    }
}
