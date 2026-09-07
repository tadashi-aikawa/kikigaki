import Foundation

/// 音声の判定が済んだ境界で手入力を混ぜる。音声処理へ渡す配列は作らない。
public enum TranscriptEntries {
    public struct Merged: Equatable, Sendable {
        public let utterances: [Utterance]
        public let pendingSpeakerRows: Set<Int>
    }

    public static func merge(voice: [Utterance], typed: [Utterance], timeline: MeetingTimeline,
                             pendingVoiceRows: Set<Int> = []) -> Merged {
        // 呼び出し側に併合済みの行が混ざっても落とさず、由来で正しい列へ戻す。
        // offsetは元のvoice配列の添字を保ち、typed列由来の声にはpendingを付けない。
        let all = voice + typed
        let voices = all.enumerated().filter { $0.element.kind == .voice }.sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }
        let entries = all.enumerated().filter { $0.element.kind == .typed }.sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }
        var result: [Utterance] = []
        result.reserveCapacity(voice.count + typed.count)
        var pending: Set<Int> = []
        var v = 0, t = 0
        // 2列を併合してtypedの投稿順を守る。壁時計が戻ってもtyped同士を並べ替えない。
        while v < voices.count || t < entries.count {
            let takeVoice: Bool
            if v == voices.count { takeVoice = false }
            else if t == entries.count { takeVoice = true }
            else {
                let voice = voices[v].element, typed = entries[t].element
                takeVoice = voice.start == typed.start
                    ? TranscriptRenderer.date(for: voice, timeline: timeline) <= TranscriptRenderer.date(for: typed, timeline: timeline)
                    : voice.start < typed.start
            }
            if takeVoice {
                if voices[v].offset < voice.count, pendingVoiceRows.contains(voices[v].offset) { pending.insert(result.count) }
                result.append(voices[v].element)
                v += 1
            } else {
                result.append(entries[t].element)
                t += 1
            }
        }
        return Merged(utterances: result, pendingSpeakerRows: pending)
    }
}
