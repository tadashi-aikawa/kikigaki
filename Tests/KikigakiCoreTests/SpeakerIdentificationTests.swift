import Foundation
import Testing
@testable import KikigakiCore

@Suite struct SpeakerIdentificationTests {
    private func participants(_ names: [String]) -> SpeakerIdentification {
        .init(unresolved: ["A", "B", "C"], candidates: names, origin: .participants)
    }
    /// 実録 2026-09-26_0237 の受入試験で、会話に出てこない台帳の「タダシ」が話者Cへ消去法で付いた。
    @Test(arguments: [SpeakerIdentification.Origin.ledger, nil])
    func 確度の低い推定は台帳の候補名を使えず確かな推定なら使える(_ origin: SpeakerIdentification.Origin?) throws {
        let fixed = SpeakerIdentification(unresolved: ["C"], candidates: ["タダシ"], origin: origin)
        let r = try request(fixed: fixed)
        let lines = ["[02:38:33] 話者C: いや、まず仕事なんか思い通りいかないですよ。"]
        let texts = ["いや、まず仕事なんか思い通りいかないですよ。"]
        let low = try AISpeakerEvent(request: r, slot: "C", name: "タダシ", evidence: "[02:38:33] 相談役なので最有力",
                                     recordedAt: Date(), confidence: .low)
        var names = SpeakerNames()
        #expect(throws: (any Error).self) {
            try names.identify(low, participant: "迅雷", fixed: fixed, detected: [2], mapping: [:], lines: lines, texts: texts)
        }
        let sure = try AISpeakerEvent(request: r, slot: "C", name: "タダシ", evidence: "[02:38:33] 名乗っている", recordedAt: Date())
        try names.identify(sure, participant: "迅雷", fixed: fixed, detected: [2], mapping: [:], lines: lines, texts: texts)
        #expect(names.name(for: 2) == "タダシ")
        // 台帳の名前でも、会話の本文に出てくれば本文の人名として確度の低い推定に使える。
        var mentioned = SpeakerNames()
        try mentioned.identify(low, participant: "迅雷", fixed: fixed, detected: [2], mapping: [:], lines: lines,
                               texts: texts + ["タダシさん、どうですか。"])
        #expect(mentioned.name(for: 2) == "タダシ")
    }
    /// 1回目に聞き手2人が逆に付き、後の会話で入れ替えられる。
    @Test func 確度の低い推定は次の依頼で推定し直せ入れ替えもできる() throws {
        let people = ["佐藤花子", "田中太郎", "鈴木一郎", "伊藤健太"]
        let lines = ["[10:00:00] 話者C: 伊藤さん、どう思います?", "[10:05:00] 話者D: 鈴木さんの言う通りですね。"]
        let texts = ["伊藤さん、どう思います?", "鈴木さんの言う通りですね。"]
        var names = SpeakerNames()
        let first = try request(fixed: .init(unresolved: ["C", "D"], candidates: people, origin: .participants))
        for (slot, name) in [("C", "鈴木一郎"), ("D", "伊藤健太")] {
            let event = try AISpeakerEvent(request: first, slot: slot, name: name, evidence: "[10:00:00] 推定", recordedAt: Date(), confidence: .low)
            try names.identify(event, participant: "迅雷", fixed: first.envelope.participant.speakerIdentification,
                               detected: [2, 3], mapping: [:], lines: lines, texts: texts)
        }
        // 次の依頼では、確度の低い推定の枠も今の名前付きでAIへ渡す。
        let fixed = try #require(SpeakerIdentification.make(names: names, detected: [2, 3], mapping: [:],
            participants: people, speakers: [], frequent: []))
        #expect(fixed.unresolved == ["C", "D"] && fixed.tentative == ["C": "鈴木一郎", "D": "伊藤健太"])
        let second = try request(fixed: fixed)
        for (slot, name) in [("C", "伊藤健太"), ("D", "鈴木一郎")] {
            let event = try AISpeakerEvent(request: second, slot: slot, name: name, evidence: "[10:05:00] 後半の呼びかけ",
                                           recordedAt: Date(), confidence: .low)
            try names.identify(event, participant: "迅雷", fixed: fixed, detected: [2, 3], mapping: [:], lines: lines, texts: texts)
        }
        #expect(names.name(for: 2) == "伊藤健太" && names.name(for: 3) == "鈴木一郎")
        // 送った後に名前が変わって元へ戻ったら、その前に送った依頼は枠の名前も同名の枠も変えられない。
        let stale = try #require(SpeakerIdentification.make(names: names, detected: [2, 3], mapping: [:],
            participants: people, speakers: [], frequent: []))
        let staleRequest = try request(fixed: stale)
        for name in ["田中太郎", "伊藤健太"] {
            let fixed = try #require(SpeakerIdentification.make(names: names, detected: [2, 3], mapping: [:],
                participants: people, speakers: [], frequent: []))
            let event = try AISpeakerEvent(request: try request(fixed: fixed), slot: "C", name: name, evidence: "[10:05:00] 推定",
                                           recordedAt: Date(), confidence: .low)
            try names.identify(event, participant: "迅雷", fixed: fixed, detected: [2, 3], mapping: [:], lines: lines, texts: texts)
        }
        #expect(names.name(for: 2) == "伊藤健太" && stale.tentative?["C"] == "伊藤健太")
        for (slot, name) in [("C", "佐藤花子"), ("D", "伊藤健太")] {
            let event = try AISpeakerEvent(request: staleRequest, slot: slot, name: name, evidence: "[10:05:00] 推定",
                                           recordedAt: Date(), confidence: .low)
            #expect(throws: (any Error).self) {
                try names.identify(event, participant: "迅雷", fixed: stale, detected: [2, 3], mapping: [:], lines: lines, texts: texts)
            }
        }
        #expect(names.name(for: 2) == "伊藤健太" && names.name(for: 3) == "鈴木一郎")
        // 確かな推定へ上げた枠と、人が確かめた枠は、以後は推定し直さない。
        let again = try #require(SpeakerIdentification.make(names: names, detected: [2, 3], mapping: [:],
            participants: people, speakers: [], frequent: []))
        let third = try request(fixed: again)
        let sure = try AISpeakerEvent(request: third, slot: "C", name: "伊藤健太", evidence: "[10:00:00] 名前で呼ばれて応答",
                                      recordedAt: Date())
        try names.identify(sure, participant: "迅雷", fixed: again, detected: [2, 3], mapping: [:], lines: lines, texts: texts)
        names.confirm("鈴木一郎", for: 3)
        #expect(!names.isTentative(2) && !names.isTentative(3))
        #expect(names.revisableSlots(detected: [2, 3], mapping: [:]).isEmpty)
    }
    @Test func 確かな推定と人が確かめた名前は確度の低い推定で奪えない() throws {
        let people = ["鈴木一郎", "伊藤健太"]
        let lines = ["[10:00:00] 話者C: 伊藤です。"], texts = ["伊藤です。"]
        let fixed = SpeakerIdentification(unresolved: ["C", "D"], candidates: people, origin: .participants, tentative: ["D": "鈴木一郎"])
        let r = try request(fixed: fixed)
        var names = SpeakerNames()
        let sure = try AISpeakerEvent(request: r, slot: "C", name: "伊藤健太", evidence: "[10:00:00] 名乗り", recordedAt: Date())
        try names.identify(sure, participant: "迅雷", fixed: fixed, detected: [2, 3], mapping: [:], lines: lines, texts: texts)
        let steal = try AISpeakerEvent(request: r, slot: "D", name: "伊藤健太", evidence: "[10:00:00] 推定", recordedAt: Date(), confidence: .low)
        #expect(throws: (any Error).self) {
            try names.identify(steal, participant: "迅雷", fixed: fixed, detected: [2, 3], mapping: [:], lines: lines, texts: texts)
        }
        #expect(names.name(for: 2) == "伊藤健太")
        // 同じ依頼で確度の低い推定が同名を2枠へ返したら、先に取り込んだ枠が勝つ。
        let pair = SpeakerIdentification(unresolved: ["A", "B"], candidates: people, origin: .participants)
        let both = try request(fixed: pair)
        let lowFirst = try AISpeakerEvent(request: both, slot: "A", name: "鈴木一郎", evidence: "[10:00:00] 推定", recordedAt: Date(), confidence: .low)
        let lowSecond = try AISpeakerEvent(request: both, slot: "B", name: "鈴木一郎", evidence: "[10:00:00] 推定", recordedAt: Date(), confidence: .low)
        try names.identify(lowFirst, participant: "迅雷", fixed: pair, detected: [0, 1], mapping: [:], lines: lines, texts: texts)
        #expect(throws: (any Error).self) {
            try names.identify(lowSecond, participant: "迅雷", fixed: pair, detected: [0, 1], mapping: [:], lines: lines, texts: texts)
        }
        #expect(names.name(for: 0) == "鈴木一郎" && names.customName(for: 1) == nil)
        // 並行して送った別の依頼は、送った後に付いた名前を知らないので、枠の名前も同名の枠も奪えない。
        let parallel = try request(fixed: pair)
        for (slot, name) in [("A", "伊藤健太"), ("B", "鈴木一郎")] {
            let event = try AISpeakerEvent(request: parallel, slot: slot, name: name, evidence: "[10:00:00] 推定", recordedAt: Date(), confidence: .low)
            #expect(throws: (any Error).self) {
                try names.identify(event, participant: "迅雷", fixed: pair, detected: [0, 1], mapping: [:], lines: lines, texts: texts)
            }
        }
        #expect(names.name(for: 0) == "鈴木一郎" && names.customName(for: 1) == nil)
        #expect(throws: (any Error).self) {
            try SpeakerIdentification(unresolved: ["C"], candidates: [], tentative: ["D": "鈴木一郎"]).validate()
        }
    }
    @Test func 確度の低い推定でも議事録の参加者と会話の本文の人名は使える() throws {
        let fixed = participants(["次郎"])
        let r = try request(fixed: fixed)
        let lines = ["[02:37:56] 話者A: 山田さんからお願いします。", "[02:38:33] 話者C: いや、まず仕事なんか。"]
        let texts = ["山田さんからお願いします。", "いや、まず仕事なんか。"]
        var names = SpeakerNames()
        let fromParticipants = try AISpeakerEvent(request: r, slot: "C", name: "次郎", evidence: "[02:38:33] 残る参加者",
                                                  recordedAt: Date(), confidence: .low)
        try names.identify(fromParticipants, participant: "迅雷", fixed: fixed, detected: [0, 2], mapping: [:], lines: lines, texts: texts)
        let fromTranscript = try AISpeakerEvent(request: r, slot: "A", name: "山田", evidence: "[02:37:56] 呼ばれた名前",
                                                recordedAt: Date(), confidence: .low)
        try names.identify(fromTranscript, participant: "迅雷", fixed: fixed, detected: [0, 2], mapping: [:], lines: lines, texts: texts)
        #expect(names.name(for: 2) == "次郎" && names.name(for: 0) == "山田")
    }
    private func request(question: String = "質問", fixed: SpeakerIdentification? = .init(unresolved: ["A", "C"], candidates: ["タダシ", "田中"])) throws -> AIRequest {
        let meeting = UUID(), root = URL(fileURLWithPath: "/tmp/speaker-core")
        var history = try AIStreamHistory(meetingID: meeting)
        let snapshot = try history.prepare(lines: ["[14:05:10] 話者A: タダシです"], outputDirectory: root)
        let p = AIParticipantContext(streamID: snapshot.streamID, requestID: UUID(), sessionGeneration: 1,
            participantName: "迅雷", cliPath: "/tmp/helper", sessionPath: root.appendingPathComponent(
                ".kikigaki-context/\(meeting)/ai/sessions/1.json").path, requestToken: "token",
            question: question, capturedAt: Date(timeIntervalSince1970: 100), audioCutoffSeconds: 1, speakerIdentification: fixed)
        return try AIRequest(envelope: AIEnvelope(snapshot: snapshot, participant: p), number: 1,
                             voiceQuestion: "声の問い", snapshot: snapshot, voiceUtteranceStart: 0)
    }
    @Test func 未確定枠は検出と改名と人の確認と統合を反映する() {
        var names = SpeakerNames([1: "名前"])
        names.confirm("", for: 2)
        #expect(names.unresolvedSlots(detected: [7, 3, 2, 1, 0, 0, 8, -1], mapping: [3: 0]) == [0, 7])
        names.diarizationEnabled = false
        #expect(names.unresolvedSlots(detected: [0, 7], mapping: [:]).isEmpty)
        #expect(SpeakerIdentification.make(names: names, detected: [0], mapping: [:], participants: [], speakers: [], frequent: []) == nil)
    }
    @Test func 参加者があればその名前だけを候補にし無ければ台帳と履歴を使う() throws {
        let speakers: [KikigakiConfig.Speaker] = [.init(name: "台帳"), .init(name: "共通")]
        let participants = SpeakerSuggestions.participants(in: "---\nattendees: [田中, 田中, タダシ]\n---", key: "attendees")
        let first = try #require(SpeakerIdentification.make(names: SpeakerNames(), detected: [0, 2], mapping: [:],
            participants: participants, speakers: speakers, frequent: ["履歴", "共通"]))
        #expect(first == .init(unresolved: ["A", "C"], candidates: ["田中", "タダシ"], origin: .participants))
        #expect(first.lowConfidenceCandidates == ["田中", "タダシ"])
        let fallback = try #require(SpeakerIdentification.make(names: SpeakerNames(), detected: [0], mapping: [:],
            participants: [], speakers: speakers, frequent: ["履歴", "共通", " 台帳 "]))
        #expect(fallback.candidates == ["台帳", "共通", "履歴"])
        // 台帳とよく使う名前は、会議にいたとは限らない。確度の低い推定には使わない。
        #expect(fallback.origin == .ledger && fallback.lowConfidenceCandidates.isEmpty)
        #expect(SpeakerIdentification(unresolved: ["A"], candidates: ["旧"]).lowConfidenceCandidates.isEmpty)
    }
    @Test(arguments: ["", "質問"])
    func envelopeの任意キーと内蔵節と元の問いの表示を維持する(_ question: String) throws {
        let r = try request(question: question)
        let data = try AIJSON.encode(r.envelope)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let p = try #require(json["participant"] as? [String: Any])
        let fixed = try #require(p["speaker_identification"] as? [String: Any])
        #expect(fixed["unresolved"] as? [String] == ["A", "C"])
        #expect(r.envelope.participant.question.hasSuffix(SpeakerIdentificationPrompt.builtIn))
        #expect(r.displayQuestion == (question.isEmpty ? "声の問い" : question))
        #expect(r.envelope.participant.questionSource == (question.isEmpty ? .voice : .typed))
        #expect(r.voiceUtteranceStart == (question.isEmpty ? 0 : nil))
        #expect(try AIJSON.decode(AIRequest.self, from: AIJSON.encode(r)) == r)
        let old = try request(fixed: nil)
        #expect(!String(decoding: try AIJSON.encode(old.envelope), as: UTF8.self).contains("speaker_identification"))
        #expect(!old.envelope.participant.question.contains(SpeakerIdentificationPrompt.builtIn))
    }
    @Test(arguments: ["null", "invalid", "empty", "duplicate", "bad-slot"])
    func envelopeの不正な指定は拒否する(_ kind: String) throws {
        var p = try #require(JSONSerialization.jsonObject(with: AIJSON.encode(try request().envelope.participant)) as? [String: Any])
        switch kind {
        case "null": p["speaker_identification"] = NSNull()
        case "invalid": p["speaker_identification"] = "A"
        case "empty": p["speaker_identification"] = ["unresolved": [], "candidates": ["田中"]]
        case "duplicate": p["speaker_identification"] = ["unresolved": ["A", "A"], "candidates": ["田中"]]
        default: p["speaker_identification"] = ["unresolved": ["I"], "candidates": ["田中"]]
        }
        #expect(throws: (any Error).self) { try AIJSON.decode(AIParticipantContext.self, from: JSONSerialization.data(withJSONObject: p)) }
    }
    @Test(arguments: ["", "質問"])
    func 内蔵文面が改訂されても保存済みの問いを復元できる(_ question: String) throws {
        var p = try #require(JSONSerialization.jsonObject(with: AIJSON.encode(try request(question: question).envelope.participant)) as? [String: Any])
        p["question"] = question + "\n\n以前の内蔵文面"
        let restored = try AIJSON.decode(AIParticipantContext.self, from: JSONSerialization.data(withJSONObject: p))
        #expect(restored.userQuestion == question)
        #expect(restored.questionSource == (question.isEmpty ? .voice : .typed))
        p["original_question"] = nil
        #expect(throws: (any Error).self) { try AIJSON.decode(AIParticipantContext.self, from: JSONSerialization.data(withJSONObject: p)) }
    }
    @Test func 引用時刻はすべて実在する行に対応し不正な時刻を無視しない() {
        let lines = ["[14:05:10] 話者A: タダシです", "[14:05:11] 話者C: 田中です"]
        #expect(SpeakerEvidence.exists("[14:05:10] タダシです\n[14:05:11] 田中です", in: lines))
        for evidence in ["時刻なし", "[14:05:12] 存在しない", "[14:05:10] タダシです\n[99:99:99] 不正"] {
            #expect(!SpeakerEvidence.exists(evidence, in: lines))
        }
    }
    @Test func 内蔵文面を仕様書と機械照合する() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let doc = try String(contentsOf: repo.appendingPathComponent("docs/ai-participant.md"), encoding: .utf8)
        let start = try #require(doc.range(of: "````text\n"))
        let end = try #require(doc.range(of: "\n````", range: start.upperBound..<doc.endIndex))
        #expect(String(doc[start.upperBound..<end.lowerBound]) == SpeakerIdentificationPrompt.builtIn)
    }
    @Test func イベントの固定情報と名前とファイル名を検証する() throws {
        let r = try request()
        let event = try AISpeakerEvent(request: r, slot: "A", name: " タダシ ", evidence: "[14:05:10] タダシです", recordedAt: Date(timeIntervalSince1970: 100))
        #expect(event.eventID == "\(r.id)/speaker/A" && event.filename == "\(r.id).speaker.A.json")
        #expect(try AIInbox.decodeSpeaker(AIJSON.encode(event), filename: event.filename, for: r) == event)
        #expect(throws: AIError.mismatch) { try AIInbox.decodeSpeaker(AIJSON.encode(event), filename: "\(r.id).speaker.C.json", for: r) }
        #expect(throws: AIError.mismatch) { try event.validate(for: request()) }
    }
    @Test(arguments: ["タダシ", "別名", ""])
    func 人の確認は点を消して会議の間AIから除外しarchiveとstateへ残る(_ name: String) throws {
        let r = try request()
        let event = try AISpeakerEvent(request: r, slot: "A", name: "タダシ", evidence: "[14:05:10] タダシです", recordedAt: Date(timeIntervalSince1970: 100))
        var names = SpeakerNames()
        try names.identify(event, participant: "迅雷", fixed: participants(["タダシ"]), detected: [0], mapping: [:], lines: ["[14:05:10] 話者A: タダシです"], texts: ["タダシです"])
        #expect(names.attributions[0]?.tooltip == "迅雷の推定 · 14:05:10「タダシです」")
        #expect(names.unresolvedSlots(detected: [0], mapping: [:]).isEmpty)
        names.confirm(name, for: 0)
        #expect(names.humanTouched == [0] && names.attributions.isEmpty)
        #expect(throws: (any Error).self) {
            try names.identify(event, participant: "迅雷", fixed: participants(["タダシ"]), detected: [0], mapping: [:], lines: ["[14:05:10] 行"], texts: ["行"])
        }
        var conversation = AIConversation(meetingID: r.envelope.meetingID)
        try conversation.append(r); try conversation.recordSpeaker(event, names: names)
        let restored = try AIJSON.decode(AIConversation.self, from: AIJSON.encode(conversation))
        #expect(restored.speakerNames == names && restored.speakerAssignments == [event])
        let meeting = MeetingMarkdown.Meeting(startedAt: Date(), duration: 1, utterances: [], names: names)
        let archive = MeetingArchive(original: meeting, markdownURL: URL(fileURLWithPath: "/tmp/unused.md"))
        #expect(try AIJSON.decode(MeetingArchive.self, from: AIJSON.encode(archive)).original.names == names)
    }
    @Test func Markdownの話者行に出所を混ぜずAI節に割当を残す() throws {
        let r = try request()
        let event = try AISpeakerEvent(request: r, slot: "A", name: "タダシ", evidence: "[14:05:10] タダシです", recordedAt: Date())
        var names = SpeakerNames()
        try names.identify(event, participant: "迅雷", fixed: participants(["タダシ"]), detected: [0], mapping: [:], lines: ["[14:05:10] 行"], texts: ["行"])
        var conversation = AIConversation(meetingID: r.envelope.meetingID)
        try conversation.append(r); try conversation.recordSpeaker(event, names: names)
        let meeting = MeetingMarkdown.Meeting(startedAt: Date(), duration: 1,
            utterances: [.init(speaker: 0, start: 0, end: 1, text: "タダシです")], names: names, ai: conversation)
        let markdown = MeetingMarkdown.render(meeting)
        let speakerLine = try #require(markdown.components(separatedBy: "\n").first { $0.hasPrefix("- 話者:") })
        #expect(speakerLine == "- 話者: A=タダシ")
        #expect(SpeakerSuggestions.names(inSpeakerLine: speakerLine) == ["タダシ"])
        #expect(markdown.contains("- 話者の割当: A → タダシ(根拠: [14:05:10] タダシです)"))
    }
    /// 実録 2026-09-26_0237 の冒頭。話者Bは名前で振られて応答し、名前は候補に無く会話の本文にだけ出てくる。
    @Test func 候補に無くても会話の本文に出てきた人名なら付けられる() throws {
        let lines = ["[02:37:56] 話者A: 山田さんからのおみをこさんにおいただきたいと思います。",
                     "[02:38:02] 話者B: させていただいてもよろしいでしょうか。"]
        let r = try request(fixed: .init(unresolved: ["A", "B"], candidates: ["タダシ"]))
        let evidence = "[02:37:56] 山田さんからの…\n[02:38:02] させていただいても…\n名前で話を振られた直後に話し始めている"
        let event = try AISpeakerEvent(request: r, slot: "B", name: "山田", evidence: evidence, recordedAt: Date())
        var names = SpeakerNames()
        try names.identify(event, participant: "迅雷", fixed: participants(["タダシ"]), detected: [0, 1], mapping: [:], lines: lines,
                           texts: ["山田さんからのおみをこさんにおいただきたいと思います。", "させていただいてもよろしいでしょうか。"])
        #expect(names.name(for: 1) == "山田")
    }
    @Test(arguments: ["司会", "話者C", "話者B"])
    func 会話に出てこない名前と既定名は付けない(_ name: String) throws {
        let lines = ["[02:37:56] 話者A: 山田さんからお願いします。", "[02:38:02] 話者B: はい。"]
        let r = try request(fixed: .init(unresolved: ["A", "B"], candidates: []))
        let event = try AISpeakerEvent(request: r, slot: "A", name: name, evidence: "[02:37:56] 議題を振っている", recordedAt: Date())
        var names = SpeakerNames()
        #expect(throws: (any Error).self) {
            try names.identify(event, participant: "迅雷", fixed: nil, detected: [0, 1], mapping: [:], lines: lines,
                               texts: ["山田さんからお願いします。", "はい。"])
        }
    }
    /// 話者名に「:」が入ると、整形した行からは本文の始まりを決められない。本文そのもので確かめる。
    @Test func 話者名の欄にだけ出る名前は本文に出てきた人名として数えない() throws {
        var names = SpeakerNames([2: "所属: 山田"])
        let lines = ["[14:05:10] 所属: 山田: はい。", "[14:05:12] 話者A: お願いします。"]
        let r = try request(fixed: .init(unresolved: ["A"], candidates: []))
        let event = try AISpeakerEvent(request: r, slot: "A", name: "山田", evidence: "[14:05:12] お願いします。", recordedAt: Date())
        #expect(throws: (any Error).self) {
            try names.identify(event, participant: "迅雷", fixed: nil, detected: [0, 2], mapping: [:], lines: lines,
                               texts: ["はい。", "お願いします。"])
        }
        #expect(SpeakerEvidence.mentions("山田", in: ["山田さんからお願いします。"]))
        #expect(!SpeakerEvidence.mentions("山田", in: ["はい。", "お願いします。"]))
    }
    @Test func 確度の低い推定はイベントに残し根拠とAI節に確度を添える() throws {
        let r = try request()
        let low = try AISpeakerEvent(request: r, slot: "A", name: "タダシ", evidence: "[14:05:10] タダシです",
                                     recordedAt: Date(timeIntervalSince1970: 100), confidence: .low)
        let json = try #require(JSONSerialization.jsonObject(with: AIJSON.encode(low)) as? [String: Any])
        #expect(json["confidence"] as? String == "low")
        #expect(try AIInbox.decodeSpeaker(AIJSON.encode(low), filename: low.filename, for: r) == low)
        // 旧イベントは確度を持たない。確かな推定として読む。
        let plain = try AISpeakerEvent(request: r, slot: "A", name: "タダシ", evidence: "[14:05:10] タダシです",
                                       recordedAt: Date(timeIntervalSince1970: 100))
        #expect(!String(decoding: try AIJSON.encode(plain), as: UTF8.self).contains("confidence"))
        #expect(!plain.isLowConfidence && !plain.sameContent(as: low))
        var bad = json; bad["confidence"] = "medium"
        #expect(throws: (any Error).self) {
            try AIInbox.decodeSpeaker(JSONSerialization.data(withJSONObject: bad), filename: low.filename, for: r)
        }
        let attribution = SpeakerAttribution(event: low, participant: "迅雷")
        #expect(attribution.tooltip == "迅雷の推定(確度: 低) · 14:05:10「タダシです」")
        #expect(attribution.detail == "迅雷(確度: 低) 14:05:10「タダシです」")
        var names = SpeakerNames()
        try names.identify(low, participant: "迅雷", fixed: participants(["タダシ"]), detected: [0], mapping: [:],
                           lines: ["[14:05:10] 話者A: タダシです"], texts: ["タダシです"])
        var conversation = AIConversation(meetingID: r.envelope.meetingID)
        try conversation.append(r); try conversation.recordSpeaker(low, names: names)
        let meeting = MeetingMarkdown.Meeting(startedAt: Date(), duration: 1,
            utterances: [.init(speaker: 0, start: 0, end: 1, text: "タダシです")], names: names, ai: conversation)
        let markdown = MeetingMarkdown.render(meeting)
        #expect(markdown.contains("- 話者: A=タダシ\n"))
        #expect(markdown.contains("- 話者の割当: A → タダシ(確度: 低、根拠: [14:05:10] タダシです)"))
    }
    @Test(arguments: ["", "改\t行", String(repeating: "長", count: 65)])
    func 名前として扱えない形は受けない(_ name: String) throws {
        let r = try request()
        #expect(throws: (any Error).self) {
            try AISpeakerEvent(request: r, slot: "A", name: name, evidence: "[14:05:10] タダシです", recordedAt: Date())
        }
    }
    @Test func キーの既定とmanifest互換と型を検証する() throws {
        let old = ResolvedAIConfig(config: AIConfig(), home: URL(fileURLWithPath: "/tmp"))
        let enabled = ResolvedAIConfig(config: AIConfig(identifySpeakers: true), home: URL(fileURLWithPath: "/tmp"))
        #expect(!old.identifySpeakers && enabled.identifySpeakers)
        #expect(try ConfigLoader.parse(toml: "[[ai]]\nidentifySpeakers = true").ai?.first?.identifySpeakers == true)
        for raw in ["1", "\"true\"", "[]"] {
            #expect(throws: (any Error).self) { try ConfigLoader.parse(toml: "[[ai]]\nidentifySpeakers = \(raw)") }
        }
        var json = try #require(JSONSerialization.jsonObject(with: AIJSON.encode(enabled)) as? [String: Any])
        json["identifySpeakers"] = nil
        #expect(try !AIJSON.decode(ResolvedAIConfig.self, from: JSONSerialization.data(withJSONObject: json)).identifySpeakers)
        json["identifySpeakers"] = "true"
        #expect(throws: (any Error).self) { try AIJSON.decode(ResolvedAIConfig.self, from: JSONSerialization.data(withJSONObject: json)) }
    }
}
