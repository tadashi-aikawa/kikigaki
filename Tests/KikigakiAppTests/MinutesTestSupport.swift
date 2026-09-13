import Foundation
import KikigakiCore
@testable import Kikigaki

final class MinutesTestDefaults {
    private let suite = "kikigaki-minutes-test-" + UUID().uuidString
    lazy var value = UserDefaults(suiteName: suite)!
    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
}

@MainActor func testAIController(meetingID: UUID, outputDirectory: URL, herdr: AIHerdr,
                                 recovered: AIConversation? = nil) throws -> AIConversationController {
    let stores = MinutesStores()
    return try AIConversationController(meetingID: meetingID, outputDirectory: outputDirectory, herdr: herdr,
        recovered: recovered, minutes: stores.store(meetingID: meetingID, markdownURL: outputDirectory.appendingPathComponent("meeting.md")))
}
