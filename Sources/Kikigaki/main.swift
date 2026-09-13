import AppKit
import Foundation
import KikigakiCore

let replayDebug: ReplayDebugOptions
do { replayDebug = try ReplayDebugOptions.load() }
catch {
    FileHandle.standardError.write(Data("Kikigaki: invalid replay debug flags\n".utf8))
    exit(1)
}

// --smoke: UIを起動せず設定の読み込みだけ確認して終了する(CI・動作確認用)
if CommandLine.arguments.contains("--smoke") {
    do {
        let config = try AppDelegate.loadConfig()
        print("Kikigaki (smoke): outputDir=\(config.outputDir.path) saveRecording=\(config.saveRecording)")
        if CommandLine.arguments.contains("--replay") {
            print("Kikigaki (replay debug): questions=\(replayDebug.questions.count) hold=\(replayDebug.hold) rename=\(replayDebug.rename != nil) typed=\(replayDebug.typedEntries.count) verifyTyped=\(replayDebug.verifyTyped) automatic=\(replayDebug.automatic != nil)")
        }
    } catch {
        FileHandle.standardError.write(Data("Kikigaki: failed to load config: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

// Swift 5 言語モードではトップレベルコードが MainActor 扱いにならないため明示する
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    #if DEBUG
    if let index = CommandLine.arguments.firstIndex(of: "--utterance-gauge"), index + 1 < CommandLine.arguments.count {
        let delegate = UtteranceGaugeHarness(output: CommandLine.arguments[index + 1])
        app.delegate = delegate; app.run(); return
    }
    if CommandLine.arguments.contains("--show-window"),
       ProcessInfo.processInfo.environment["KIKIGAKI_DEBUG_AI_PROGRESS_VERIFY"] == "1" {
        let delegate = AIProgressWindowVerification()
        app.delegate = delegate; app.run(); return
    }
    if CommandLine.arguments.contains("--show-window"),
       let output = ProcessInfo.processInfo.environment["KIKIGAKI_DEBUG_AI_PROGRESS_CAPTURE"] {
        let delegate = AIProgressCaptureHarness(output: output)
        app.delegate = delegate; app.run(); return
    }
    if let index = CommandLine.arguments.firstIndex(of: "--minutes-history-ui"), index + 1 < CommandLine.arguments.count {
        let delegate = MinutesHistoryHarness(output: CommandLine.arguments[index + 1])
        app.delegate = delegate; app.run(); return
    }
    if let index = CommandLine.arguments.firstIndex(of: "--preview-minutes"), index + 1 < CommandLine.arguments.count {
        let delegate = MinutesPreviewHarness(path: CommandLine.arguments[index + 1])
        app.delegate = delegate; app.run(); return
    }
    #endif
    let delegate = AppDelegate(replayDebug: replayDebug)
    app.delegate = delegate
    app.run()
}
