import Foundation
import CoreFoundation

/// 表示専用の倍率。会議の内容や設定ファイルには持ち込まない。
public struct TranscriptTextScale: Equatable, Sendable {
    public static let percentages = [80, 90, 100, 110, 125, 150, 175, 200]
    public static let actual = Self(percent: 100)
    public let percent: Int
    public var multiplier: Double { Double(percent) / 100 }
    public var canIncrease: Bool { percent < Self.percentages.last! }
    public var canDecrease: Bool { percent > Self.percentages.first! }

    /// 保存値は段階の完全一致だけを受け入れる。近い値へ丸めない。
    public init(percent: Int) {
        self.percent = Self.percentages.contains(percent) ? percent : 100
    }
    public init(savedValue: Any?) {
        guard let number = savedValue as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              Self.percentages.contains(where: { Double($0) == number.doubleValue }) else {
            self = .actual
            return
        }
        self.init(percent: number.intValue)
    }
    public func increased() -> Self { stepped(by: 1) }
    public func decreased() -> Self { stepped(by: -1) }
    private func stepped(by step: Int) -> Self {
        let index = Self.percentages.firstIndex(of: percent)!
        return Self(percent: Self.percentages[min(max(index + step, 0), Self.percentages.count - 1)])
    }
}
