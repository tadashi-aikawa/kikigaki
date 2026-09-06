import Foundation
import KikigakiCore

struct AIHerdrConnection: Codable, Equatable, Sendable {
    let workspaceID: String
    let paneID: String
    let provider: AIProvider
    var sessionID: String?
}

struct AIHerdrObservation: Equatable, Sendable {
    let status: AIConnectionStatus
    let ready: Bool
    let sessionID: String?
}

enum AIHerdrError: Error { case notReady, replaced, server(String) }

/// セッションの所有者は会議controller。生成途中の接続IDも永続化してから起動する。
/// startとpromptの自動再試行はしない。信頼承認後はobserveで同じpaneを再確認する。
struct AIHerdr: Sendable {
    typealias Run = @Sendable ([String], TimeInterval) async throws -> AIProcessOutput
    private let run: Run

    init(executable: URL) {
        run = { arguments, timeout in try await AIProcessRunner().run(executable, arguments, timeout: timeout) }
    }
    init(run: @escaping Run) { self.run = run }

    private func call(_ arguments: [String], timeout: TimeInterval = 15) async throws -> [String: Any] {
        let output = try await run(arguments, timeout)
        guard output.status == 0 else {
            // stderr本文にはargvが含まれ得るため、既知のerror code以外は外へ出さない。
            let json = try? JSONSerialization.jsonObject(with: output.stderr) as? [String: Any]
            let error = json?["error"] as? [String: Any]
            throw AIHerdrError.server(error?["code"] as? String ?? "herdr_failed")
        }
        guard let json = try JSONSerialization.jsonObject(with: output.stdout) as? [String: Any],
              let result = json["result"] as? [String: Any] else { throw AIProcessError.invalidResponse }
        return result
    }

    func create(cwd: URL, label: String, provider: AIProvider) async throws -> AIHerdrConnection {
        let result = try await call(["workspace", "create", "--cwd", cwd.path, "--no-focus", "--label", label])
        guard let workspace = result["workspace"] as? [String: Any],
              let pane = result["root_pane"] as? [String: Any],
              let workspaceID = workspace["workspace_id"] as? String,
              let paneID = pane["pane_id"] as? String, !workspaceID.isEmpty, !paneID.isEmpty else {
            throw AIProcessError.invalidResponse
        }
        return AIHerdrConnection(workspaceID: workspaceID, paneID: paneID, provider: provider)
    }

    func label(_ connection: AIHerdrConnection, participant: String) async throws {
        _ = try await call(["pane", "report-metadata", connection.paneID, "--source", "owlery", "--display-agent", participant])
    }

    func start(_ connection: AIHerdrConnection, executable: URL, arguments: [String]) async throws {
        _ = try await call(["pane", "run", connection.paneID, AIShell.command([executable.path] + arguments)], timeout: 40)
    }

    func observe(_ connection: AIHerdrConnection) async throws -> AIHerdrObservation {
        let result = try await call(["agent", "get", connection.paneID])
        guard let agent = result["agent"] as? [String: Any],
              agent["pane_id"] as? String == connection.paneID,
              agent["workspace_id"] as? String == connection.workspaceID else { throw AIHerdrError.replaced }
        let provider = agent["agent"] as? String
        let session = (agent["agent_session"] as? [String: Any])?["value"] as? String
        if let provider, provider != connection.provider.rawValue { throw AIHerdrError.replaced }
        if let expected = connection.sessionID, let session, expected != session { throw AIHerdrError.replaced }
        let raw = agent["agent_status"] as? String ?? "unknown"
        let status: AIConnectionStatus
        switch raw {
        case "idle", "done": status = .idle
        case "working": status = .working
        case "blocked": status = .blocked
        default: status = .unknown
        }
        let ready = provider == connection.provider.rawValue && agent["interactive_ready"] as? Bool == true
            && status == .idle && (connection.provider == .codex || session != nil)
            && (connection.sessionID == nil || connection.sessionID == session)
        return AIHerdrObservation(status: status, ready: ready, sessionID: session)
    }

    func prompt(_ connection: AIHerdrConnection, text: String) async throws {
        // 送信試行を永続化した呼び手だけが使う。再確認とpromptの間の競合も送達不明に残す。
        let observation = try await observe(connection)
        guard observation.ready else { throw AIHerdrError.notReady }
        _ = try await call(["agent", "prompt", connection.paneID, text])
    }

    func show(_ connection: AIHerdrConnection) async throws {
        _ = try await call(["workspace", "focus", connection.workspaceID])
    }
}
