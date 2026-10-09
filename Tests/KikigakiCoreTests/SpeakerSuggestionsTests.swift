import Foundation
import Testing
@testable import KikigakiCore

@Suite struct SpeakerSuggestionsTests {
    @Test func ブロックリストと引用符とコメントを読む() {
        let text = """
        ---
        title: 会議
        attendees:
          - Bob
          - "Tadashi Aikawa" # コメント
          - 'O''Brien'
          - "松岡, 太郎"
          - Bob
        other: value
        ---
        本文
        """
        #expect(SpeakerSuggestions.attendees(in: text) == ["Bob", "Tadashi Aikawa", "O'Brien", "松岡, 太郎"])
    }

    @Test func フローリストとエスケープを読む() {
        let text = #"---\nattendees: [Bob, "Tadashi Aikawa", 'O''Brien', "Bob, Jr.", "Say \"Hi\""] # comment\n---\n本文"#
            .replacingOccurrences(of: #"\n"#, with: "\n")
        #expect(SpeakerSuggestions.attendees(in: text) == ["Bob", "Tadashi Aikawa", "O'Brien", "Bob, Jr.", "Say \"Hi\""])
        #expect(SpeakerSuggestions.attendees(in: "---\nattendees: [\n  Bob,\n  '松岡'\n]\n---") == ["Bob", "松岡"])
    }

    @Test func frontmatterが無いか不正なら空() {
        for text in ["本文\nattendees: [Bob]", "attendees: [Bob]", "---\ntitle: Bob\n---",
                     "---\nattendees: [Bob]", "---\nattendees: Bob\n---", "---\nattendees: ['Bob]\n---",
                     "---\nattendees:\n  - {name: Bob}\n---", "---\nattendees: []\n---"] {
            #expect(SpeakerSuggestions.attendees(in: text).isEmpty)
        }
    }

    @Test func YAMLのUnicodeエスケープと引用符を含む平文とフロー内コメントを読む() {
        let text = #"---\nattendees: ["Tadashi\x20Aikawa", "\u677e\u5ca1", "\U0001F600", O'Brien, # comment\n Bob, null]\n---"#
            .replacingOccurrences(of: #"\n"#, with: "\n")
        #expect(SpeakerSuggestions.attendees(in: text) == ["Tadashi Aikawa", "松岡", "😀", "O'Brien", "Bob"])
    }

    @Test func 改行形式とインデント無しのリストを読む() {
        #expect(SpeakerSuggestions.attendees(in: "\u{FEFF}---\r\nattendees:\r\n- Bob\r\n- '松岡'\r\n...\r\n") == ["Bob", "松岡"])
    }

    @Test func ファイルは毎回読み直し欠損を無視する() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("minutes.md")
        #expect(SpeakerSuggestions.attendees(at: nil).isEmpty)
        #expect(SpeakerSuggestions.attendees(at: url).isEmpty)
        try "---\nattendees: [Bob]\n---".write(to: url, atomically: true, encoding: .utf8)
        #expect(SpeakerSuggestions.attendees(at: url) == ["Bob"])
        try "---\nattendees: [松岡]\n---".write(to: url, atomically: true, encoding: .utf8)
        #expect(SpeakerSuggestions.attendees(at: url) == ["松岡"])
    }

    @Test func 会議数で集計し既定名は除く() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try meeting("2026-10-09_1000", speakers: "A=Bob, B=Bob, C=話者C, D=松岡", in: directory)
        try meeting("2026-10-08_1000", speakers: "A=松岡, B=古い名前", in: directory)
        #expect(SpeakerSuggestions.frequentNames(in: directory, excluding: nil) == ["松岡", "Bob", "古い名前"])
        #expect(SpeakerSuggestions.names(inSpeakerLine: "- 話者: A=Bob, Jr., B=話者B, C=話者A, 9=話者9") == ["Bob, Jr."])
    }

