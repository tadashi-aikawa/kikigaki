import Foundation

public enum AIMarkdown {
    private struct Line {
        let date: Date
        let kind: Int // 同時刻は人間、送信印、返送印の順
        let order: Int
        let text: String
    }

    static func transcriptLines(_ meeting: MeetingMarkdown.Meeting, timeZone: TimeZone) -> [String] {
        // 既存の手動保存では発話順も含めて従来どおり。
        guard let ai = meeting.ai, !ai.questions.isEmpty else {
            return meeting.utterances.map { "- " + TranscriptRenderer.line($0, names: meeting.names, timeline: meeting.timeline, timeZone: timeZone) }
        }
        var lines = meeting.utterances.enumerated().map { index, utterance in
            Line(date: meeting.timeline.date(at: utterance.start), kind: 0, order: index,
                 text: "- " + TranscriptRenderer.line(utterance, names: meeting.names, timeline: meeting.timeline, timeZone: timeZone))
        }
        for question in ai.questions {
            let number = question.request.number
            if let sent = question.sendAttemptedAt {
                let label = question.state == .deliveryUnknown ? "AIへ質問・送達不明" : "AIへ質問"
                lines.append(Line(date: sent, kind: 1, order: number,
                    text: "- [\(stamp(sent, relativeTo: meeting.startedAt, timeZone: timeZone))] \(label) Q\(number) → AIとのやりとり"))
            }
            if let result = question.result, let received = question.resultReceivedAt {
                let label = result.kind == .needsInput ? "AI確認質問" : result.kind == .failed ? "AI失敗" : "AI回答"
                lines.append(Line(date: received, kind: 2, order: question.resultOrder ?? 0,
                    text: "- [\(stamp(received, relativeTo: meeting.startedAt, timeZone: timeZone))] \(label) Q\(number) → AIとのやりとり"))
            }
        }
        return lines.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            return $0.order < $1.order
        }.map(\.text)
    }

    public static func section(_ conversation: AIConversation, timeZone: TimeZone = .current) -> String {
        guard !conversation.questions.isEmpty else { return "" }
        let generation = conversation.questions.map { $0.request.envelope.participant.sessionGeneration }.max() ?? 1
        var lines = ["## AIとのやりとり"]
        for question in conversation.questions {
            let request = question.request
            let envelope = request.envelope
            let participant = envelope.participant
            lines += ["", "### AI Q\(request.number)", ""]
            if let sent = question.sendAttemptedAt { lines.append("- 送信: " + date(sent, timeZone: timeZone)) }
            lines.append("- 宛先: " + oneLine(participant.participantName))
            lines.append("- 問い: 「" + oneLine(request.displayQuestion.isEmpty ? "会話末尾の問い" : request.displayQuestion) + "」")
            let range = envelope.readLineCount == 0 ? "読む行数0" : "\(envelope.readStartLine)〜\(envelope.totalLineCount)行"
            let times = request.timeRange.map { "(\($0.start)〜\($0.end))" } ?? ""
            lines.append("- 対象: \(range)\(times)" + (participant.tentativeTail == nil ? "" : "。暫定末尾を含む"))
            lines.append("- 作業許可: " + (participant.workAllowed ? "あり" : "なし"))
            if let accepted = question.acceptance { lines.append("- 受領: " + date(accepted.recordedAt, timeZone: timeZone)) }
            if let result = question.result {
                lines.append("- 回答: " + date(result.recordedAt, timeZone: timeZone))
                if question.cancelledAt != nil { lines.append("- 補足: 取消後の回答") }
                if participant.sessionGeneration < generation { lines.append("- 補足: 旧接続からの回答") }
                if question.answeredByRequestID != nil { lines.append("- 確認: 返答済み") }
                if result.kind == .needsInput { lines.append("- 状態: 確認待ち") }
                if result.kind == .failed { lines.append("- 状態: 失敗") }
                lines += ["", "#### 回答", "", result.body ?? ""]
            } else {
                lines.append("- 状態: " + label(question.state))
                if let failure = question.failure { lines += ["", "#### 回答", "", failure] }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func label(_ state: AIQuestionState) -> String {
        switch state {
        case .prepared: return "送信準備済み"
        case .submitted: return "受領未確認"
        case .accepted: return "回答待ち"
        case .needsInput: return "確認待ち"
        case .answered: return "回答済み"
        case .failed: return "失敗"
        case .deliveryUnknown: return "送達不明"
        case .cancelled: return "取消"
        }
    }

    private static func oneLine(_ text: String) -> String { text.components(separatedBy: .newlines).joined(separator: " ") }
    private static func date(_ value: Date, timeZone: TimeZone) -> String {
        formatted(value, format: "yyyy-MM-dd HH:mm:ss Z", timeZone: timeZone)
    }
    private static func stamp(_ value: Date, relativeTo start: Date, timeZone: TimeZone) -> String {
        let sameDay = formatted(value, format: "yyyy-MM-dd", timeZone: timeZone) == formatted(start, format: "yyyy-MM-dd", timeZone: timeZone)
        return formatted(value, format: sameDay ? "HH:mm:ss" : "yyyy-MM-dd HH:mm:ss", timeZone: timeZone)
    }
    private static func formatted(_ value: Date, format: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone; formatter.dateFormat = format
        return formatter.string(from: value)
    }
}
