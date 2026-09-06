import Foundation
import KikigakiCore

public struct AIHerdrConnection: Codable, Equatable, Sendable {
    public let workspaceID: String
    public let paneID: String
    public let provider: AIProvider
    public var sessionID: String?
    public var terminalID: String?
    public init(workspaceID: String, paneID: String, provider: AIProvider, sessionID: String? = nil, terminalID: String? = nil) {
        self.workspaceID = workspaceID; self.paneID = paneID; self.provider = provider
        self.sessionID = sessionID; self.terminalID = terminalID
    }
}

public struct AISessionRecord: Codable, Sendable {
    public let schemaVersion: Int
    public let meetingID: UUID
    public let generation: Int
    public let provider: AIProvider
    public let token: String
    public var connection: AIHerdrConnection?
    public init(schemaVersion: Int = 1, meetingID: UUID, generation: Int, provider: AIProvider, token: String, connection: AIHerdrConnection? = nil) {
        self.schemaVersion = schemaVersion; self.meetingID = meetingID; self.generation = generation
        self.provider = provider; self.token = token; self.connection = connection
    }
}
