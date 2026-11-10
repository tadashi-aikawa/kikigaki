import Foundation

/// 音量のトラックから、ある位置の直前に声があったかを決める。画面の記録の無音の判定に使う。
/// 仕様は [画面の記録](docs/screen-capture.md) の「無音の間の保留」
///
/// - 声のウィンドウ: 0.1秒のウィンドウのうち、音量がしきい値以上のもの。欠測(nil)は声とみなさない
/// - しきい値は小音量の除外と同じ値を使う。利用者が「声とみなす音量」を決める所を1つにするため。除外のオン・オフは見ない
/// - 話者判別ではなく音量で測る理由: 話者判別を切った会議でも使え、確定の遅れが無い。
///   打鍵などを声と取り違えても、画面が残る側に倒れるだけで消えはしない
public struct VoiceActivity: Equatable, Sendable {
    /// 声のウィンドウが途切れてこの秒数続いたら無音とみなす。
    /// 2秒では発言の合間の息継ぎで切れやすく、5秒では黙ってスライドを2枚送る程度の間が無音にならない。
    public static let defaultSilenceSeconds = 3.0

    public var thresholdDBFS: Double
    public var silenceSeconds: Double

    public init(thresholdDBFS: Double, silenceSeconds: Double = Self.defaultSilenceSeconds) {
        self.thresholdDBFS = thresholdDBFS; self.silenceSeconds = silenceSeconds
    }

    public func isVoice(_ level: Double?) -> Bool { level.map { $0 >= thresholdDBFS } ?? false }

    /// 位置tの過去 `silenceSeconds` 秒にかかるウィンドウの番号。始まりがt以上のウィンドウは含めない。
    /// 判定には上端までのウィンドウが確定している必要がある。録音の頭では0秒より前を見ない。
    public func windows(endingAt time: Double) -> Range<Int> {
        let end = Self.windowsBefore(time)
        let first = min(end, Self.sample(time - silenceSeconds) / AudioLevelTrack.windowSamples)
        return first..<end
    }

    /// 始まりが位置tより前のウィンドウの数。
    static func windowsBefore(_ time: Double) -> Int {
        let sample = Self.sample(time)
        return sample == 0 ? 0 : (sample - 1) / AudioLevelTrack.windowSamples + 1
    }

    private static func sample(_ time: Double) -> Int {
        guard time.isFinite, time > 0 else { return 0 }
        return Int((time * Double(AudioLevelTrack.sampleRate)).rounded())
    }
}

/// 無音の間に撮った画面を公開せずに持ち、話し始めに最後の1枚だけを出す。
/// 仕様は [画面の記録](docs/screen-capture.md) の「無音の間の保留」
///
/// 行き先は、保存の結果が届いた順ではなく、受付の番号(`sequence`)の順で決める。
/// 受付の番号は、自動の保存も「いま撮る」も呼び出し側が1つのロックの中で振る、単調に増える番号。ここへ来るのは自動の保存だけなので番号は飛ぶ。
/// 自動の保存の受付の順は観測の順と同じ。受け付けた保存は、符号化と書き込みを終えてから遅れて届く。
/// - 受け取った画面は受付の順に並べ、音量が観測位置まで届いてから決める。届く前に決めると、話し始めの直後の画面を無音とみなしてしまう
///   - 例外: 届いている分にすでに声があれば、話している間の画面として待たずに出す
/// - 話している間の画面: 観測位置の過去 `silenceSeconds` 秒に声のウィンドウがある。すぐ出す
/// - 無音の中の画面: 保留する。保留は1枚だけで、次の無音の中の画面が来たら古い方を捨てる
/// - 保留した画面の後に声のウィンドウが来たら(話し始め)、保留していた1枚を出す
///   - 受付済みでまだ届いていない保存があれば、話し始めとして出さずに待つ。届いた画面が無音の中なら、そちらが最後の1枚になる
/// - 境界(一時停止・停止・取得不能・送信・コピー・いま撮る)は受付の番号で引く。境界より前に受け付けた保存が境界の後に届いても、境界の扱いを当てる
///   - 公開の境界(`release`): 届いたらその場で公開する
///   - いま撮るの境界(`supersede`): 無音の中の画面なら、保留せずに捨てる
/// - 出す順は受付の順。保留の古い1枚と話し始めの新しい1枚を入れ替えない
///
/// 録音中に消す操作を作らないため、出していない画面だけを捨てる。捨てた画像ファイルの片付けは呼び出し側が行う。
public struct ScreenSilenceHold<Item> {
    public struct Outcome {
        /// 公開する画面。受付の順。
        public var publish: [Item] = []
        /// 置き換えと「いま撮る」で捨てた画面。公開していない。
        public var discard: [Item] = []
    }

    private struct Waiting { let item: Item; let time: Double; let sequence: Int }
    private struct Held { let item: Item; let time: Double; let sequence: Int; var scanned: Int }

