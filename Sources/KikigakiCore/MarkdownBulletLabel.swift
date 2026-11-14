import Foundation

/// 箇条書きの行頭の「ラベル: 」(`- 理由: …` の `理由`)。描画側はラベルを塗りで描き、`:` を見せない。
///
/// 判定はparliamentの `packages/web/src/bullet-label.ts` と同じ。仕様の正はparliamentの
/// `docs/thread-bullet-label.md` で、KIKIGAKIでの描き方は [AIの返事のMarkdown表示](docs/ai-markdown.md)。
/// 議事録プレビューの同じ判定は `web/minutes/renderer.js` の `bulletLabel`。
///
/// **字としての `:` は残す**。描く側はコロンを見せないだけで、選んでコピーした文字列は `理由: …` のまま。
public struct MarkdownBulletLabel: Equatable, Sendable {
    /// 塗りの中に出す字。コロンを含まない
    public var label: String
    /// 塗りのまま折り返してよい長いラベル。短いラベルは1かたまりで描き、折り返しで塗りを割らない
    public var long: Bool
    /// ラベルと `:` を除いた残り。後ろの空白は残す(コピーで `理由: …` に戻るため)
    public var rest: [MarkdownInline]

    /// この字数を超えるラベルは折り返してよい
    public static let nowrapCharacters = 12

    /// ラベルにコロン・括弧・記号類・句読点を含めない。句読点は `推奨はA。理由: …` のような文を外す。
    /// 字数と空白は問わない(`GitHub Release: …` もラベル)。数字だけ(`0: …`)もラベル。
    private static let forbidden = Set("\n:：()（）[]`*_~<>\"'|。、，．！？!?「」『』")

    /// 項目の行内トークンからラベルを切り出す。ラベルで始まらなければnil。
    ///
    /// 先頭は飾りの無い地の文か、ちょうどラベルを囲む太字(`**理由**: …` / `**理由:** …`)だけ。
    /// コード・リンク・斜体で始まる行は拾わない。
    public static func split(_ content: [MarkdownInline]) -> MarkdownBulletLabel? {
        guard let head = content.first, !head.isCode, !head.isLineBreak, head.destination == nil else { return nil }
        let tail = Array(content.dropFirst())
        if head.style == [] { return split(text: head.text, tail: tail) }
        guard head.style == .strong else { return nil }
        // 太字の中身と、続く地の文の頭をつないで同じ規則で判定し、ラベルが太字の中身と
        // ちょうど一致するときだけ拾う。`**理**由: …` は書き手の意図が読めないので太字のまま。
        // 塗りの中は太字にしない。太字だったことは塗りに置き換わって消える。
        let follows = tail.first.flatMap(isPlain) == true ? tail[0].text : ""
        let after = follows.isEmpty ? tail : Array(tail.dropFirst())
        guard let found = split(text: head.text + follows, tail: after),
              found.label == head.text || found.label + ":" == head.text else { return nil }
        return found
    }

    private static func isPlain(_ run: MarkdownInline) -> Bool {
        run.style == [] && !run.isCode && !run.isLineBreak && run.destination == nil
    }

    /// `:` の後ろは空白1つか行末。行末は**行の終わり**で見る ── `理由:**遅い**` の先頭は `理由:` で
    /// 終わるが、行は空白なしで続くので拾わない。`<br>` は行の終わりとして扱う。
    private static func split(text: String, tail: [MarkdownInline]) -> MarkdownBulletLabel? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let label = String(text[..<colon])
        guard !label.isEmpty, !label.contains(where: forbidden.contains),
              label.trimmingCharacters(in: .whitespaces) == label else { return nil }
        let rest = String(text[text.index(after: colon)...])
        if rest.isEmpty {
            guard tail.first.map(\.isLineBreak) ?? true else { return nil }
        } else if rest.first != " " { return nil }
        var runs = tail
        if !rest.isEmpty { runs.insert(MarkdownInline(rest), at: 0) }
        // parliamentはコードポイントで数える。結合文字・絵文字でも同じ境目にする。
        return MarkdownBulletLabel(label: label, long: label.unicodeScalars.count > nowrapCharacters, rest: runs)
    }
}
