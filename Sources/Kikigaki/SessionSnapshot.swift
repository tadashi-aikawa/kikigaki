import Foundation
import KikigakiCore

/// 画面に渡す状態。保存先の予約と保存成功は別の情報として扱う。
struct SessionSnapshot {
    var aiSchedule = AIScheduleViewState()
    var ai: AIViewState?
    var previousAIUnread = 0
    var aiRecoveryWarning: String?
    var state: RecordingState = .idle
    var utterances: [Utterance] = []
    var tentativeText: String?
    var pendingSpeakerRows: Set<Int> = []
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
    var detectedSpeakerSlots: [Int] = []
    var speakerMapping: [Int: Int] = [:]
    var speakerOverrides: [Int: Int] = [:]

    var canSubmitTyped: Bool { state == .recording || state == .paused }
    var voiceQuestionPlaceholder: String {
        tentativeText ?? utterances.last(where: { $0.kind == .voice })?.text ?? "空欄なら声の末尾を送ります"
    }
    /// 音声消費が遅れていても、投稿済みの位置までを表示範囲に含める。
    var contextEnd: Double { max(elapsed, utterances.filter { $0.kind == .typed }.map(\.start).max() ?? 0) }
    var contextEndClock: String {
        if let latest = utterances.filter({ $0.kind == .typed }).compactMap(\.postedAt).max(),
           latest > timeline.date(at: contextEnd) {
            return MeetingTimeline(startedAt: latest).clock(at: 0)
        }
        return timeline.clock(at: contextEnd)
    }

    func contextStartClock(_ preview: HandoffPreview) -> String {
        let index = preview.startLine - 1
        if utterances.indices.contains(index) { return TranscriptRenderer.clock(for: utterances[index], timeline: timeline) }
        return timeline.clock(at: preview.startTime)
    }

    var canShare: Bool {
        markdownURL != nil && (state == .recording || state == .paused || state == .idle)
    }
}
