import Foundation

/// requestへ固定する候補。人の候補UIと違い、参加者があれば台帳・履歴を混ぜない。
public struct SpeakerIdentification: Codable, Equatable, Sendable {
    public let unresolved: [String]
    public let candidates: [String]
    /// 候補名の出どころ。議事録の参加者はその会議にいた人、台帳とよく使う名前はいたとは限らない。
    /// 確度の低い推定に候補名を使えるのは参加者のときだけ。欠損の旧envelopeは使えない側に倒す。
    public let origin: Origin?
    public enum Origin: String, Codable, Sendable { case participants, ledger }
    /// `unresolved` のうち、確度の低い推定で付いている枠と今の名前。AIはこれを見て推定し直す。
    public let tentative: [String: String]?
    /// `tentative` の枠ごとの、送った時点の割当元のイベントID。名前が変わって元へ戻った後に、古い依頼から上書きさせないため。
    /// AIは読まなくてよい。欠損の旧envelopeは、名前の付いた枠を推定し直せない側に倒す。
    public let tentativeEvents: [String: String]?
    private enum CodingKeys: String, CodingKey {
        case unresolved, candidates, origin, tentative, tentativeEvents = "tentative_events"
    }
    public init(unresolved: [String], candidates: [String], origin: Origin? = nil, tentative: [String: String]? = nil,
                tentativeEvents: [String: String]? = nil) {
        self.unresolved = unresolved; self.candidates = candidates; self.origin = origin; self.tentative = tentative
        self.tentativeEvents = tentativeEvents
    }
    /// 確度の低い推定に使ってよい候補名
    public var lowConfidenceCandidates: [String] { origin == .participants ? candidates : [] }
    public static func make(names: SpeakerNames, detected: [Int], mapping: [Int: Int],
                            participants: [String], speakers: [KikigakiConfig.Speaker], frequent: [String]) -> Self? {
        let slots = names.revisableSlots(detected: detected, mapping: mapping)
        guard !slots.isEmpty else { return nil }
        var seen = Set<String>()
        let source = participants.isEmpty ? speakers.map(\.name) + frequent : participants
        let candidates = source.map(SpeakerNames.normalized).filter {
            AIValidation.singleLine($0) && seen.insert($0).inserted
        }
        let held = slots.filter(names.isTentative)
        let tentative = Dictionary(uniqueKeysWithValues: held.map { (SpeakerNames.letter(for: $0), names.name(for: $0)) })
        let events = Dictionary(uniqueKeysWithValues: held.compactMap { slot in
            names.attributions[slot].map { (SpeakerNames.letter(for: slot), $0.event.eventID) }
        })
        return .init(unresolved: slots.map(SpeakerNames.letter), candidates: candidates,
                     origin: participants.isEmpty ? .ledger : .participants, tentative: tentative.isEmpty ? nil : tentative,
                     tentativeEvents: events.isEmpty ? nil : events)
    }
    public func validate() throws {
        guard !unresolved.isEmpty, Set(unresolved).count == unresolved.count,
              unresolved.allSatisfy(SpeakerNames.letters.contains),
              Set(candidates).count == candidates.count,
              candidates.allSatisfy({ AIValidation.singleLine($0) && SpeakerNames.normalized($0) == $0 }),
              (tentative ?? [:]).allSatisfy({ unresolved.contains($0.key) && AISpeakerEvent.validName($0.value) }),
              Set((tentativeEvents ?? [:]).keys).isSubset(of: Set((tentative ?? [:]).keys)) else {
            throw AIError.invalid("speaker identification")
        }
    }
}

