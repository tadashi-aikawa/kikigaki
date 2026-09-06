import Foundation
import Testing
@testable import Kikigaki
import KikigakiCore

@Suite struct AIConversationControllerTests {
    @Test @MainActor func 送信前の試行記録と遅延回答の回収を保存する() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = UUID(), store = AIFileStore(root: root)
        let base = [".kikigaki-context", meeting.uuidString, "ai"]
        let herdr = AIHerdr(run: { args, _ in
            let response: String
            switch Array(args.prefix(2)) {
            case ["workspace", "create"]:
                response = #"{"result":{"workspace":{"workspace_id":"w"},"root_pane":{"pane_id":"p"}}}"#
            case ["agent", "get"]:
                response = #"{"result":{"agent":{"workspace_id":"w","pane_id":"p","agent":"codex","agent_status":"idle","interactive_ready":true}}}"#
            case ["agent", "prompt"]:
                let state = try AIJSON.decode(AIConversation.self, from: store.read(base + ["state.json"]))
                #expect(state.questions.first?.state == .deliveryUnknown)
                throw AIProcessError.timeout
            default: response = #"{"result":{}}"#
            }
            return AIProcessOutput(status: 0, stdout: Data(response.utf8), stderr: Data())
        })
        let controller = try AIConversationController(meetingID: meeting, outputDirectory: root, herdr: herdr)
        let config = ResolvedAIConfig(config: AIConfig(), home: root)
        let request = try controller.prepare(lines: ["[12:00:00] A: 会話"], question: "質問", voiceQuestion: "",
            capturedAt: Date(), cutoff: 1, tail: nil, config: config, helper: root.appendingPathComponent("helper"))
        #expect(!controller.canSend)
        try await controller.connect(config: config, label: "検証", executable: URL(fileURLWithPath: "/tmp/fake"), arguments: [])
        await #expect(throws: AIProcessError.self) { try await controller.send(request, config: config) }
        #expect(controller.conversation.questions.first?.state == .deliveryUnknown)
        let event = try AIReceiveEvent(request: request, kind: .answered, recordedAt: Date(), body: "遅れて届いた回答")
        try store.write(AIJSON.encode(event), to: base + ["inbox", event.filename], replacing: false)
        controller.scan()
        controller.scan()
        #expect(controller.conversation.questions.count == 1)
        #expect(controller.conversation.questions.first?.result?.body == "遅れて届いた回答")
        #expect(controller.canSend)
        let state = try AIJSON.decode(AIConversation.self, from: store.read(base + ["state.json"]))
        let recovered = try AIConversationController(meetingID: meeting, outputDirectory: root, herdr: herdr, recovered: state)
        recovered.scan()
        #expect(recovered.connection == nil)
        #expect(!recovered.canSend)
        #expect(recovered.conversation == state)
        try recovered.markRead(request.id)
        #expect(recovered.conversation.questions.first?.isUnread == false)
    }
}
