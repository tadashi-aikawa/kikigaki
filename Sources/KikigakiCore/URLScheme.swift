import Foundation

/// `kikigaki://` のリンクから受ける指定。
///
/// 開けるのは録音開始シートだけで、リンクから録音そのものは始めない。議事録を用意する側が
/// リンクを出し、人がクリックして開始シートを開くところまでが役目。人が開始を押す一手を
/// 残すのは、押し間違いや古いリンクで勝手に録音が始まらないようにするため。
///
/// 解釈できない形は `nil` で黙って捨て、`kikigaki://start` と読めた上で値だけが悪いものは
/// 理由を返して人へ見せる。捨てるものと見せるものを分けないと、別アプリ宛のURLにまで
/// 画面を出してしまう。
public enum KikigakiURL {
    public static let scheme = "kikigaki"
    /// 開始シートを開くホスト。ほかのホストは増やす余地として空けておく
    public static let startHost = "start"

    /// `kikigaki://start` の中身。
    public struct Start: Equatable, Sendable {
        /// 検証を通った議事録の絶対パス。nilは指定なし
        public let minutesPath: String?
        /// 指定が読めなかった理由。パス欄は触らず、この1行だけを出す
        public let problem: String?
        public init(minutesPath: String? = nil, problem: String? = nil) {
            self.minutesPath = minutesPath
            self.problem = problem
        }
    }

    /// 読めない議事録の指定に出す1行。`MinutesPath.validate` の条件をまとめて言い換える。
    public static let minutesProblem = "リンクの議事録は絶対パスの.mdではありません"

    /// リンクを解釈する。`kikigaki://start` でなければ nil。
    ///
    /// `minutes` 以外のクエリは無視する。知らない指定を握り潰すのは、リンクを出す側が
    /// 先に新しい指定を書いても、古いアプリが黙って開始シートまでは出せるようにするため。
    public static func start(_ text: String) -> Start? {
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == startHost,
              // `kikigaki://start/なにか` は受けない。下位の道は別の意味に使えるよう空けておく
              components.path.isEmpty || components.path == "/" else { return nil }
        guard let value = components.queryItems?.first(where: { $0.name == "minutes" })?.value else { return Start() }
        let input = expandingTilde(value.trimmingCharacters(in: .whitespacesAndNewlines))
        // `minutes=` の空指定は「指定なし」と同じにする。理由を出すほどの間違いではない
        guard !input.isEmpty else { return Start() }
        guard (try? MinutesPath.validate(input)) != nil else { return Start(problem: minutesProblem) }
        return Start(minutesPath: input)
    }

    /// `~/` だけを展開する。`~他人/` は展開せず、絶対パスでないものとして検証で落とす。
    private static func expandingTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return (path as NSString).expandingTildeInPath
    }
}
