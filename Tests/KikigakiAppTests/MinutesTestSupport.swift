import Foundation
import KikigakiCore
@testable import Kikigaki

@MainActor func testAIController(meetingID: UUID, outputDirectory: URL, herdr: AIHerdr,
                                 recovered: AIConversation? = nil) throws -> AIConversationController {
    let stores = MinutesStores()
    return try AIConversationController(meetingID: meetingID, outputDirectory: outputDirectory, herdr: herdr,
        recovered: recovered, minutes: stores.store(meetingID: meetingID, markdownURL: outputDirectory.appendingPathComponent("meeting.md")))
}
