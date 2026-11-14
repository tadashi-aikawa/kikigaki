import CoreGraphics
import Foundation

/// 撮っているディスプレイの上に出す「記録中」のバッジと、切り替えた瞬間の知らせ。
/// 仕様は [画面の記録](docs/screen-capture.md) の「撮っている画面の印」
///
/// - バッジ: 撮っている間だけ、撮っているディスプレイの右下に出し続ける。一時停止中・撮らない・撮れなくなった後は出さない
/// - 知らせ: バッジが出る・消える・撮れなくなった瞬間に、画面の中央へ数秒出す
///   - 対象を替えたときは、替えた先で撮り始めた知らせだけを出す。替える前のバッジは黙って消す
public enum ScreenIndicator<Target: Equatable & Sendable>: Equatable, Sendable {
    case hidden
    /// 撮っている。バッジをこの対象に出す。
    case on(Target)
    /// 撮り直しを待っている。対象の替え・一時停止からの再開で、ストリームを準備し直している間。
    /// 対象は撮り直しの前に撮っていたもの。バッジは出さず、知らせも出さない。撮り始めた時点で `on` へ移る。
    case switching(Target)
    /// 撮れなくなった。バッジは出さない。
    case failed(Target)

    /// 対象と録音の状態から決める。target: 画面の操作が無い会議・録音中と一時停止中以外はnil
    /// - 一時停止中は出さない。一時停止の間に対象を選び直しても同じ
    /// - 撮り直しを待つ間は `switching`。開始を待つ理由が対象の替えでも再開でも、撮り始めるまでは何も撮っていない
    public init(target: ScreenTarget<Target>?, paused: Bool) {
        switch target?.display {
        case nil, .off?: self = .hidden
        case let .on(current)?:
            if paused { self = .hidden }
            else if target?.isStarting == true { self = .switching(current) }
            else { self = .on(current) }
        case let .failed(current)?: self = .failed(current)
        }
    }

    /// バッジを出す対象。
    public var badge: Target? {
        if case let .on(target) = self { return target }
        return nil
    }

    public enum Notice: Equatable, Sendable {
        /// 撮り始めた。中央に出してから、右下のバッジへ縮みながら移る。
        case started(Target)
        /// 撮るのをやめた。一時停止と会議の停止も含む。中央に出して消える。
        case stopped(Target)
        /// 撮れなくなった。中央に出して消える。対象のディスプレイが無ければ、出す場所は呼び出し側が決める。
        case unavailable(Target)
    }

    /// この状態へ移ったときに出す知らせ。
    /// - 撮り直しを待つ状態へ移るとき・その間に「撮らない」や一時停止にしたときは何も出さない
    ///   - 理由: バッジを出していない間に止めた知らせを出すと、再開の手前の一時停止のように同じ知らせが2度並ぶ
    ///   - 替えた先・再開で撮り始めた時点で、撮り始めた知らせを出す
    /// - 撮れなくなった対象を選び直してまた撮れなかったときは出さない。別の対象で撮れなかったときは出す
    public func notice(from previous: ScreenIndicator) -> Notice? {
        switch (previous, self) {
        case let (.on(old), .on(new)): return old == new ? nil : .started(new)
        case let (_, .on(new)): return .started(new)
        case let (.on(old), .hidden): return .stopped(old)
        case let (.failed(old), .failed(new)): return old == new ? nil : .unavailable(new)
        case let (_, .failed(new)): return .unavailable(new)
        default: return nil
        }
    }
}

/// バッジと知らせの寸法と置き場。座標はディスプレイの左下を原点にしたpt。
public enum ScreenIndicatorLayout {
    /// バッジの右下の隅からの間隔。
    public static let badgeInset: CGFloat = 10
    public static let badgeHeight: CGFloat = 20
    public static let noticeHeight: CGFloat = 64

    /// 右下の隅に、幅widthのバッジを置く枠。
    public static func badgeFrame(width: CGFloat, in screen: CGRect) -> CGRect {
        CGRect(x: screen.maxX - badgeInset - width, y: screen.minY + badgeInset, width: width, height: badgeHeight)
    }

    /// 画面の中央に、幅widthの知らせを置く枠。
    public static func noticeFrame(width: CGFloat, in screen: CGRect) -> CGRect {
        CGRect(x: (screen.midX - width / 2).rounded(), y: (screen.midY - noticeHeight / 2).rounded(), width: width, height: noticeHeight)
    }
}
