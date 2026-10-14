import Foundation
import KikigakiCore

/// 保存物には入れない、その場で受け入れたAI割当の知らせ。
struct SpeakerReveal: Equatable {
    let id: String
    let slot: Int
    let oldName: String
    let name: String
    let participant: String
    let receivedAt: Date
    var message: String { "\(oldName) → \(name)(\(participant)の推定)" }

    /// 人の改名・統合・再判定では由来が増えない。停止後の割当は保存しても知らせない。
    static func changes(from previous: SpeakerNames, to current: SpeakerNames,
                        state: RecordingState, now: Date = Date()) -> [SpeakerReveal] {
        guard state == .recording || state == .paused else { return [] }
        return current.attributions.keys.sorted().compactMap { slot in
            guard let attribution = current.attributions[slot],
                  previous.attributions[slot] != attribution,
                  previous.name(for: slot) != current.name(for: slot) else { return nil }
            return SpeakerReveal(id: attribution.event.eventID, slot: slot, oldName: previous.name(for: slot),
                name: current.name(for: slot), participant: attribution.participant, receivedAt: now)
        }
    }
}
