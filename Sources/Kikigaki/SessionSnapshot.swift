import Foundation
import KikigakiCore

/// 画面に渡す状態。保存先の予約と保存成功は別の情報として扱う。
struct SessionSnapshot {
    var state: RecordingState = .idle
    var utterances: [Utterance] = []
    var tentativeText: String?
    var timeline = MeetingTimeline(startedAt: Date())
    var names = SpeakerNames()
    var speakers: [KikigakiConfig.Speaker] = []
    /// 一時停止中を除いた会議の経過秒。
    var elapsed: Double = 0
    var markdownURL: URL?
    var message: String?
    var saved = false
    var handoffPreview: HandoffPreview?
    var hasCopied = false
    var handoffMessage: String?
    var handoffFailed = false
    /// 次の録音の人数上限。録音開始時に会議用の値へコピーする。
    var maxSpeakers: Int?
    /// 現在の会議の枠数。停止後に次の録音の上限を変えても、この値は変えない。
    var meetingSpeakerCapacity: Int?
    var detectedSpeakerSlots: [Int] = []
    var speakerMapping: [Int: Int] = [:]
    var speakerOverrides: [Int: Int] = [:]
    var speakerWarning: String?

    var canShare: Bool {
        markdownURL != nil && (state == .recording || state == .paused || state == .idle)
    }
}
