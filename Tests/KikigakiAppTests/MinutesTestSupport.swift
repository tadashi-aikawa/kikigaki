import Foundation
import WebKit
import KikigakiCore
@testable import Kikigaki

final class MinutesTestDefaults {
    private let suite = "kikigaki-minutes-test-" + UUID().uuidString
    lazy var value = UserDefaults(suiteName: suite)!
    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
}

// swift testのWKWebViewでは実rAFが進まない。描画器はそのまま、フレームの配送だけ明示的に行う。
@MainActor func installBoardFrameClock(_ web: WKWebView) async throws {
    _ = try await web.evaluateJavaScript("""
    if (!window.diagramFrames) {
      window.diagramFrames=new Map(); window.diagramFrameID=0;
      window.requestAnimationFrame=callback=>{const id=++diagramFrameID;diagramFrames.set(id,callback);return id;};
      window.cancelAnimationFrame=id=>diagramFrames.delete(id);
      window.flushDiagramFrames=()=>{const callbacks=[...diagramFrames.values()];diagramFrames.clear();for(const callback of callbacks)callback(performance.now());};
    }
    void 0;
    """)
}

@MainActor func testAIController(meetingID: UUID, outputDirectory: URL, herdr: AIHerdr,
                                 recovered: AIConversation? = nil) throws -> AIConversationController {
    let stores = MinutesStores()
    return try AIConversationController(meetingID: meetingID, outputDirectory: outputDirectory, herdr: herdr,
        recovered: recovered, minutes: stores.store(meetingID: meetingID, markdownURL: outputDirectory.appendingPathComponent("meeting.md")))
}
