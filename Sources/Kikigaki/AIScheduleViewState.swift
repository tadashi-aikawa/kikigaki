import Foundation
import KikigakiCore

struct AIScheduleViewState {
    var active = false
    var text = ""
    var warning: String?
    var tone: AINoticeTone = .normal
    var toolTip = ""
    var nextFire: Date?
    var interval: TimeInterval = 180
    var skipReason: String?
    var canCountDown = true
    var canFireNow = true
    var destination: String?
    private static let clock: DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.dateFormat = "HH:mm"; return value
    }()

    init(schedule: AIScheduleState? = nil, warning: String? = nil, destination: String? = nil,
         availability: AIScheduleAvailability = .ready, hasChanges: Bool = true) {
        self.warning = warning
        self.destination = destination
        // 宛先は複数プロファイルのときだけ添える。1つしか無い会議で行を伸ばさない。
        let target = destination.map { " · " + $0 + "へ" } ?? ""
        guard let schedule, schedule.phase != .stopped else {
            text = warning ?? ""; toolTip = text; tone = warning == nil ? .normal : .warning; return
        }
        active = true
        nextFire = schedule.nextFire
        canCountDown = schedule.phase == .running && availability != .disconnected
        canFireNow = schedule.phase == .running && availability == .ready
        interval = schedule.options?.interval ?? 180
        switch availability {
        case .awaitingResult: skipReason = "返事待ちでスキップ中"
        case .busy: skipReason = "処理中のためスキップ中"
        case .disconnected: skipReason = "接続できないためスキップ中"
        case .ready: if !hasChanges { skipReason = "差分なしでスキップ中" }
        }
        // 音声ファイルの書き起こしは開始シートの「完了時に送信」と同じ言葉で出す。
        let final = schedule.finalOnly ? "完了時に送信" : "最後の1回"
        if schedule.phase != .running { skipReason = final + "を待っています" }
        toolTip = schedule.options?.prompt ?? ""
        switch schedule.phase {
        case .running:
            let seconds = schedule.options?.interval ?? 180
            let interval = seconds < 60 ? "\(Int(seconds))秒" : "\(Int(seconds / 60))分"
            text = "自動送信 \(interval) · 次 " + (schedule.nextFire.map(Self.clock.string) ?? "—") + target
        case .awaitingSave: text = final + (schedule.finalOnly ? " · 書き起こしを待っています" : " · 保存を待っています") + target
        case .awaitingFinal: text = final + " · 返事を待っています" + target
        case .stopped: break
        }
    }
}
