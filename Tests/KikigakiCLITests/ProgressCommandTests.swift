import Darwin
import Foundation
import Testing
import KikigakiCore
import KikigakiAIIO
@testable import KikigakiCLI

@Suite struct ProgressCommandTests {
    private func name(_ f: ReturnCommandTests.Fixture, _ phase: AIProgressEvent.Phase = .editing) -> String {
        AIProgressEvent.filename(requestID: f.request.id, phase: phase)
    }

    @Test(arguments: [nil, 2] as [Int?])
    func 編集の申告を受信箱へ置きacceptやresultと共存する(_ slot: Int?) throws {
        let f = try ReturnCommandTests.Fixture(slot: slot)
        let command = try ReturnCommand(f.args("progress", ["--editing", "--total", "7"]))
        let id = try command.execute(input: { Issue.record("progressはstdinを読まない"); return Data() },
                                     environment: [:], now: Date(timeIntervalSince1970: 20))
        #expect(id == f.request.id.uuidString + "/progress/editing")
        let event = try AIInbox(outputDirectory: f.root).readProgress(.editing, for: f.request)
        #expect(event.total == 7 && event.phase == .editing && event.schemaVersion == 1)
        #expect(event.recordedAt == Date(timeIntervalSince1970: 20) && event.filename == name(f))
        _ = try ReturnCommand(f.args("accept")).execute(input: { Data() }, environment: [:])
        _ = try ReturnCommand(f.args("reply", ["--kind", "answered"])).execute(input: { Data("回答".utf8) }, environment: [:])
        #expect(try AIInbox(outputDirectory: f.root).read(filename: f.request.id.uuidString + ".result.json", for: f.request).body == "回答")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.files.directory(f.base + ["inbox"]).path).count == 3)
    }

    /// 段ごとに別ファイル。返答の申告が編集の申告を消さず、総数も残る。
    @Test func 返答の申告は編集とは別のファイルへ置く() throws {
        let f = try ReturnCommandTests.Fixture()
        _ = try ReturnCommand(f.args("progress", ["--editing", "--total", "2"]))
            .execute(input: { Data() }, environment: [:], now: Date(timeIntervalSince1970: 30))
        let id = try ReturnCommand(f.args("progress", ["--replying"]))
            .execute(input: { Data() }, environment: [:], now: Date(timeIntervalSince1970: 40))
        #expect(id == f.request.id.uuidString + "/progress/replying")
        let inbox = AIInbox(outputDirectory: f.root)
        let editing = try inbox.readProgress(.editing, for: f.request)
        let replying = try inbox.readProgress(.replying, for: f.request)
        #expect(editing.total == 2 && editing.recordedAt == Date(timeIntervalSince1970: 30))
        #expect(replying.total == nil && replying.phase == .replying)
        #expect(replying.recordedAt == Date(timeIntervalSince1970: 40))
        #expect(replying.filename == f.request.id.uuidString + ".progress.replying.json")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.files.directory(f.base + ["inbox"]).path).count == 2)
    }

    /// 編集を経ずに返答だけ申告してもよい。読むだけの依頼でも呼ぶ契約のため。
    @Test func 返答だけの申告も受け取る() throws {
        let f = try ReturnCommandTests.Fixture()
        _ = try ReturnCommand(f.args("progress", ["--replying"])).execute(input: { Data() }, environment: [:])
        #expect(try AIInbox(outputDirectory: f.root).readProgress(.replying, for: f.request).phase == .replying)
        #expect(throws: (any Error).self) { try AIInbox(outputDirectory: f.root).readProgress(.editing, for: f.request) }
    }

    /// 2回目以降は無視して成功で返す。失敗にすると、申告のためにAIの手が止まる。
    @Test(arguments: [["--editing"], ["--replying"]])
    func 段ごとに有効なのは最初の1回だけで再申告は上書きも失敗もしない(_ stage: [String]) throws {
        let f = try ReturnCommandTests.Fixture()
        let phase: AIProgressEvent.Phase = stage == ["--editing"] ? .editing : .replying
        let first = try ReturnCommand(f.args("progress", stage))
            .execute(input: { Data() }, environment: [:], now: Date(timeIntervalSince1970: 30))
        for extra in [stage, phase == .editing ? stage + ["--total", "3"] : stage] {
            let again = try ReturnCommand(f.args("progress", extra))
                .execute(input: { Data() }, environment: [:], now: Date(timeIntervalSince1970: 99))
            #expect(again == first)
        }
        let event = try AIInbox(outputDirectory: f.root).readProgress(phase, for: f.request)
        #expect(event.total == nil && event.recordedAt == Date(timeIntervalSince1970: 30))
    }

