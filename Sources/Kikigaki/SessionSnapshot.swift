import Foundation
import KikigakiCore

/// 画面に渡す状態。保存先の予約と保存成功は別の情報として扱う。
struct SessionSnapshot {
    var aiSchedule = AIScheduleViewState()
    var ai: AIViewState?
    var aiRecoveryWarning: String?
    var manualDestination: AIDestinationPicker.Item?
    var manualDraftSendState: ManualDraftSendState = .unavailable("AI設定がありません")
    var automaticDestination: AIDestinationPicker.Item?
    var state: RecordingState = .idle
    var utterances: [Utterance] = []
    var microphoneSwitches: [MicrophoneSwitch] = []
    var audioLevels: [AudioLevelAssessment?] = []
    var audioExclusion = AudioExclusion()
    var excludedRows: Set<Int> = []
    var includedUtterances: [Utterance] { utterances.enumerated().filter { !excludedRows.contains($0.offset) }.map(\.element) }
    var canChangeAudioExclusion: Bool { state != .preparing && state != .finishing }
    var tentativeText: String?
    var tentativeExcluded = false
    var pendingSpeakerRows: Set<Int> = []
    /// 録音中に薄く表示する未確定の声の行。停止結果では空にする。
    var unconfirmedRows: Set<Int> = []
    var timeline = MeetingTimeline(startedAt: Date())
    var names = SpeakerNames()
    /// 最後に受け入れた一組だけを保持する。再描画で同じIDを再演せず、保存・回収には使わない。
    var speakerReveals: [SpeakerReveal] = []
    var speakers: [KikigakiConfig.Speaker] = []
    var participantsKey = ResolvedConfig.defaultParticipantsKey
    /// 一時停止中を除いた会議の経過秒。
    var elapsed: Double = 0
    var markdownURL: URL?
    var message: String?
    var saved = false
    /// 録音中の途中保存の失敗。成功した途中保存はヘッダーに出さない。次の成功と停止で消す
    var interimSaveWarning: String?
    /// ヘッダーの1行と赤で出すか。保存成功の通知は出さず、途中保存の失敗はほかの通知より先に置く
    var headerMessage: (text: String, isError: Bool) {
        var message = self.message ?? ""
        if saved, message.hasPrefix("保存:") {
            message = message.components(separatedBy: " / ").dropFirst().joined(separator: " / ")
        }
        let text = [interimSaveWarning, message.isEmpty ? nil : message].compactMap { $0 }.joined(separator: " / ")
        return (text, interimSaveWarning != nil || (state == .idle && !saved && !message.isEmpty))
    }
    var handoffMessage: String?
    var handoffFailed = false
    var detectedSpeakerSlots: [Int] = []
    var speakerMapping: [Int: Int] = [:]
    var speakerOverrides: [Int: Int] = [:]
    var nextDiarizationEnabled = true
    /// 本文のある会議を優先する。停止後に次回設定を変えてもヘッダーを塗り替えない。
    var displayedDiarizationEnabled: Bool {
        markdownURL != nil || state != .idle ? names.diarizationEnabled : nextDiarizationEnabled
    }
    var canChangeDiarization: Bool { state == .idle }

    /// 音声ファイルの書き起こしの音源。書き起こし中と、その結果を表示している間だけ持つ。仕様は docs/audio-file.md
    var audioFile: AudioFile?
    /// 書き起こし中は、録音の操作のうち時間の流れに依存するものを止める
    var transcribingFile: Bool { audioFile != nil && state != .idle }
    /// 書き起こしを保存した後の仕上げ。「完了」までは話者を決めてAIへ頼める
    var reviewingFile = false

    var canSubmitTyped: Bool { (state == .recording || state == .paused) && !transcribingFile }
    var canPauseOrResume: Bool { state.canPauseOrResume && !transcribingFile }
    var voiceQuestionPlaceholder: String {
        let last = utterances.lastIndex(where: { $0.kind == .voice })
        if tentativeExcluded || (tentativeText == nil && last.map { excludedRows.contains($0) } == true) {
            return "末尾の声は小音量のため除外されます。問いを入力してください"
        }
        return tentativeText ?? last.flatMap { excludedRows.contains($0) ? nil : utterances[$0].text } ?? "空欄なら声の末尾を送ります"
    }
    /// 音声消費が遅れていても、投稿済みの位置までを表示範囲に含める。
    var contextEnd: Double { max(elapsed, utterances.filter { $0.kind == .typed }.map(\.start).max() ?? 0) }
    var contextEndClock: String {
        if let latest = utterances.filter({ $0.kind == .typed }).compactMap(\.postedAt).max(),
           latest > timeline.date(at: contextEnd) {
            return MeetingTimeline(startedAt: latest).clock(at: 0, seconds: true)
        }
        return timeline.clock(at: contextEnd, seconds: true)
    }

    var canShare: Bool {
        markdownURL != nil && (state == .recording || state == .paused || state == .idle)
    }
    var canCopy: Bool { canShare && !includedUtterances.isEmpty }

    /// AIへ新しく依頼を出せるのは録音中と一時停止中だけ。停止後はherdrのペインを閉じるので、
    /// 会議が終わった後の相談は送らない(自動の「最後の1回」はこの入口を通らない)。
    /// 例外として、音声ファイルの仕上げ中は保存後でも送れる。「完了」でペインを閉じる。
    var canSubmitAI: Bool {
        markdownURL != nil && ((state == .recording || state == .paused) && !transcribingFile || reviewingFile)
    }

    /// 自動の段のメニューから即時送信する入口。
    var canFireAutomatic: Bool {
        aiSchedule.active && aiSchedule.nextFire != nil && aiSchedule.canFireNow
            && ai?.isPreparing != true
            && ai?.conversation?.questions.contains { $0.isAwaitingResult } != true
    }
}
