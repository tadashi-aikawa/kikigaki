import Foundation
import Testing
@testable import Kikigaki

/// 試験用 `.app` は起動時の `recover()` で本体のAI会議を拾わないよう、別の固定の登録先を使う
@Suite struct TrialAppSupportTests {
    private let home = URL(fileURLWithPath: "/Users/example")
    private let output = URL(fileURLWithPath: "/tmp/out")

    @Test func 本体と試験appとreplay隔離で登録先が分かれる() {
        #expect(AppDelegate.aiSupportDirectory(isolatedReplay: false, bundleIdentifier: "com.tadashi-aikawa.kikigaki",
                                               outputDir: output, home: home).path
                == "/Users/example/Library/Application Support/KIKIGAKI")
        // 識別子の無い `swift run` も従来どおり
        #expect(AppDelegate.aiSupportDirectory(isolatedReplay: false, bundleIdentifier: nil, outputDir: output, home: home).path
                == "/Users/example/Library/Application Support/KIKIGAKI")
        #expect(AppDelegate.aiSupportDirectory(isolatedReplay: false, bundleIdentifier: AppDelegate.trialBundleIdentifier,
                                               outputDir: output, home: home).path
                == "/Users/example/Library/Application Support/KIKIGAKI-Trial")
        // replayの隔離条件は識別子より優先する
        for identifier in [nil, "com.tadashi-aikawa.kikigaki", AppDelegate.trialBundleIdentifier] {
            #expect(AppDelegate.aiSupportDirectory(isolatedReplay: true, bundleIdentifier: identifier,
                                                   outputDir: output, home: home).path == "/tmp/out/.typed-test-support")
        }
    }

    @Test func 試験appを組むスクリプトと識別子が一致する() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/make-app.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains("Set :CFBundleIdentifier \(AppDelegate.trialBundleIdentifier)"))
    }
}
