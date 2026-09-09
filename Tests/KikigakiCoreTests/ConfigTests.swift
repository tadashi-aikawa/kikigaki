import Foundation
import Testing

@testable import KikigakiCore

@Suite struct ConfigTests {
    private let home = URL(fileURLWithPath: "/Users/test")

    @Test func AIのアバターは話者と同じパス解決で旧設定も読める() throws {
        for source in ["~/Pictures/ai.png", "/tmp/ai.png", "https://example.com/ai.png", "http://example.com/ai.png",
                       "HTTPS://example.com/AI.png", "HtTp://example.com/AI.png"] {
            let config = try ConfigLoader.parse(toml: "[[ai]]\navatar = \"\(source)\"")
            let resolved = try #require(ResolvedConfig(config: config, home: home).ai)
            #expect(resolved.avatar == (source.hasPrefix("~/") ? "/Users/test/Pictures/ai.png" : source))
            #expect(try JSONDecoder().decode(ResolvedAIConfig.self, from: JSONEncoder().encode(resolved)) == resolved)
        }
        let old = ResolvedAIConfig(config: AIConfig(), home: home)
        #expect(try JSONDecoder().decode(ResolvedAIConfig.self, from: JSONEncoder().encode(old)).avatar == nil)
        for value in ["\"\"", "\"   \"", "\"ftp://example.com/ai.png\"", "\"https://\"", "12", "\"a\\n.png\""] {
            #expect(throws: (any Error).self) { try ConfigLoader.parse(toml: "[[ai]]\navatar = \(value)") }
        }
    }

    @Test func 台帳は省略でき枡数より多く登録できる() throws {
        #expect(ResolvedConfig(config: try ConfigLoader.parse(toml: "")).speakers.isEmpty)
        let toml = (0..<12).map { "[[speakers]]\nname = \"参加者\($0)\"" }.joined(separator: "\n")
        #expect(try ConfigLoader.parse(toml: toml).speakers?.count == 12)
    }

    @Test func 台帳の画像パスとURLと省略を解決する() throws {
        let toml = """
        [[speakers]]
        name = " 田中 "
        avatar = "~/Pictures/tanaka.png"
        [[speakers]]
        name = "迅雷"
        avatar = "https://example.com/jinrai.webp"
        [[speakers]]
        name = "佐藤"
        """
        let speakers = ResolvedConfig(config: try ConfigLoader.parse(toml: toml), home: home).speakers
        #expect(speakers == [.init(name: "田中", avatar: "/Users/test/Pictures/tanaka.png"),
                             .init(name: "迅雷", avatar: "https://example.com/jinrai.webp"), .init(name: "佐藤")])
    }

    @Test func 台帳の名前は必須で空と正規化後の重複を拒否する() {
        for toml in ["[[speakers]]\navatar = \"a.png\"", "[[speakers]]\nname = \"  \"",
                     "[[speakers]]\nname = \"田中\"\n[[speakers]]\nname = \" 田中 \"",
                     "[[speakers]]\nname = 12"] {
            #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: toml) }
        }
    }

    @Test func 使用中候補は別枡だけを検出する() {
        let names = SpeakerNames([1: "田中"])
        #expect(names.otherSlot(using: "田中", excluding: 0) == 1)
        #expect(names.otherSlot(using: "田中", excluding: 1) == nil)
        #expect(names.otherSlot(using: "話者C", excluding: 0) == 2)
        #expect(names.otherSlot(using: "新しい人", excluding: 0) == nil)
    }

    @Test func 空の設定は既定値になる() throws {
        let config = try ConfigLoader.parse(toml: "")
        let resolved = ResolvedConfig(config: config, home: home)
        #expect(resolved.outputDir.path == "/Users/test/Documents/KIKIGAKI")
        #expect(resolved.saveRecording == false)
        #expect(resolved.dropRepeatedBackchannels == false)
        #expect(resolved.toggleRecording == KikigakiConfig.Hotkey(modifiers: ["ctrl", "alt", "cmd"], key: "k"))
        #expect(resolved.togglePause == KikigakiConfig.Hotkey(modifiers: ["ctrl", "alt", "cmd"], key: "p"))
    }

    @Test func 全項目を読める() throws {
        let toml = """
            outputDir = "~/work/minerva/Notes/meetings"
            saveRecording = true
            dropRepeatedBackchannels = true

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
        #expect(resolved.dropRepeatedBackchannels == true)
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

    @Test func 相槌省略は真偽値だけを受け付ける() {
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: "dropRepeatedBackchannels = \"true\"") }
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
