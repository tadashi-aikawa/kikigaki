import Foundation

/// 書き起こしウィンドウの画像レーン。画面の行を発言の列から外し、発言の横へ並べる。
/// 表示専用で、保存するMarkdown・コピー・AIへ渡す会話は変えない。仕様は [画面の記録](docs/screen-capture.md) の「表示」
///
/// 割り当ては行の並びから毎回導き、状態として持たない。録音中は行が増え、話者の付け替え・併合で
/// 声の行の区間が変わるため、持つと古い割り当てを直す経路が要る。
public enum ScreenLane {
    /// 画面の行の置き場。添字は `assign` へ渡した行の並びのもの。
    public struct Assignment: Equatable, Sendable {
        /// 声の行の添字 → その横に出す画面の行の添字。並びは渡した行の並び(観測の位置順)
        public var beside: [Int: [Int]] = [:]
        /// 後ろに声の行がまだ無い画面の行。会議の末尾と、録音中の最新が当たる。
        /// 聞き取り中の行があればその横、無ければ末尾に出す。次の声の行が届けばそちらへ移る
        public var trailing: [Int] = []

        public init(beside: [Int: [Int]] = [:], trailing: [Int] = []) {
            self.beside = beside
            self.trailing = trailing
        }
    }

    /// 画面の行を、観測した時点に話していた声の行へ割り当てる。誰も話していなければ次の声の行へ。
    ///
    /// - 手入力の行は割り当て先にしない。理由: 手入力は投稿した時点の点で「話していた」区間を持たず、
    ///   自分の添付画像も持つ。画面のサムネイルを横に並べると、どちらが貼った画像か取り違えやすい
    /// - 声の行の区間が重なっていれば、後から話し始めた行を採る。話者の交代の直後に映った画面を、
    ///   言い終わりかけの前の話者より、話し始めた次の話者に結びつけるため
    public static func assign(_ utterances: [Utterance]) -> Assignment {
        var result = Assignment()
        let voices = utterances.indices.filter { utterances[$0].kind == .voice }
            .sorted { (utterances[$0].start, $0) < (utterances[$1].start, $1) }
        // 先頭からk件目までの終わりの最大値。観測の時点を含む声の行が手前にあるかを二分探索の後に1回で判定する。
        var latestEnd: [Double] = []
        for index in voices { latestEnd.append(max(latestEnd.last ?? -.infinity, utterances[index].end)) }
        for index in utterances.indices where utterances[index].kind == .screen {
            let time = utterances[index].start
            // 話し始めが観測の時点以前の声の行の数
            var low = 0, high = voices.count
            while low < high {
                let middle = (low + high) / 2
                if utterances[voices[middle]].start <= time { low = middle + 1 } else { high = middle }
            }
            var target: Int?
            if low > 0, latestEnd[low - 1] >= time {
                var candidate = low - 1
                while utterances[voices[candidate]].end < time { candidate -= 1 }
                target = voices[candidate]
            } else if low < voices.count {
                target = voices[low]
            }
            if let target { result.beside[target, default: []].append(index) } else { result.trailing.append(index) }
        }
        return result
    }

    /// レーンの1枠。
    public enum Slot: Equatable, Sendable {
        /// 画像の行かイベントの行。
        case screen(Int)
        /// 畳んだ画像の連なり。押すとその場で開く。
        case folded([Int])
        /// 開いた画像の連なりの頭に置く「畳む」。続けて連なりの各画像を `screen` で並べる。
        /// 「+N枚」があった位置に替わって出し、開いた場所と閉じる場所を同じにする。
        case expanded([Int])
    }

    /// 1つの発言の横に出す枠。画像が2枚までなら全部、3枚以上なら最初と最後を出し、間を畳む。
    ///
    /// - イベントの行(停止・再開・取得不能)は畳まない。撮れなかった期間を見落とさないため。
    ///   イベントの行を挟んだ間の画像は、イベントの行の前後で別の連なりに畳む
    /// - `expanded`: 押して開いた画像のパス。割り当て先が変わっても開いたまま保つため、発言ではなく画像で覚える
    ///   - 間の画像のうち、開いた画像の連なりは「畳む」を頭に付けて全部出す。開いた後に届いて間に入った画像は、
    ///     開いた連なりとは別の「+N枚」に畳む
    public static func slots(_ screens: [Int], utterances: [Utterance], expanded: Set<String>) -> [Slot] {
        let images = screens.filter { !utterances[$0].imagePaths.isEmpty }
        var result: [Slot] = []
        var folded: [Int] = []
        var opened: [Int] = []
        func flush() {
            if !folded.isEmpty { result.append(.folded(folded)) }
            if !opened.isEmpty { result.append(.expanded(opened)); result += opened.map(Slot.screen) }
            folded = []; opened = []
        }
        for index in screens {
            guard let path = utterances[index].imagePaths.first, index != images.first, index != images.last else {
                flush()
                result.append(.screen(index))
                continue
            }
            if expanded.contains(path) {
                if !folded.isEmpty { flush() }
                opened.append(index)
            } else {
                if !opened.isEmpty { flush() }
                folded.append(index)
            }
        }
        flush()
        return result
    }

    static let displaySeparator = " · "

    /// 会議の全画像の見出しが同じディスプレイ名で始まるなら、その名前。
    /// 撮るディスプレイは会議ごとに1つで、毎枚同じ名前をサムネイルの下に重ねて言わないために省く。
    /// どれか1つでも ` · ` の前にその名前を持たなければ、ディスプレイ名と確かめられないのでnil。
    public static func sharedDisplayName(_ labels: [String]) -> String? {
        var name: String?
        var separated = false
        for label in labels {
            let head: String
            if let range = label.range(of: displaySeparator) {
                head = String(label[..<range.lowerBound])
                separated = true
            } else {
                head = label
            }
            if name == nil { name = head } else if name != head { return nil }
        }
        return separated ? name : nil
    }

    /// 会議の画像の見出しから、サムネイルの下に添える題を並びの順に決める。
    /// - ディスプレイが1つの会議: 全部の題からディスプレイ名を省く。毎枚同じ名前を重ねて言わない
    /// - 録音中に対象を替えた会議: 直前の画像と同じディスプレイなら省き、違えば残す。最初の1枚も残す
    ///   - 理由: 替えた直後の1枚で、どのディスプレイに替わったかが分かるようにする
    public static func captions(_ labels: [String]) -> [String] {
        if let shared = sharedDisplayName(labels) { return labels.map { caption($0, sharedDisplay: shared) } }
        // ディスプレイ名と確かめられる見出しが1つも無ければ、今までどおり見出しのまま出す。
        guard labels.contains(where: { $0.contains(displaySeparator) }) else { return labels }
        var previous: String?
        return labels.map { label in
            let head = label.range(of: displaySeparator).map { String(label[..<$0.lowerBound]) } ?? label
            defer { previous = head }
            return head == previous ? caption(label, sharedDisplay: head) : label
        }
    }

    /// サムネイルの下に添える題。共通のディスプレイ名を省き、ウィンドウが無ければ空。
    public static func caption(_ label: String, sharedDisplay: String?) -> String {
        guard let display = sharedDisplay else { return label }
        if label == display { return "" }
        let prefix = display + displaySeparator
        return label.hasPrefix(prefix) ? String(label.dropFirst(prefix.count)) : label
    }
}
