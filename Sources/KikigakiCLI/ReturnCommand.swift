import Foundation
import KikigakiCore
import KikigakiAIIO

struct ReturnCommand: Sendable {
    let action: String
    let options: [String: String]
    let payload: String?
    init(_ arguments: [String]) throws {
        guard let action = arguments.first, ["accept", "reply", "notify"].contains(action) else { throw AIError.invalid("command") }
        self.action = action
        var options: [String: String] = [:], payload: String?, index = 1
        while index < arguments.count {
            let name = arguments[index]
            if name.hasPrefix("--") {
                guard ["--session", "--request", "--token", "--kind", "--reason", "--provider"].contains(name),
                      options[name] == nil, index + 1 < arguments.count else { throw AIError.invalid("arguments") }
                options[name] = arguments[index + 1]; index += 2
            } else {
                guard action == "notify", payload == nil, index == arguments.count - 1 else { throw AIError.invalid("arguments") }
                payload = name; index += 1
            }
        }
        let required: Set<String> = action == "notify" ? ["--session", "--token", "--provider"] : ["--session", "--token", "--request"]
        let allowed = action == "reply" ? required.union(["--kind", "--reason"]) : required
        guard required.isSubset(of: Set(options.keys)), Set(options.keys).isSubset(of: allowed),
              options.values.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }),
              action != "reply" || options["--kind"] != nil,
              payload == nil || options["--provider"] == "codex" else { throw AIError.invalid("arguments") }
        self.options = options; self.payload = payload
    }

    func execute(input: () throws -> Data, environment: [String: String] = ProcessInfo.processInfo.environment, now: Date = Date()) throws -> String {
        let path = options["--session"]!
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("//"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw AIError.unsafeFile }
        let url = URL(fileURLWithPath: path), pieces = url.pathComponents
        guard pieces.count >= 6, pieces[pieces.count - 5] == ".kikigaki-context",
              let meeting = UUID(uuidString: pieces[pieces.count - 4]), pieces[pieces.count - 4] == meeting.uuidString,
              pieces[pieces.count - 3] == "ai", pieces[pieces.count - 2] == "sessions",
              url.pathExtension == "json", let generation = Int(url.deletingPathExtension().lastPathComponent), generation > 0,
              url.lastPathComponent == "\(generation).json" else { throw AIError.unsafeFile }
        let root = (0..<5).reduce(url) { value, _ in value.deletingLastPathComponent() }
        let files = AIFileStore(root: root), base = [".kikigaki-context", meeting.uuidString, "ai"]
        let session = try AIJSON.decode(AISessionRecord.self, from: files.read(base + ["sessions", "\(generation).json"], limit: AILimits.eventBytes))
        guard session.schemaVersion == 1, session.meetingID == meeting, session.generation == generation,
              !session.token.isEmpty, session.connection?.provider == session.provider else { throw AIError.mismatch }
        if action == "notify" {
            guard options["--token"] == session.token, options["--provider"] == session.provider.rawValue else { throw AIError.mismatch }
            guard (session.provider == .codex) == (payload != nil) else { throw AIError.invalid("hook input") }
            let bytes = try payload.map { Data($0.utf8) } ?? input()
            let event = try AIHookObservation(payload: bytes, session: session, now: now)
            let target = base + ["inbox", event.filename]
            do { try files.write(AIJSON.encode(event), to: target, replacing: false) }
            catch AIError.conflict {
                let previous = try AIJSON.decode(AIHookObservation.self, from: files.read(target, limit: AILimits.eventBytes))
                try previous.validate(session: session)
                guard previous.sameContent(as: event) else { throw AIError.conflict }
                try files.syncDirectory(Array(target.dropLast()))
            }
            return event.eventID
        }
        guard let id = UUID(uuidString: options["--request"]!) else { throw AIError.invalid("request") }
        let request = try AIJSON.decode(AIRequest.self, from: files.read(base + ["requests", id.uuidString + ".json"], limit: AILimits.eventBytes))
        try request.validate(); try request.envelope.validatePaths(outputDirectory: root)
        guard request.id == id, request.envelope.meetingID == meeting,
              request.envelope.participant.sessionGeneration == generation,
              request.envelope.participant.sessionPath == path,
              options["--token"] == request.envelope.participant.requestToken else { throw AIError.mismatch }
        let kind: AIReceiveEvent.Kind
        if action == "accept" { kind = .accept }
        else {
            guard let parsed = AIReceiveEvent.Kind(rawValue: options["--kind"]!), parsed != .accept else { throw AIError.invalid("kind") }
            kind = parsed
        }
        var body: String?
        if action == "reply" {
            let bytes = try input()
            guard bytes.count <= AILimits.bodyBytes else { throw AIError.tooLarge }
            guard let text = String(data: bytes, encoding: .utf8) else { throw AIError.invalid("UTF-8") }
            body = text
        }
        let event = try AIReceiveEvent(request: request, kind: kind, recordedAt: now, body: body, reason: options["--reason"])
        let encoded = try AIJSON.encode(event)
        guard encoded.count <= AILimits.eventBytes else { throw AIError.tooLarge }
        // 実行環境のthreadだけを保存する。質問トークンでsession本体は変更できない。
        if session.provider == .codex, let thread = environment["CODEX_THREAD_ID"], !thread.isEmpty {
            guard thread.utf8.count <= 512, !thread.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  session.connection?.sessionID == nil || session.connection?.sessionID == thread else { throw AIError.mismatch }
            let target = base + ["sessions", "\(generation).identity.json"]
            let data = try AIJSON.encode(thread)
            do { try files.write(data, to: target, replacing: false) }
            catch AIError.conflict {
                guard try AIJSON.decode(String.self, from: files.read(target, limit: 2048)) == thread else { throw AIError.mismatch }
                try files.syncDirectory(Array(target.dropLast()))
            }
        }
        let target = base + ["inbox", event.filename]
        do { try files.write(encoded, to: target, replacing: false) }
        catch AIError.conflict {
            let previous = try AIInbox.decode(files.read(target, limit: AILimits.eventBytes), filename: event.filename, for: request)
            guard previous.sameContent(as: event) else { throw AIError.conflict }
            try files.syncDirectory(Array(target.dropLast()))
        }
        return event.eventID
    }
}
