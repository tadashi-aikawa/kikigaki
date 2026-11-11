import Foundation

/// 録音中の画面の記録の対象と、フッターに出す状態。仕様は [画面の記録](docs/screen-capture.md) の「録音中の切り替え」
///
/// 切り替えは「いまの撮影を止めて、新しい対象で始め直す」1本の入口にまとめる。
/// この型は選んだ対象・対象の世代・フッターの表示・イベントの行だけを決める。ストリーム・受付の番号・保留は呼び出し側が持つ。
/// - 対象の世代(`generation`): 選び直すたびに増える。撮影側はこの値を運び、始められた・撮れなくなったの知らせに添えて返す
///   - 知らせは `started(generation:)` と `failed(generation:)` で、いまの世代のときだけ効かせる。古い対象の知らせは捨てる
///   - 世代の新旧はこの型だけが判定する。撮影側は自分で古い知らせを見分けない
/// - 選んだ対象(`selected`)は、選んだ時点で替える。最後に選んだものだけが効く
/// - フッターの表示(`display`)は、撮影を始められた時点で替える。選んだ時点では替えない
///   - 例外: 「撮らない」は撮影をその場で止めるので、その場で替える
/// - 「いま撮る」は、いまの世代の開始を終えて撮っている間だけ。表示と選んだ対象が一致していても、開始の途中なら出さない
///   - 一時停止からの再開も開始の途中に数える。世代は増やさない
/// - イベントの行
///   - 撮っている対象を「撮らない」で切ったら `記録を停止`
///   - 切った後(停止・取得不能)に撮影を始められたら `記録を再開`
///   - 対象を替えただけのとき、撮らずに始めた会議で初めて撮り始めたときは出さない
public struct ScreenTarget<Target: Equatable & Sendable>: Equatable, Sendable {
    public enum Display: Equatable, Sendable {
        case off
        case on(Target)
        /// 撮れなくなった。対象は撮れなくなったときに選んでいたもの。
        case failed(Target)
    }

    /// 選んだときに呼び出し側が行うこと。どちらも、いまの撮影を止めてから行う。
    public enum Action: Equatable, Sendable {
        /// 何もしない。いま撮っている対象と同じものを選んだ。世代も替えない。
        case keep
        /// いまの撮影を止める。recordStopped: `記録を停止` の行を残す
        case stop(recordStopped: Bool, generation: Int)
        /// いまの撮影を止めて、この対象で始め直す。
        case start(Target, generation: Int)
    }

    public private(set) var display: Display = .off
    /// 最後に選んだ対象。nilは「撮らない」。
    public private(set) var selected: Target?
    /// 対象の世代。選び直して止めるか始め直すたびに増える。
    public private(set) var generation = 0
    /// いまの世代の開始を待っている。
    private var starting = false
    /// 切った後に、まだ撮影を始めていない。次に始めたら `記録を再開` を残す。
    private var cut = false

    public init() {}

    /// いまの世代か。撮影側からの知らせと、撮影を始める直前の確認はこれで決める。
    public func isCurrent(_ value: Int) -> Bool { value == generation }

    /// メニューで選んだ。開始シートの選択も同じ入口を通す。
    public mutating func select(_ target: Target?) -> Action {
        guard let target else {
            guard selected != nil || display != .off else { return .keep }
            selected = nil
            generation += 1
            starting = false
            // 撮っていた(フッターに対象を出していた)ときだけ、撮影を切ったと残す。始める途中で切ったものは何も撮っていない。
            let stopped: Bool
            if case .on = display { stopped = true } else { stopped = false }
            if stopped { cut = true }
            display = .off
            return .stop(recordStopped: stopped, generation: generation)
        }
        // 撮っている対象・開始を待っている対象と同じなら何もしない。撮れなくなった対象は始め直す。
        if target == selected, !isFailed { return .keep }
        selected = target
        generation += 1
        starting = true
        return .start(target, generation: generation)
    }

    /// 一時停止から再開した。閉じたストリームを準備し直す間は、開始を待つ状態にする。
    /// 対象の世代は増やさない。一時停止の前の判定器の比較の基準を保つため。撮らない・撮れなくなった後は何もしない。
    public mutating func resume() {
        guard selected != nil, !isFailed else { return }
        starting = true
    }

    /// 撮影を始められた。古い世代の知らせならnil。いまの世代なら、`記録を再開` を残すかを返す。
    /// 一時停止からの再開でも、同じ世代で呼ばれる。
    public mutating func started(generation value: Int) -> Bool? {
        guard isCurrent(value), let selected else { return nil }
        display = .on(selected)
        starting = false
        defer { cut = false }
        return cut
    }

    /// 撮れなくなった。古い世代の知らせならfalseを返し、何も替えない。以後は撮らない。選び直せば撮り直す。
    public mutating func failed(generation value: Int) -> Bool {
        guard isCurrent(value), let selected else { return false }
        display = .failed(selected)
        starting = false
        cut = true
        return true
    }

    public var isFailed: Bool {
        if case .failed = display { return true }
        return false
    }

    /// 「いま撮る」を出すか。録音中で、いまの世代の開始を終えて選んだ対象を撮っているときだけ。
    /// 替える途中・撮れなくなった後は出さない。替えた後に元の対象へ戻した場合も、戻した開始を終えるまで出さない。
    public func canCaptureNow(recording: Bool) -> Bool {
        guard recording, !starting, let selected else { return false }
        return display == .on(selected)
    }
}
