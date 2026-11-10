import Foundation

/// パスの字句上の正規化。ファイルやディレクトリが在るかどうかを見ず、文字列だけで決める。
///
/// `.`、重なったスラッシュ、末尾のスラッシュを畳む。どれも畳んでも指す場所が変わらない。
/// `..` は畳まない。直前の要素がシンボリックリンクなら、字句上で1つ戻した場所とOSが辿る場所が違うため。
/// `/private/tmp` を `/tmp` へ変える処理とシンボリックリンクの解決も入れない。
/// - 理由: `standardizedFileURL` はファイルが在るときだけ `/private` を外す。会議Markdownを書く前と後で値が変わり、
///   会話ファイル・`image_dirs`・行の画像参照の表記がずれる
///
/// 区切りはUnicodeスカラーの `/` で探す。`Character` で分けると、`/` の直後の結合文字が `/` と1文字にまとまり、
/// 要素の境目を見失う。要素の中のスカラーは並びも正規化形(NFC・NFD)もそのまま保つ。
///
/// 保存先を確定する所(`ResolvedConfig.outputDir`)で1回だけ通し、会議Markdown・画像の置き場・会話ファイルはその値から導く。
/// 仕様は docs/ai-handoff.md の「画像の参照」
public enum LexicalPath {
    private static let separator: Unicode.Scalar = "/"
    private static let current: [Unicode.Scalar] = ["."]
    private static let parent: [Unicode.Scalar] = [".", "."]

    /// 空でない要素。`/` の連なりは1つの区切りとして扱う。
    private static func components(_ path: String) -> [[Unicode.Scalar]] {
        path.unicodeScalars.split(separator: separator, omittingEmptySubsequences: true).map(Array.init)
    }

    public static func normalized(_ path: String) -> String {
        let absolute = path.unicodeScalars.first == separator
        // 要素の比較はスカラーの並びで行う。Stringの等価性は正規化形の違いを同一視するため使わない。
        let parts = components(path).filter { $0 != current }
        var scalars = String.UnicodeScalarView()
        if absolute { scalars.append(separator) }
        for (index, part) in parts.enumerated() {
            if index > 0 { scalars.append(separator) }
            scalars.append(contentsOf: part)
        }
        let result = String(scalars)
        return result.isEmpty ? "." : result
    }

    /// 要素に `..` があるか。`a..b` のような名前は当たらない。
    public static func containsParentReference(_ path: String) -> Bool {
        components(path).contains(parent)
    }

    /// 正規化したディレクトリのURL。`isDirectory` を明示し、`URL(fileURLWithPath:)` にディレクトリかどうかを
    /// ファイルシステムへ問い合わせさせない。問い合わせると、在るかどうかで末尾のスラッシュが変わる。
    public static func directory(_ path: String) -> URL {
        URL(fileURLWithPath: normalized(path), isDirectory: true)
    }
}
