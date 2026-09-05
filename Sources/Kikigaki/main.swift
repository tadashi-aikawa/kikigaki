import AppKit
import Foundation
import KikigakiCore

// --smoke: UIを起動せず設定の読み込みだけ確認して終了する(CI・動作確認用)
if CommandLine.arguments.contains("--smoke") {
    do {
        let config = try AppDelegate.loadConfig()
        print("Kikigaki (smoke): outputDir=\(config.outputDir.path) saveRecording=\(config.saveRecording)")
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
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
