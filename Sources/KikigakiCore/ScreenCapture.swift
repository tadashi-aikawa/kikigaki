import Foundation

/// 画面の記録の置き場・ファイル名・見出し・失敗の数え方。AppKitとScreenCaptureKitを持たない部分。
/// 仕様は [画面の記録](docs/screen-capture.md)
public enum ScreenCaptureFiles {
    /// `<会議名>.captures/`。手入力の添付 `<会議名>.attachments/` とは分ける。
    /// 理由: 添付は利用者が貼ったもの、記録は自動で溜まるもの。あとで記録だけを消せるようにする
    public static func directory(for markdownURL: URL) -> URL {
        markdownURL.deletingPathExtension().appendingPathExtension("captures")
    }

    /// `HHmmss.webp`。同じ秒に2枚目以降が来たら `_2`、`_3` と足す。人が開いても時刻が分かる名前にする。
    public static func fileName(observedAt date: Date, taken: (String) -> Bool, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HHmmss"
        let stem = formatter.string(from: date)
        var suffix = 1
        while true {
            let name = stem + (suffix == 1 ? "" : "_\(suffix)") + ".webp"
            if !taken(name) { return name }
            suffix += 1
        }
    }
}

public enum ScreenCaptureLabel {
    /// `EV3895 · Keynote「提案資料」`。題が無ければアプリ名、ウィンドウが無ければディスプレイ名だけ。
    public static func make(display: String, application: String?, title: String?) -> String {
        let display = Utterance.normalizedScreenLabel(display)
        let application = application.map(Utterance.normalizedScreenLabel).flatMap { $0.isEmpty ? nil : $0 }
        let title = title.map(Utterance.normalizedScreenLabel).flatMap { $0.isEmpty ? nil : $0 }
        guard let application else { return display.isEmpty ? "画面" : display }
        let window = title.map { "\(application)「\($0)」" } ?? application
        return display.isEmpty ? window : "\(display) · \(window)"
    }
}

/// 保存の失敗を数え、ヘッダーへ出す1行を決める。1枚の失敗では出さず、3回続いたら出す。次に1枚保存できたら消す。
/// 撮れなくなった理由(許可・ディスプレイの消失)は、保存の失敗より優先して出し続ける。
public struct ScreenCaptureHealth: Equatable, Sendable {
    public static let failureLimit = 3
    public private(set) var consecutiveFailures = 0
    public private(set) var lastFailure: String?
    public private(set) var unavailable: String?

    public init() {}

    public mutating func saved() { consecutiveFailures = 0; lastFailure = nil }
    public mutating func failed(_ reason: String) { consecutiveFailures += 1; lastFailure = reason }
    public mutating func becameUnavailable(_ reason: String) { unavailable = reason }

    public var warning: String? {
        if let unavailable { return "画面を記録できません: \(unavailable)" }
        guard consecutiveFailures >= Self.failureLimit, let lastFailure else { return nil }
        return "画面を記録できません: \(lastFailure)"
    }
}

/// 観測した瞬間の音声位置。受け付けた音声の位置から、観測からの経過を引いて求める。
/// 一時停止の間は撮らないので、受け付けた位置より後ろにも、0より前にもしない。
public enum ScreenCaptureClock {
    public static func audioTime(acceptedAudioTime: Double, now: Date, observedAt: Date) -> Double {
        let elapsed = max(0, now.timeIntervalSince(observedAt))
        return min(acceptedAudioTime, max(0, acceptedAudioTime - elapsed))
    }
}
