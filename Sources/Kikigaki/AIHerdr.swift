import Foundation
import KikigakiCore

struct AIHerdrConnection: Codable, Equatable, Sendable {
    let workspaceID: String
    let paneID: String
    let provider: AIProvider
    var sessionID: String?
    var terminalID: String?
}
struct AIHerdrObservation: Equatable, Sendable {
    let status: AIConnectionStatus
    let ready: Bool
    let sessionID: String?
    var terminalID: String?
}
enum AIHerdrError: Error, Equatable { case notReady, replaced, missing, server(String) }

/// herdrのJSONを型として解釈する。エラー本文やargvを診断へ転載しない。
struct AIHerdr: Sendable {
    typealias Run = @Sendable ([String], TimeInterval) async throws -> AIProcessOutput
    private let run: Run
    init(executable: URL) { run = { try await AIProcessRunner().run(executable, $0, timeout: $1) } }
    init(run: @escaping Run) { self.run = run }
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
    }
    private struct AgentReply: Decodable { let agent: Agent }
    private struct Failure: Decodable {
        struct Detail: Decodable { let code: String }
        let error: Detail
    }
    private func call<T: Decodable>(_ args: [String], as type: T.Type, timeout: TimeInterval = 15) async throws -> T {
        guard !args.contains(where: { $0.contains("\0") }) else { throw AIProcessError.invalidInput }
        let reply = try await run(args, timeout)
        if reply.status != 0 {
            let code = (try? JSONDecoder().decode(Failure.self, from: reply.stderr))?.error.code ?? "herdr_failed"
            let safeCodes = ["agent_not_found", "pane_not_found", "workspace_not_found", "agent_blocked", "agent_not_ready", "agent_prompt_stalled"]
            if ["agent_not_found", "pane_not_found", "workspace_not_found"].contains(code) { throw AIHerdrError.missing }
            throw AIHerdrError.server(safeCodes.contains(code) ? code : "herdr_failed")
        }
        guard let result = try? JSONDecoder().decode(Reply<T>.self, from: reply.stdout) else { throw AIProcessError.invalidResponse }
        return result.result
    }
    func create(cwd: URL, label: String, provider: AIProvider) async throws -> AIHerdrConnection {
        let result = try await call(["workspace", "create", "--cwd", cwd.path, "--no-focus", "--label", label], as: Created.self)
        guard Self.identifier(result.workspace.workspace_id), Self.identifier(result.root_pane.pane_id) else { throw AIProcessError.invalidResponse }
        return AIHerdrConnection(workspaceID: result.workspace.workspace_id, paneID: result.root_pane.pane_id, provider: provider)
    }
    func label(_ target: AIHerdrConnection, participant: String) async throws {
        _ = try await call(["pane", "report-metadata", target.paneID, "--source", "owlery", "--display-agent", participant], as: Empty.self)
    }
    func start(_ target: AIHerdrConnection, executable: URL, arguments: [String], customCommand: Bool = true) async throws {
        guard executable.isFileURL, executable.path.hasPrefix("/"), !arguments.contains(where: { $0.contains("\0") }) else { throw AIProcessError.invalidInput }
        let args = customCommand
            ? ["pane", "run", target.paneID, AIShell.command([executable.path] + arguments)]
            : ["agent", "start", "kikigaki-" + UUID().uuidString.lowercased(), "--kind", target.provider.rawValue,
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
        let ready = status == .idle && agent.interactive_ready == true && (target.provider == .codex || !(session ?? "").isEmpty)
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
