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
        let lines = meeting.utterances.enumerated().map { index, utterance in
            Line(date: TranscriptRenderer.date(for: utterance, timeline: meeting.timeline), kind: 0, order: index,
                 text: "- " + TranscriptRenderer.line(utterance, names: meeting.names, timeline: meeting.timeline, timeZone: timeZone))
        }
        var marks: [Line] = []
        var attached: [Int: [Line]] = [:]
        for question in ai.questions {
            let number = question.request.number
            if let sent = question.sendAttemptedAt {
                let label = (question.state == .deliveryUnknown ? "AIへ・送達不明" : "AIへ")
                    + (question.request.trigger == .scheduled ? "(自動)" : "")
                let line = Line(date: sent, kind: 1, order: number,
                    text: "- [\(stamp(sent, relativeTo: meeting.startedAt, timeZone: timeZone))] \(label) #\(number) → AIとのやりとり")
                if let index = question.request.voiceAnchorIndex(in: meeting.utterances) { attached[index, default: []].append(line) }
                else { marks.append(line) }
            }
            if let result = question.result, let received = question.resultReceivedAt {
                let label = result.kind == .needsInput ? "AIからの確認" : result.kind == .failed ? "AI失敗" : "AIから"
                marks.append(Line(date: received, kind: 2, order: question.resultOrder ?? 0,
                    text: "- [\(stamp(received, relativeTo: meeting.startedAt, timeZone: timeZone))] \(label) #\(number) → AIとのやりとり"))
            }
        }
        marks.sort {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            return $0.order < $1.order
        }
        // 会話行は音声位置順の正本を保つ。postedAtで全文をsortすると、replayや
        // 壁時計の変更時に手入力だけ末尾へ飛ぶため、AIの印だけ日時順で差し込む。
        var rendered: [String] = []
        var markIndex = 0
        for line in lines {
            while markIndex < marks.count, marks[markIndex].date < line.date {
                rendered.append(marks[markIndex].text)
                markIndex += 1
            }
            rendered.append(line.text)
            rendered += attached[line.order, default: []].sorted {
                $0.date == $1.date ? $0.order < $1.order : $0.date < $1.date
            }.map(\.text)
        }
        rendered += marks.dropFirst(markIndex).map(\.text)
        return rendered
    }

    public static func section(_ conversation: AIConversation, timeZone: TimeZone = .current) -> String {
        guard !conversation.questions.isEmpty else { return "" }
        let generation = conversation.questions.map { $0.request.envelope.participant.sessionGeneration }.max() ?? 1
        var lines = ["## AIとのやりとり"]
        for question in conversation.questions {
            let request = question.request
            let envelope = request.envelope
            let participant = envelope.participant
            lines += ["", "### AI #\(request.number)", ""]
            if let sent = question.sendAttemptedAt {
                lines.append("- 送信: " + date(sent, timeZone: timeZone) + (request.trigger == .scheduled ? " (自動)" : ""))
            }
            lines.append("- 宛先: " + oneLine(participant.participantName))
            lines.append("- 送信文: 「" + oneLine(request.displayQuestion.isEmpty ? "会話末尾の送信文" : request.displayQuestion) + "」")
            let range = envelope.readLineCount == 0 ? "読む行数0" : "\(envelope.readStartLine)〜\(envelope.totalLineCount)行"
            let times = request.timeRange.map { "(\($0.start)〜\($0.end))" } ?? ""
            lines.append("- 対象: \(range)\(times)" + (participant.tentativeTail == nil ? "" : "。暫定末尾を含む"))
            lines.append("- 作業許可: " + (participant.workAllowed ? "あり" : "なし"))
            if let accepted = question.acceptance { lines.append("- 受領: " + date(accepted.recordedAt, timeZone: timeZone)) }
            if let result = question.result {
                lines.append("- 返事: " + date(result.recordedAt, timeZone: timeZone))
                if question.cancelledAt != nil { lines.append("- 補足: 取消後の返事") }
                if participant.sessionGeneration < generation { lines.append("- 補足: 旧接続からの返事") }
                if AIQuestion.isAnswered(question, in: conversation.questions) { lines.append("- 確認: 返答済み") }
                if result.kind == .needsInput { lines.append("- 状態: 確認待ち") }
                if result.kind == .failed { lines.append("- 状態: 失敗") }
                lines += ["", "#### 返事", "", result.body ?? ""]
            } else {
                lines.append("- 状態: " + label(question.state))
                if let failure = question.failure { lines += ["", "#### 返事", "", failure] }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func label(_ state: AIQuestionState) -> String {
        switch state {
        case .prepared: return "送信準備済み"
        case .submitted: return "受領未確認"
        case .accepted: return "返事待ち"
        case .needsInput: return "確認待ち"
        case .answered: return "返事済み"
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