    @Test func 総数は1から999の整数だけを受け取る() throws {
        let f = try ReturnCommandTests.Fixture()
        for total in ["0", "1000", "-1", "3.5", "七", "+3", " 3", "١٢"] {
            #expect(throws: (any Error).self) {
                try ReturnCommand(f.args("progress", ["--editing", "--total", total])).execute(input: { Data() }, environment: [:])
            }
        }
        #expect(throws: (any Error).self) { try f.files.read(f.base + ["inbox", name(f)]) }
        for total in ["1", "999"] {
            let f = try ReturnCommandTests.Fixture()
            _ = try ReturnCommand(f.args("progress", ["--editing", "--total", total])).execute(input: { Data() }, environment: [:])
            #expect(try AIInbox(outputDirectory: f.root).readProgress(.editing, for: f.request).total == Int(total))
        }
    }

    @Test func 引数の欠けと余りとtokenの違いを拒否する() throws {
        let f = try ReturnCommandTests.Fixture()
        for extra in [[], ["--total", "2"], ["--editing", "--editing"], ["--editing", "--kind", "answered"],
                      ["--editing", "--path", "/tmp/a.md"], ["--editing", "--total"],
                      // 段はどちらか1つ。総数は編集にしか添えられない。
                      ["--editing", "--replying"], ["--replying", "--replying"], ["--replying", "--total", "2"]] {
            #expect(throws: (any Error).self) { try ReturnCommand(f.args("progress", extra)) }
        }
        // --editing と --replying は progress 専用の値なしフラグ。他のコマンドへ持ち込めない。
        #expect(throws: (any Error).self) { try ReturnCommand(f.args("accept", ["--editing"])) }
        #expect(throws: (any Error).self) { try ReturnCommand(f.args("reply", ["--kind", "answered", "--replying"])) }
        var args = f.args("progress", ["--replying"]); args[6] = "hook-secret"
        #expect(throws: AIError.mismatch) { try ReturnCommand(args).execute(input: { Data() }, environment: [:]) }
        let command = try ReturnCommand(f.args("progress", ["--editing"]))
        #expect(throws: AIError.mismatch) { try command.execute(input: { Data() }, environment: ["CODEX_THREAD_ID": "other"]) }
        _ = try command.execute(input: { Data() }, environment: ["CODEX_THREAD_ID": "main-thread"])
        #expect(try AIJSON.decode(String.self, from: f.files.read(f.base + ["sessions", "1.identity.json"])) == "main-thread")
    }

    @Test(arguments: ["symlink", "hardlink", "fifo", "permissions"])
    func 不正な既存イベントを読みも置換もしない(_ kind: String) throws {
        let f = try ReturnCommandTests.Fixture()
        let inbox = try f.files.directory(f.base + ["inbox"]), target = inbox.appendingPathComponent(name(f))
        let command = try ReturnCommand(f.args("progress", ["--editing"]))
        let bytes = try AIJSON.encode(AIProgressEvent(request: f.request, phase: .editing, recordedAt: Date(), total: 2))
        let other = f.root.appendingPathComponent("other")
        try f.files.write(bytes, to: ["other"])
        switch kind {
        case "symlink": try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other)
        case "hardlink": #expect(link(other.path, target.path) == 0)
        case "fifo": #expect(mkfifo(target.path, 0o600) == 0)
        default:
            try f.files.write(bytes, to: f.base + ["inbox", name(f)]); #expect(chmod(target.path, 0o644) == 0)
        }
        #expect(throws: (any Error).self) { try command.execute(input: { Data() }, environment: [:]) }
        #expect(throws: (any Error).self) { try AIInbox(outputDirectory: f.root).readProgress(.editing, for: f.request) }
        #expect(try Data(contentsOf: other) == bytes)
    }

    @Test func 別requestや偽の種別のイベントは読めない() throws {
        let f = try ReturnCommandTests.Fixture(), other = try ReturnCommandTests.Fixture()
        _ = try ReturnCommand(f.args("progress", ["--editing"])).execute(input: { Data() }, environment: [:])
        let bytes = try f.files.read(f.base + ["inbox", name(f)])
        #expect(throws: (any Error).self) { try AIInbox.decodeProgress(bytes, filename: name(f), for: other.request) }
        #expect(throws: (any Error).self) { try AIInbox.decodeProgress(bytes, filename: "other.progress.editing.json", for: f.request) }
        // 名前の段とJSONの段が食い違うものは読まない。編集の申告を返答の枠へ置けない。
        #expect(throws: (any Error).self) { try AIInbox.decodeProgress(bytes, filename: name(f, .replying), for: f.request) }
        // 段の申告先を増やさない。編集・返答以外のphaseは読まない。
        var json = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for forgedPhase in ["reply", "reading", ""] {
            json["phase"] = forgedPhase
            json["event_id"] = f.request.id.uuidString + "/progress/" + forgedPhase
            let forged = try JSONSerialization.data(withJSONObject: json)
            #expect(throws: (any Error).self) { try AIInbox.decodeProgress(forged, filename: name(f), for: f.request) }
        }
        // 返答の申告には総数を添えられない。
        json["phase"] = "replying"; json["event_id"] = f.request.id.uuidString + "/progress/replying"; json["total"] = 2
        #expect(throws: (any Error).self) {
            try AIInbox.decodeProgress(try JSONSerialization.data(withJSONObject: json), filename: name(f, .replying), for: f.request)
        }
        json["phase"] = "editing"; json["event_id"] = f.request.id.uuidString + "/progress/editing"; json["total"] = 1000
        #expect(throws: (any Error).self) {
            try AIInbox.decodeProgress(try JSONSerialization.data(withJSONObject: json), filename: name(f), for: f.request)
        }
    }
}
