import Foundation

/// 録音中の会議Markdownの途中保存。アプリが不意に落ちても、最後に書けた分をMarkdownとして読めるようにする。
///
/// 前回書いた本文から**長さ以外**が変わったときだけ書く。長さは録音中ずっと進むので、比べると
/// 無言の間も毎回書くことになる。前回の記録は書き込みに成功したときだけ更新し、失敗した内容は次の周期で書き直す。
/// 停止後の保存は `MeetingArchive` が受け持ち、ここは関与しない。
public struct InterimSave: Sendable {
    private var lastBody: String?

    public init() {}

    /// 変わっていれば `write` へ本文を渡して書く。書いたら true、変化が無く省いたら false。
    /// `write` の失敗はそのまま投げ、前回の記録を進めない
    @discardableResult
    public mutating func save(_ meeting: MeetingMarkdown.Meeting, at date: Date, timeZone: TimeZone = .current,
                              write: (Data) throws -> Void) throws -> Bool {
        var comparable = meeting
        comparable.duration = 0
        let body = MeetingMarkdown.render(comparable, timeZone: timeZone)
        guard body != lastBody else { return false }
        try write(Data(MeetingMarkdown.render(meeting, interimSavedAt: date, timeZone: timeZone).utf8))
        lastBody = body
        return true
    }

    /// 失敗の表示に使う間隔の表記。分で割り切れれば分、それ以外は秒
    public static func intervalLabel(seconds: Int) -> String {
        seconds % 60 == 0 ? "\(seconds / 60)分" : "\(seconds)秒"
    }
}