    /// 音量が届くのを待っている画面。受付の順。
    private var waiting: [Waiting] = []
    /// 無音の中の最後の1枚。scanned: 声が無いと確かめ終えたウィンドウの数
    private var held: Held?
    /// この番号より前に受け付けた保存は、届いたら保留せずに公開する。
    private var releasedBelow = 0
    /// この番号より前に受け付けた保存は、無音の中の画面なら保留せずに捨てる。
    private var supersededBelow = 0

    public init() {}

    public var isEmpty: Bool { waiting.isEmpty && held == nil }
    public var count: Int { waiting.count + (held == nil ? 0 : 1) }

    /// 自動の判定で保存した1枚を受け取る。`advance` で行き先を決める。
    /// - sequence: 受付の番号。自動の保存どうしでは、届く順はこの順と同じ
    public mutating func receive(_ item: Item, at time: Double, sequence: Int) {
        waiting.append(Waiting(item: item, time: time, sequence: sequence))
    }

    /// 届いた音量で決められる分を決める。
    /// - levels: 確定したウィンドウの音量。録音の頭から順に並ぶ
    /// - outstanding: 受け付けたが、まだ届いていない自動の保存がある
    public mutating func advance(levels: [Double?], voice: VoiceActivity, outstanding: Bool) -> Outcome {
        var outcome = Outcome()
        while true {
            if let next = waiting.first, next.sequence < releasedBelow {
                // 公開の境界より前に受け付けた保存。音量によらず公開する。保留があれば、それより前に受け付けたので先に出す。
                if let current = held { outcome.publish.append(current.item); held = nil }
                outcome.publish.append(next.item)
                waiting.removeFirst()
                continue
            }
            if var current = held {
                // 次の画面の判定に使う範囲の手前までに声が来れば、話し始め。保留していた1枚を出す。
                // 次の画面がまだ届いていなければ、それが無音の中の最後の1枚かもしれないので待つ。
                let limit: Int
                if let next = waiting.first { limit = min(levels.count, voice.windows(endingAt: next.time).upperBound) }
                else { limit = outstanding ? current.scanned : levels.count }
                if current.scanned < limit, levels[current.scanned..<limit].contains(where: voice.isVoice) {
                    outcome.publish.append(current.item)
                    held = nil
                    continue
                }
                current.scanned = max(current.scanned, limit)
                held = current
            }
            guard let next = waiting.first else { break }
            let range = voice.windows(endingAt: next.time)
            let arrived = range.clamped(to: 0..<levels.count)
            if levels[arrived].contains(where: voice.isVoice) {
                // 話している間の画面。保留がまだあるのは、しきい値の変更で前後の判定が食い違ったときだけ。受付の順に出す。
                if let current = held { outcome.publish.append(current.item); held = nil }
                outcome.publish.append(next.item)
                waiting.removeFirst()
                continue
            }
            guard levels.count >= range.upperBound else { break }
            waiting.removeFirst()
            if next.sequence < supersededBelow {
                // 「いま撮る」より前に観測した無音の中の画面。手動の1枚の方が新しいので保留しない。
                outcome.discard.append(next.item)
                continue
            }
            // 無音の中の画面。保留していた古い1枚と置き換える。
            if let current = held { outcome.discard.append(current.item) }
            held = Held(item: next.item, time: next.time, sequence: next.sequence, scanned: range.upperBound)
        }
        return outcome
    }

    /// 送信・コピー・一時停止・停止・取得不能のイベントの行の直前に、持っている画面を全部出す。
    /// 決められる分を決めた後、保留の1枚と、音量を待っている画面を受付の順に出す。
    /// 待っている画面は無音かもしれないが、AIへ今の画面を渡すことと、話している間の画面を落とさないことを優先する。
    /// - below: 境界の時点までに受け付けた保存の数。受付の番号がこれより小さい保存は、まだ届いていなければ届いたらその場で公開する
    public mutating func release(below bound: Int, levels: [Double?], voice: VoiceActivity) -> Outcome {
        var outcome = advance(levels: levels, voice: voice, outstanding: true)
        releasedBelow = max(releasedBelow, bound)
        if let current = held { outcome.publish.append(current.item) }
        outcome.publish.append(contentsOf: waiting.map(\.item))
        held = nil; waiting = []
        return outcome
    }

    /// 「いま撮る」を公開する前に、それより前に受け付けた自動の保留を捨てる。手動の1枚の方が新しいため。
    /// まだ届いていない分と音量を待っている分も、無音の中の画面と決まったら捨てる。話している間の画面は残す。
    /// - below: 「いま撮る」の受付の番号。これより小さい番号の保留を捨て、後から受け付けた保留は残す
    public mutating func supersede(below bound: Int) -> [Item] {
        supersededBelow = max(supersededBelow, bound)
        guard let current = held, current.sequence < bound else { return [] }
        held = nil
        return [current.item]
    }

    /// 会議の切替・無効化で全部捨て、境界も忘れる。受付の番号は記録ごとに0から数え直すため。
    public mutating func removeAll() -> [Item] {
        let items = (held.map { [$0.item] } ?? []) + waiting.map(\.item)
        self = ScreenSilenceHold()
        return items
    }
}
