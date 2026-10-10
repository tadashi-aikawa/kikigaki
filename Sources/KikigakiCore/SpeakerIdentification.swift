import Foundation

/// requestへ固定する候補。人の候補UIと違い、参加者があれば台帳・履歴を混ぜない。
public struct SpeakerIdentification: Codable, Equatable, Sendable {
    public let unresolved: [String]
    public let candidates: [String]
    public init(unresolved: [String], candidates: [String]) {
        self.unresolved = unresolved; self.candidates = candidates
    }
    public static func make(names: SpeakerNames, detected: [Int], mapping: [Int: Int],
                            participants: [String], speakers: [KikigakiConfig.Speaker], frequent: [String]) -> Self? {
        let slots = names.unresolvedSlots(detected: detected, mapping: mapping)
        guard !slots.isEmpty else { return nil }
        var seen = Set<String>()
        let source = participants.isEmpty ? speakers.map(\.name) + frequent : participants
        let candidates = source.map(SpeakerNames.normalized).filter {
            AIValidation.singleLine($0) && seen.insert($0).inserted
        }
        return .init(unresolved: slots.map(SpeakerNames.letter), candidates: candidates)
    }
    public func validate() throws {
        guard !unresolved.isEmpty, Set(unresolved).count == unresolved.count,
              unresolved.allSatisfy(SpeakerNames.letters.contains),
              Set(candidates).count == candidates.count,
              candidates.allSatisfy({ AIValidation.singleLine($0) && SpeakerNames.normalized($0) == $0 }) else {
            throw AIError.invalid("speaker identification")
        }
    }
}

public enum SpeakerIdentificationPrompt {
    public static let builtIn = """
    ## 話者名の割当
    participant.speaker_identification があるときだけ、通常の依頼に加えて話者名を割り当ててください。
    新しく読んだ範囲に直接の根拠がある未確定の枠だけが対象です。直接の根拠は本人の名乗り、または名前で呼ばれて直後に応答した発言です。
    役割・口調・消去法から名前を類推してはいけません。候補名の中で一意に対応するときだけ返し、確信が無ければ何も返さないでください。
    accept の後、progress --replying と reply の前に、該当する枠ごとに同梱CLIの speaker を呼んでください。作業許可が無効でも speaker は返せます。
    --slot は unresolved の A〜H、--name は candidates の名前を使います。--session、--request、--token はこの依頼の固定値です。
    根拠は新しく読んだ会話の行を [HH:MM:SS] 付きで引用し、stdin へ渡してください。根拠はUTF-8で2 KiB以内です。
    """
    public static func compose(question: String, identification: SpeakerIdentification?) -> String {
        guard identification != nil else { return question }
        return question + (question.isEmpty ? "" : "\n\n") + builtIn
    }
}

/// 別イベント。返事・受領・進行・ロボットの状態には数えない。
public struct AISpeakerEvent: Codable, Equatable, Sendable {
    public static let evidenceBytes = 2048
    public let schemaVersion: Int
    public let eventID: String
    public let kind: String
    public let meetingID: UUID
    public let requestID: UUID
    public let sessionGeneration: Int
    public let snapshotID: UUID
    public let recordedAt: Date
    public let slot: String
    public let name: String
    public let evidence: String
    public var filename: String { "\(requestID.uuidString).speaker.\(slot).json" }

    public init(request: AIRequest, slot: String, name: String, evidence: String, recordedAt: Date) throws {
        schemaVersion = 1; kind = "speaker"; self.slot = slot; self.name = SpeakerNames.normalized(name)
        self.evidence = evidence; self.recordedAt = recordedAt
        requestID = request.id; meetingID = request.envelope.meetingID; snapshotID = request.envelope.snapshotID
        sessionGeneration = request.envelope.participant.sessionGeneration
        eventID = "\(requestID.uuidString)/speaker/\(slot)"
        try validate(for: request)
    }
    public func validate(for request: AIRequest) throws {
        try request.validate()
        guard schemaVersion == 1, kind == "speaker", meetingID == request.envelope.meetingID,
              requestID == request.id, snapshotID == request.envelope.snapshotID,
              sessionGeneration == request.envelope.participant.sessionGeneration,
              eventID == "\(requestID.uuidString)/speaker/\(slot)", recordedAt.timeIntervalSince1970.isFinite,
              let fixed = request.envelope.participant.speakerIdentification,
              fixed.unresolved.contains(slot), fixed.candidates.contains(name),
              name == SpeakerNames.normalized(name) else { throw AIError.mismatch }
        try AIValidation.text(evidence, limit: Self.evidenceBytes, nonempty: true)
    }
    public func sameContent(as other: Self) -> Bool {
        // 再送の時刻は同一性に含めず、最初のイベントを保持する。
        schemaVersion == other.schemaVersion && eventID == other.eventID && kind == other.kind
            && meetingID == other.meetingID && requestID == other.requestID && snapshotID == other.snapshotID
            && sessionGeneration == other.sessionGeneration && slot == other.slot && name == other.name && evidence == other.evidence
    }
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", eventID = "event_id", kind, meetingID = "meeting_id"
        case requestID = "request_id", snapshotID = "snapshot_id", sessionGeneration = "session_generation"
        case recordedAt = "recorded_at", slot, name, evidence
    }
}

public struct SpeakerAttribution: Codable, Equatable, Sendable {
    public let event: AISpeakerEvent
    public let participant: String
    public var evidenceLine: String { event.evidence.components(separatedBy: .newlines).joined(separator: " ") }
    private var citation: String {
        guard let stamp = SpeakerEvidence.timestamps(in: event.evidence).first,
              let range = evidenceLine.range(of: "[\(stamp)]") else { return "「\(evidenceLine)」" }
        let quote = evidenceLine[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(stamp)「\(quote)」"
    }
    public var tooltip: String { "\(participant)の推定 · \(citation)" }
    public var detail: String { "\(participant) \(citation)" }
    public init(event: AISpeakerEvent, participant: String) { self.event = event; self.participant = participant }
}

/// 内容の意味や本人性はモデルの責務。アプリは引用時刻の実在だけを機械判定する。
public enum SpeakerEvidence {
    public static func timestamps(in evidence: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"\[\d{2}:\d{2}:\d{2}\]"#)
        let source = evidence as NSString
        return regex.matches(in: evidence, range: NSRange(location: 0, length: source.length)).map {
            String(source.substring(with: $0.range).dropFirst().dropLast())
        }
    }
    public static func exists(_ evidence: String, in lines: [String]) -> Bool {
        let stamps = timestamps(in: evidence)
        let available = Set(lines.compactMap(AIContextTimeRange.timestamp))
        return !stamps.isEmpty && stamps.allSatisfy(available.contains)
    }
}
