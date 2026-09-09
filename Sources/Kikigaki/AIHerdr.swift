import Foundation
import KikigakiCore
import KikigakiAIIO
struct AIHerdrObservation: Equatable, Sendable {
    let status: AIConnectionStatus
    let ready: Bool
    let sessionID: String?
    var terminalID: String?
}
enum AIHerdrError: Error, Equatable { case notReady, replaced, missing, server(String) }

/// 同じ操作の同じ失敗を連続して記録しない。成功したら次の失敗はまた記録する。
actor AIHerdrLogGate {
    private var lastCode: [String: String] = [:]
    func shouldLog(operation: String, code: String) -> Bool {
        guard lastCode[operation] != code else { return false }
        lastCode[operation] = code
        return true
    }
    func recovered(operation: String) { lastCode[operation] = nil }
}

/// herdrのJSONを型として解釈する。エラー本文やargvを診断へ転載しない。
struct AIHerdr: Sendable {
    typealias Run = @Sendable ([String], TimeInterval) async throws -> AIProcessOutput
    typealias Log = @Sendable (String) -> Void
    private let run: Run
    private let log: Log
    private let gate = AIHerdrLogGate()
    init(executable: URL) {
        self.init(run: { try await AIProcessRunner().run(executable, $0, timeout: $1) })
    }
    init(run: @escaping Run, log: @escaping Log = { FileHandle.standardError.write(Data(("Kikigaki: " + $0 + "\n").utf8)) }) {
        self.run = run; self.log = log
    }
    private struct Reply<T: Decodable>: Decodable { let result: T }
    private struct Empty: Decodable {}
    private struct Workspace: Decodable { let workspace_id: String }
    private struct Pane: Decodable { let pane_id: String }
    private struct Created: Decodable { let workspace: Workspace; let root_pane: Pane }
    private struct Session: Decodable { let value: String }
    private struct Agent: Decodable {
        let pane_id: String; let workspace_id: String
        let agent: String?; let agent_status: String?; let interactive_ready: Bool?
        let agent_session: Session?; let terminal_id: String?
        let display_agent: String?; let cwd: String?
        let terminal_title: String?; let terminal_title_stripped: String?
    }
    private struct AgentReply: Decodable { let agent: Agent }
    private struct AgentList: Decodable { let agents: [Agent] }
    /// `pane list` はagentが検知される前のペインも返す。起動直後の準備済みを
    /// 「消えた」と誤判定しないよう、生存と表題はこちらから取る。
    private struct PaneList: Decodable { let panes: [Agent] }
    private struct Failure: Decodable {
        struct Detail: Decodable { let code: String }
        let error: Detail
    }
    private func call<T: Decodable>(_ args: [String], as type: T.Type, timeout: TimeInterval = 15) async throws -> T {
        guard !args.contains(where: { $0.contains("\0") }) else { throw AIProcessError.invalidInput }
        let operation = args.prefix(2).joined(separator: " ")
        let reply: AIProcessOutput
        do { reply = try await run(args, timeout) }
        catch {
            let code = error as? AIProcessError == .timeout ? "timeout" : error is CancellationError ? "cancelled" : "transport_failed"
            log("herdr \(operation): \(code)")
            throw error
        }
        if reply.status != 0 {
            let rawCode = (try? JSONDecoder().decode(Failure.self, from: reply.stderr))?.error.code
                ?? (try? JSONDecoder().decode(Failure.self, from: reply.stdout))?.error.code ?? "herdr_failed"
            let code = rawCode.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) == rawCode.startIndex..<rawCode.endIndex ? rawCode : "herdr_failed"
            // 切断後の定期監視は同じ失敗を繰り返すため、同じ操作で同じcodeが続く間は1回だけ記録する(段6の実測: agent_not_found が2秒ごとに出続けた)。
            if await gate.shouldLog(operation: operation, code: code) { log("herdr \(operation): \(code)") }
            if ["agent_not_found", "pane_not_found", "workspace_not_found"].contains(code) { throw AIHerdrError.missing }
            throw AIHerdrError.server(code)
        }
        await gate.recovered(operation: operation)
        // report-metadata のように成功時に何も出力しないコマンドは、空の標準出力を成功として扱う(段6の実測: herdr 0.8.2)。
        if let empty = Empty() as? T, reply.stdout.allSatisfy({ $0 == 0x0A || $0 == 0x0D || $0 == 0x20 || $0 == 0x09 }) {
            return empty
        }
        guard let result = try? JSONDecoder().decode(Reply<T>.self, from: reply.stdout) else {
            log("herdr \(operation): invalid_response"); throw AIProcessError.invalidResponse
        }
        return result.result
    }
    func create(cwd: URL, label: String, provider: AIProvider) async throws -> AIHerdrConnection {
        let result = try await call(["workspace", "create", "--cwd", cwd.path, "--no-focus", "--label", label], as: Created.self)
        guard Self.identifier(result.workspace.workspace_id), Self.identifier(result.root_pane.pane_id) else { throw AIProcessError.invalidResponse }
        return AIHerdrConnection(workspaceID: result.workspace.workspace_id, paneID: result.root_pane.pane_id, provider: provider)
    }
    /// 稼働中のpane IDを列挙する。準備済みセッションの生存確認にだけ使い、
    /// 宛先の候補には使わない(利用者が手で起こしたペインへ繋ぐ案は取り下げた)。
    func alivePaneIDs() async throws -> Set<String> { Set(try await panes().map(\.paneID)) }

    /// 稼働中のペインと表題。表題はCLIがOSCで設定する値なので、表示のたびに引き直す。
    /// `terminal_title` には状態記号が付くため、素の `terminal_title_stripped` を先に使う。
    func panes() async throws -> [(paneID: String, title: String?)] {
        try await call(["pane", "list"], as: PaneList.self).panes
            .filter { Self.identifier($0.pane_id) }
            .map { ($0.pane_id, $0.terminal_title_stripped ?? $0.terminal_title) }
    }
    func label(_ target: AIHerdrConnection, participant: String) async throws {
        _ = try await call(["pane", "report-metadata", target.paneID, "--source", "owlery", "--display-agent", participant], as: Empty.self)
    }
    func rename(_ target: AIHerdrConnection, name: String) async throws {
        _ = try await call(["pane", "rename", target.paneID, "--", name], as: Empty.self)
    }
    static func agentName(generation: Int, id: UUID = UUID()) throws -> String {
        guard generation > 0 else { throw AIProcessError.invalidInput }
        // 最大のInt世代でも32文字に収めるため、世代は36進で表す。
        return "kikigaki-" + id.uuidString.prefix(8).lowercased() + "-g" + String(generation, radix: 36)
    }
    func start(_ target: AIHerdrConnection, executable: URL, arguments: [String], customCommand: Bool = true, generation: Int = 1) async throws {
        guard executable.isFileURL, executable.path.hasPrefix("/"), !arguments.contains(where: { $0.contains("\0") }) else { throw AIProcessError.invalidInput }
        let args = customCommand
            ? ["pane", "run", target.paneID, AIShell.command([executable.path] + arguments)]
            : ["agent", "start", try Self.agentName(generation: generation), "--kind", target.provider.rawValue,
               "--pane", target.paneID, "--timeout", "15000", "--"] + arguments
        _ = try await call(args, as: Empty.self, timeout: 20)
    }
    func observe(_ target: AIHerdrConnection) async throws -> AIHerdrObservation {
        let agent = try await call(["agent", "get", target.paneID], as: AgentReply.self).agent
        guard agent.pane_id == target.paneID, agent.workspace_id == target.workspaceID else { throw AIHerdrError.replaced }
        if let kind = agent.agent, kind != target.provider.rawValue { throw AIHerdrError.replaced }
        if let expected = target.terminalID, let actual = agent.terminal_id, expected != actual { throw AIHerdrError.replaced }
        let session = agent.agent_session?.value
        if let expected = target.sessionID, let actual = session, expected != actual { throw AIHerdrError.replaced }
        let identityKnown = agent.agent == target.provider.rawValue
            && (target.sessionID == nil || target.sessionID == session)
            && (target.terminalID == nil || target.terminalID == agent.terminal_id)
        let status: AIConnectionStatus
        switch identityKnown ? agent.agent_status : nil {
        case "idle", "done": status = .idle
        case "working": status = .working
        case "blocked": status = .blocked
        default: status = .unknown
        }
        // `interactive_ready` は `agent start` で起こしたagentにしか付かない(実測: herdr 0.8.2 の `agent get` は
        // `pane run` で起こしたCodexにこの項目を返さない)。無い場合は idle をもって入力可能とみなす。
        let ready = status == .idle && agent.interactive_ready != false && (target.provider == .codex || !(session ?? "").isEmpty)
        return AIHerdrObservation(status: status, ready: ready, sessionID: session, terminalID: agent.terminal_id)
    }
    func prompt(_ target: AIHerdrConnection, text: String, beforeSend: @Sendable () async throws -> Void = {}) async throws {
        guard try await observe(target).ready else { throw AIHerdrError.notReady }
        try Task.checkCancellation()
        try await beforeSend()
        try Task.checkCancellation()
        _ = try await call(["agent", "prompt", target.paneID, text], as: Empty.self)
    }
    func show(_ target: AIHerdrConnection) async throws { _ = try await call(["workspace", "focus", target.workspaceID], as: Empty.self) }
    private static func identifier(_ value: String) -> Bool { !value.isEmpty && !value.hasPrefix("-") && value.utf8.allSatisfy { (33...126).contains($0) } }
}
