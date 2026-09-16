import Foundation
import Testing
@testable import KikigakiCore

@Suite struct URLSchemeTests {
    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    @Test func パーセントエンコードした絶対パスを議事録として受ける() {
        let value = KikigakiURL.start("kikigaki://start?minutes=/Users/tadashi/work/2026-09-16%20%E5%AE%9A%E4%BE%8B.md")
        #expect(value == KikigakiURL.Start(minutesPath: "/Users/tadashi/work/2026-09-16 定例.md"))
    }

    @Test func チルダ始まりは展開する() {
        let value = KikigakiURL.start("kikigaki://start?minutes=~%2Fwork%2Fminutes.md")
        #expect(value?.minutesPath == home + "/work/minutes.md")
        #expect(value?.problem == nil)
    }

    @Test func 他人のホームのチルダは展開せず理由を返す() {
        #expect(KikigakiURL.start("kikigaki://start?minutes=~someone/work/minutes.md")?.problem == KikigakiURL.minutesProblem)
    }

    @Test func スキームは大文字小文字を問わない() {
        #expect(KikigakiURL.start("KIKIGAKI://START?minutes=/work/a.md")?.minutesPath == "/work/a.md")
    }

    @Test func 議事録が無ければ指定なしで開始シートだけを開く() {
        #expect(KikigakiURL.start("kikigaki://start") == KikigakiURL.Start())
        // 空の指定は間違いというほどでもないので、理由を出さず指定なしとして扱う。
        #expect(KikigakiURL.start("kikigaki://start?minutes=") == KikigakiURL.Start())
        #expect(KikigakiURL.start("kikigaki://start?minutes=%20%20") == KikigakiURL.Start())
    }

    @Test func minutes以外のクエリは無視する() {
        #expect(KikigakiURL.start("kikigaki://start?theme=dark&minutes=/work/a.md&diarization=off")?.minutesPath == "/work/a.md")
        #expect(KikigakiURL.start("kikigaki://start?theme=dark") == KikigakiURL.Start())
    }

    @Test func start以外のホストと別スキームは捨てる() {
        #expect(KikigakiURL.start("kikigaki://stop?minutes=/work/a.md") == nil)
        #expect(KikigakiURL.start("kikigaki://start/extra?minutes=/work/a.md") == nil)
        #expect(KikigakiURL.start("kikigaki:start?minutes=/work/a.md") == nil)
        #expect(KikigakiURL.start("https://example.com/start?minutes=/work/a.md") == nil)
        #expect(KikigakiURL.start("") == nil)
    }

    @Test func 読めない議事録はパスを返さず理由だけを返す() {
        for path in ["relative.md", "/work/a.txt", "/work/../a.md", "/work/./a.md", "/", "~",
                     "/work/.kikigaki-context/a.md", "/work/" + String(repeating: "あ", count: 400) + ".md"] {
            let value = KikigakiURL.start("kikigaki://start?minutes=" + encoded(path))
            #expect(value == KikigakiURL.Start(problem: KikigakiURL.minutesProblem), "\(path)")
        }
    }

    @Test func 改行や制御文字を含む指定は受けない() {
        // URLとして読めた場合だけ理由を返す。読めない形は捨てるので、どちらでもパスは通さない。
        #expect(KikigakiURL.start("kikigaki://start?minutes=%2Fwork%2Fa%0Ab.md")?.minutesPath == nil)
        #expect(KikigakiURL.start("kikigaki://start?minutes=%2Fwork%2Fa%00b.md")?.minutesPath == nil)
    }

    private func encoded(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
    }
}
