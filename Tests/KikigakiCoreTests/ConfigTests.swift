import Foundation
import Testing

@testable import KikigakiCore

@Suite struct ConfigTests {
    private let home = URL(fileURLWithPath: "/Users/test")

    @Test func 空の設定は既定値になる() throws {
        let config = try ConfigLoader.parse(toml: "")
        let resolved = ResolvedConfig(config: config, home: home)
        #expect(resolved.outputDir.path == "/Users/test/Documents/KIKIGAKI")
        #expect(resolved.saveRecording == false)
        #expect(resolved.toggleRecording == KikigakiConfig.Hotkey(modifiers: ["ctrl", "alt", "cmd"], key: "k"))
        #expect(resolved.togglePause == KikigakiConfig.Hotkey(modifiers: ["ctrl", "alt", "cmd"], key: "p"))
    }

    @Test func 全項目を読める() throws {
        let toml = """
            outputDir = "~/work/minerva/Notes/meetings"
            saveRecording = true

            [hotkeys.toggleRecording]
            modifiers = ["cmd", "shift"]
            key = "f18"

            [hotkeys.togglePause]
            modifiers = ["cmd", "shift"]
            key = "f19"
            """
        let resolved = ResolvedConfig(config: try ConfigLoader.parse(toml: toml), home: home)
        #expect(resolved.outputDir.path == "/Users/test/work/minerva/Notes/meetings")
        #expect(resolved.saveRecording == true)
        #expect(resolved.toggleRecording == KikigakiConfig.Hotkey(modifiers: ["cmd", "shift"], key: "f18"))
        #expect(resolved.togglePause == KikigakiConfig.Hotkey(modifiers: ["cmd", "shift"], key: "f19"))
    }

    @Test func 絶対パスはそのまま() throws {
        let config = try ConfigLoader.parse(toml: "outputDir = \"/Volumes/data/meetings\"")
        #expect(ResolvedConfig(config: config, home: home).outputDir.path == "/Volumes/data/meetings")
    }

    @Test func 空の保存先は不正() {
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: "outputDir = \"  \"") }
    }

    @Test func 空のキーは不正() {
        let toml = """
            [hotkeys.toggleRecording]
            modifiers = []
            key = ""
            """
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: toml) }
    }

    @Test func 相対パスの保存先は不正() {
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: "outputDir = \"meetings\"") }
    }

    @Test func 不明な修飾キーは不正() {
        let toml = """
            [hotkeys.togglePause]
            modifiers = ["hyper"]
            key = "p"
            """
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: toml) }
    }

    @Test func 修飾キーの別名は同じ扱い() throws {
        let toml = """
            [hotkeys.toggleRecording]
            modifiers = ["Command", "option"]
            key = "K"
            """
        _ = try ConfigLoader.parse(toml: toml)
    }

    @Test func 二つの操作に同じキーは不正() {
        let toml = """
            [hotkeys.toggleRecording]
            modifiers = ["cmd", "alt", "ctrl"]
            key = "P"

            [hotkeys.togglePause]
            modifiers = ["control", "option", "command"]
            key = "p"
            """
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: toml) }
    }

    @Test func 片方だけ既定と同じキーにしても不正() {
        // togglePause の既定 ctrl+alt+cmd+P と衝突
        let toml = """
            [hotkeys.toggleRecording]
            modifiers = ["ctrl", "alt", "cmd"]
            key = "p"
            """
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: toml) }
    }

    @Test func TOMLの文法エラーは不正() {
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: "outputDir = ") }
    }

    @Test func ファイルがなければ既定設定() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/kikigaki/config.toml")
        #expect(try ConfigLoader.load(from: missing) == KikigakiConfig())
    }
}

@Suite struct RecordingStateTests {
    @Test func メニュー表題と可否() {
        #expect(RecordingState.idle.startStopTitle == "録音を開始")
        #expect(RecordingState.recording.startStopTitle == "録音を停止")
        #expect(RecordingState.paused.startStopTitle == "録音を停止")
        #expect(RecordingState.paused.pauseResumeTitle == "再開")
        #expect(RecordingState.recording.pauseResumeTitle == "一時停止")
        #expect(RecordingState.idle.canStart)
        #expect(!RecordingState.preparing.canStart)
        #expect(RecordingState.recording.canStop && RecordingState.paused.canStop)
        #expect(!RecordingState.finishing.canStop)
        #expect(!RecordingState.idle.canPauseOrResume)
    }
}
