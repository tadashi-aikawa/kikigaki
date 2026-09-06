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
            print("Kikigaki (replay debug): questions=\(replayDebug.questions.count) hold=\(replayDebug.hold) rename=\(replayDebug.rename != nil)")
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
    let delegate = AppDelegate(replayDebug: replayDebug)
    app.delegate = delegate
    app.run()
}
