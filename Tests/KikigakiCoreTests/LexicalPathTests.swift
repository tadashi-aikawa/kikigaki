import Foundation
import Testing
@testable import KikigakiCore

/// 保存先の字句上の正規化。ファイルが在るかどうかで結果を変えない。仕様は docs/ai-handoff.md の「画像の参照」
@Suite struct LexicalPathTests {
    @Test(arguments: [
        ("/a/./b", "/a/b"),
        ("/a//b///c", "/a/b/c"),
        ("/a/b/", "/a/b"),
        ("/a/b/.", "/a/b"),
        ("/./a/.//b/", "/a/b"),
        ("/", "/"),
        ("//", "/"),
        ("/private/tmp/x", "/private/tmp/x"),
        // `..` は畳まない。直前がシンボリックリンクなら、字句上で戻すと別の場所になる。
        ("/a/b/../c", "/a/b/../c"),
        ("/a/./b/..//c/", "/a/b/../c"),
        ("/a..b/.c/c.", "/a..b/.c/c."),
    ])
    func 点と重なったスラッシュと末尾のスラッシュを畳み_点二つは残す(input: String, expected: String) {
        #expect(LexicalPath.normalized(input) == expected)
    }

    @Test func 要素の点二つだけを親への参照とみなす() {
        #expect(LexicalPath.containsParentReference("/a/../b"))
        #expect(LexicalPath.containsParentReference("~/link/.."))
        #expect(LexicalPath.containsParentReference(".."))
        #expect(!LexicalPath.containsParentReference("/a..b/c.."))
        #expect(!LexicalPath.containsParentReference("/a/.../b"))
    }

    @Test func 結合文字で始まる要素を区切りと一緒にしない() {
        // Characterで分けると "/\u{0301}" が1文字にまとまり、"tmp/\u{0301}" が1つの要素に見える。
        let path = "/tmp/\u{0301}/../out"
        #expect(LexicalPath.containsParentReference(path))
        #expect(Array(LexicalPath.normalized(path).unicodeScalars) == Array(path.unicodeScalars))
        let dotted = "/tmp/\u{0301}/./out/"
        #expect(Array(LexicalPath.normalized(dotted).unicodeScalars) == Array("/tmp/\u{0301}/out".unicodeScalars))
        // 点に結合文字が付いた要素は `.` ではない。
        let accentedDot = "/tmp/.\u{0301}/out"
        #expect(Array(LexicalPath.normalized(accentedDot).unicodeScalars) == Array(accentedDot.unicodeScalars))
    }

    @Test func NFCとNFDの名前をそのまま保つ() {
        let nfc = "/Users/someone/カ\u{3099}イ/./meeting"   // NFD: カ + 結合用濁点
        let composed = "/Users/someone/\u{30AC}イ/./meeting" // NFC: ガ
        #expect(Array(LexicalPath.normalized(nfc).unicodeScalars) == Array("/Users/someone/カ\u{3099}イ/meeting".unicodeScalars))
        #expect(Array(LexicalPath.normalized(composed).unicodeScalars) == Array("/Users/someone/\u{30AC}イ/meeting".unicodeScalars))
    }

    @Test func 在るディレクトリでも無いディレクトリでも同じ結果にし_private_tmpを外さない() throws {
        let existing = URL(fileURLWithPath: "/private/tmp/kikigaki-lexical-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: existing) }
        let missing = "/private/tmp/kikigaki-lexical-missing-" + UUID().uuidString
        #expect(LexicalPath.normalized(existing.path + "/./") == existing.path)
        #expect(LexicalPath.normalized(missing + "/./") == missing)
        // URLはディレクトリと明示して作る。在るかどうかで末尾のスラッシュが変わらない。
        let made = [LexicalPath.directory(existing.path), LexicalPath.directory(missing)]
        #expect(made.allSatisfy { $0.hasDirectoryPath && $0.absoluteString.hasSuffix("/") })
        #expect(made.map(\.path) == [existing.path, missing])
        // 比較: standardizedFileURL は在るときだけ /private を外す。
        #expect(existing.standardizedFileURL.path.hasPrefix("/tmp/"))
    }

    @Test func 設定の保存先は読み込み時に1回だけ正規化しディレクトリとして作る() {
        let home = URL(fileURLWithPath: "/Users/someone")
        func resolved(_ value: String) -> URL { ResolvedConfig(config: KikigakiConfig(outputDir: value), home: home).outputDir }
        #expect(resolved("/private/tmp/./meeting").path == "/private/tmp/meeting")
        #expect(resolved("/private/tmp/meeting/").path == "/private/tmp/meeting")
        #expect(resolved("/private/tmp//meeting").path == "/private/tmp/meeting")
        #expect(resolved("~/Documents/./KIKIGAKI/").path == "/Users/someone/Documents/KIKIGAKI")
        #expect(resolved("~").path == "/Users/someone")
        #expect(resolved("/private/tmp/meeting").path == "/private/tmp/meeting")
        #expect(resolved("/private/tmp/meeting").hasDirectoryPath)
        #expect(ResolvedConfig(config: KikigakiConfig(), home: home).outputDir.path == "/Users/someone/Documents/KIKIGAKI")
    }

    @Test(arguments: ["~/link/../meetings", "/Volumes/archive/../meetings", "/a/b/..", "~/.."])
    func 保存先の要素に点二つがあれば設定エラーにする(value: String) {
        #expect(throws: ConfigError.self) { try ConfigLoader.parse(toml: "outputDir = \"\(value)\"") }
    }

    @Test func 点二つを含まない名前と点の保存先は受け付ける() throws {
        for value in ["~/a..b", "/data/.../meetings", "/private/tmp/./meetings/"] {
            #expect(try ConfigLoader.parse(toml: "outputDir = \"\(value)\"").outputDir == value)
        }
    }
}