public enum SpeakerIdentificationPrompt {
    public static let builtIn = """
    ## 話者名の割当
    participant.speaker_identification があるときだけ、通常の依頼に加えて話者名を割り当ててください。
    unresolved の枠が対象です。読んだ会話の流れから、その枠の話者が誰かを推定してください。
    根拠には、本人の名乗り、名前で呼ばれて応答した発言、名前を挙げて話を振られた流れ、ほかの人の呼びかけや話題の受け答えを使えます。
    名前は candidates か、会話の本文に出てきた人名から選びます。役割名や、会話に出てこない名前は付けないでください。
    同じ名前を複数の枠へ付けないでください。
    決め手があれば、--confidence を付けずに返してください。初めて付ける枠でも同じです。決め手は、その枠の話者が本人として応じたと会話から判断できることです。
    例は、自分で名乗った、名前で呼ばれて返事をした、その人自身の発言や仕事を問われて自分のこととして答えた、です。呼びかけの直後に話した、名前を含む行がある、という順番や名前の有無だけでは決め手になりません。
    決め手が無くても、ほかの名前より当てはまる根拠がある名前は返してください。そのときは speaker に --confidence low を付けます。人が確かめて直します。
    会話の中で立場や役割が1人だけの枠は、その立場の人の名前を確度低で付けてかまいません。例は、ほかの人と違って解説や司会を続けている枠です。
    ただし、その名前の人がこの会話に参加し、その立場を担っていると読めるときに限ります。話題に出ただけの人の名前は付けません。
    確信が低いときに使える名前は、会話の本文に出てきた人名と、origin が participants のときの candidates だけです。
    origin が ledger の candidates のうち会話の本文に出てこない名前は、名乗りや名前で呼ばれた応答のような確かな根拠があるときだけ使います。
    同じ役割や立場の人が複数いて、どの枠が誰かを区別する根拠が無いときは、その枠に名前を付けないでください。五分五分の決め打ちはしません。
    返さないのは、使える名前の中に当てはまるものが無い枠と、どの名前か区別できない枠です。
    tentative にある枠は、前に確度の低い推定で付けた名前です。依頼のたびに見直し、枠ごとに確定・変更・据え置きのどれかを決めてください。
    確定は決め手が見つかったときで、--confidence を付けずに同じ名前を返します。変更は別の名前の決め手が見つかったときで、その名前を返します。据え置きは speaker を呼びません。
    決めた結果は、reply の本文に枠ごとに1行で書いてください。元の依頼に、短くまとめる、報告は「完了」だけ、のような指定があっても、この1行は省きません。例は「話者B 田中: 確定([14:05:10] 自分の担当を問われて答えた)」「話者A 佐藤: 据え置き」です。
    この見直しに限り、transcript_path の read_start_line より前の行も読み直してかまいません。指定範囲を越えて読まない決まりの例外です。
    2つの枠の名前を入れ替えるときは、両方の枠を返してください。
    accept の後、progress --replying と reply の前に、該当する枠ごとに同梱CLIの speaker を呼んでください。作業許可が無効でも speaker は返せます。
    --slot は unresolved の A〜H、--name は選んだ名前を使います。--session、--request、--token はこの依頼の固定値です。
    根拠は会話の行を [HH:MM:SS] 付きで引用し、そう推定した理由を1文添えて stdin へ渡してください。根拠はUTF-8で2 KiB以内です。
    """
    public static func compose(question: String, identification: SpeakerIdentification?) -> String {
        guard identification != nil else { return question }
        return question + (question.isEmpty ? "" : "\n\n") + builtIn
    }
}

/// 別イベント。返事・受領・進行・宛先ボタンの状態には数えない。
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
    /// AIの申告する確度。欠損は確かな推定で、旧イベントもそう読む。
    public let confidence: Confidence?
    public enum Confidence: String, Codable, Sendable { case high, low }
    public var isLowConfidence: Bool { confidence == .low }
    public var filename: String { "\(requestID.uuidString).speaker.\(slot).json" }

    public init(request: AIRequest, slot: String, name: String, evidence: String, recordedAt: Date,
                confidence: Confidence? = nil) throws {
        schemaVersion = 1; kind = "speaker"; self.slot = slot; self.name = SpeakerNames.normalized(name)
        self.evidence = evidence; self.recordedAt = recordedAt; self.confidence = confidence
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
              fixed.unresolved.contains(slot), Self.validName(name) else { throw AIError.mismatch }
        try AIValidation.text(evidence, limit: Self.evidenceBytes, nonempty: true)
    }
    /// 候補名に加え、会話の本文に出てきた人名も付けてよい。本文に出てきたかは取り込み時に会話の行で確かめる。
    /// ここでは名前として扱える形かだけを見る。
    public static let nameLimit = 64
    public static func validName(_ name: String) -> Bool {
        name == SpeakerNames.normalized(name) && AIValidation.singleLine(name) && name.count <= nameLimit
    }
    public func sameContent(as other: Self) -> Bool {
        // 再送の時刻は同一性に含めず、最初のイベントを保持する。
        schemaVersion == other.schemaVersion && eventID == other.eventID && kind == other.kind
            && meetingID == other.meetingID && requestID == other.requestID && snapshotID == other.snapshotID
            && sessionGeneration == other.sessionGeneration && slot == other.slot && name == other.name && evidence == other.evidence
            && isLowConfidence == other.isLowConfidence
    }
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", eventID = "event_id", kind, meetingID = "meeting_id"
        case requestID = "request_id", snapshotID = "snapshot_id", sessionGeneration = "session_generation"
        case recordedAt = "recorded_at", slot, name, evidence, confidence
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
    private var confidenceNote: String { event.isLowConfidence ? "(確度: 低)" : "" }
    public var tooltip: String { "\(participant)の推定\(confidenceNote) · \(citation)" }
    public var detail: String { "\(participant)\(confidenceNote) \(citation)" }
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
    /// 会話の本文に名前が出てきたか。発言の本文だけを見て、整形した行の時刻と話者名は見ない。
    /// 話者名に「:」が入ると、整形した行からは本文の始まりを決められないため。
    public static func mentions(_ name: String, in texts: [String]) -> Bool {
        texts.contains { $0.contains(name) }
    }
    public static func exists(_ evidence: String, in lines: [String]) -> Bool {
        let stamps = timestamps(in: evidence)
        let available = Set(lines.compactMap(AIContextTimeRange.timestamp))
        return !stamps.isEmpty && stamps.allSatisfy(available.contains)
    }
}