    @Test func 同数なら新しい会議を優先し更新時刻には依存しない() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try meeting("2026-10-08_1000", speakers: "A=古い名前", in: directory)
        try meeting("2026-10-09_1000", speakers: "A=新しい名前", in: directory)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
            ofItemAtPath: directory.appendingPathComponent("2026-10-08_1000.md").path)
        #expect(SpeakerSuggestions.frequentNames(in: directory, excluding: nil) == ["新しい名前", "古い名前"])
    }

    @Test func 直近30会議に制限し現在の会議と別種のMarkdownを除く() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 1...31 {
            try meeting(String(format: "2026-10-09_%04d", index), speakers: "A=\(index == 1 ? "範囲外" : "Bob")", in: directory)
        }
        let current = directory.appendingPathComponent("2026-10-09_9999.md")
        try meeting("2026-10-09_9999", speakers: "A=録音中", in: directory)
        try "# 議事録\n- 話者: A=議事録".write(to: directory.appendingPathComponent("2026-10-09_9998.md"), atomically: true, encoding: .utf8)
        for name in ["2026-10-09_9997.raw.md", "minutes.md", "2026-10-09_9996.archive.md"] {
            try "# KIKIGAKI sample\n- 話者: A=別ファイル".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        #expect(SpeakerSuggestions.frequentNames(in: directory, excluding: current) == ["Bob"])
        #expect(SpeakerSuggestions.frequentNames(in: nil, excluding: nil).isEmpty)
    }

    @Test func 同じ分の会議の連番を数値で並べる() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (suffix, name) in [("", "一番"), ("_2", "二番"), ("_10", "十番")] {
            try meeting("2026-10-09_1000" + suffix, speakers: "A=\(name)", in: directory)
        }
        #expect(SpeakerSuggestions.frequentNames(in: directory, excluding: nil) == ["十番", "二番", "一番"])
    }

    @Test func 参加者を頻度順にし重複を除き台帳の画像を引き継ぐ() {
        let candidates = SpeakerSuggestions.candidates(attendees: ["Bob", "初参加", "松岡", "未使用"],
            frequent: ["松岡", "Bob", "伊藤"], speakers: [.init(name: "Bob", avatar: "bob.webp"), .init(name: "本田")],
            names: SpeakerNames(), excluding: 1)
        #expect(candidates.map(\.name) == ["松岡", "Bob", "初参加", "未使用", "伊藤", "本田"])
        #expect(candidates.prefix(4).allSatisfy { $0.isAttendee })
        #expect(candidates[1].avatar == "bob.webp")
        #expect(candidates[0].avatar == nil)
    }

    @Test func 使用中は出どころに関係なく末尾で選択不可() {
        let candidates = SpeakerSuggestions.candidates(attendees: ["タダシ", "Bob"], frequent: ["伊藤"],
            speakers: [.init(name: "本田")], names: SpeakerNames([0: "タダシ", 1: "Bob", 2: "会議だけの名前"]), excluding: 1)
        #expect(candidates.map(\.name) == ["Bob", "伊藤", "本田", "タダシ", "会議だけの名前"])
        #expect(candidates[0].isSelectable)
        #expect(candidates[3].usedBySlot == 0)
        #expect(candidates[4].usedBySlot == 2)
        #expect(!candidates[3].isSelectable)
    }

    @Test func 前方一致を優先し大小文字を区別せず各群の元の順位を保つ() {
        let candidates = SpeakerSuggestions.candidates(attendees: ["Mr. Tadashi", "Tadashi Aikawa", "TADASHI"],
            frequent: ["tadashi junior"], speakers: [], names: SpeakerNames([0: "tadashi used"]), excluding: 1)
        #expect(SpeakerSuggestions.filtered(candidates, query: "tadashi").map(\.name)
                == ["Tadashi Aikawa", "TADASHI", "tadashi junior", "tadashi used", "Mr. Tadashi"])
        #expect(SpeakerSuggestions.filtered(candidates, query: "").map(\.name) == candidates.map(\.name))
        #expect(SpeakerSuggestions.filtered(candidates, query: "佐々木").isEmpty)
    }

    @Test func 完全一致は選べる名前だけで大小も区別する() {
        let candidates = SpeakerSuggestions.candidates(attendees: ["Bob", "Tadashi"], frequent: [], speakers: [],
            names: SpeakerNames([0: "Tadashi"]), excluding: 1)
        #expect(SpeakerSuggestions.exactMatch(in: candidates, query: "Bob")?.name == "Bob")
        #expect(SpeakerSuggestions.exactMatch(in: candidates, query: "bob") == nil)
        #expect(SpeakerSuggestions.exactMatch(in: candidates, query: "Tadashi") == nil)
    }

    @Test func 強調範囲はUnicodeと複数一致に対応する() {
        #expect(SpeakerSuggestions.matchRanges(in: "松岡と松本", query: "松") == [NSRange(location: 0, length: 1), NSRange(location: 3, length: 1)])
        #expect(SpeakerSuggestions.matchRanges(in: "😀TADASHI", query: "tadashi") == [NSRange(location: 2, length: 7)])
        #expect(SpeakerSuggestions.matchRanges(in: "Bob", query: "").isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-suggestions-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func meeting(_ stem: String, speakers: String, in directory: URL) throws {
        try "# KIKIGAKI 2026-10-09 10:00\n\n- 開始: 2026-10-09 10:00\n- 長さ: 00:01\n- 話者: \(speakers)\n\n## 書き起こし\n"
            .write(to: directory.appendingPathComponent(stem + ".md"), atomically: true, encoding: .utf8)
    }
}
