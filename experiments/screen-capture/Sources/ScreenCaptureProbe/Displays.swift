import AppKit
import CoreGraphics
import ScreenCaptureKit

struct DisplayInfo {
    let id: CGDirectDisplayID
    let name: String
    let points: CGSize
    let scale: Double
    /// メニューバーの高さ(pt)。メニューバーが無いディスプレイは0。
    let menuBar: Double
    let isMain: Bool

    static func all() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            return DisplayInfo(id: id, name: screen.localizedName, points: screen.frame.size, scale: screen.backingScaleFactor,
                               menuBar: max(0, screen.frame.maxY - screen.visibleFrame.maxY),
                               isMain: CGDisplayIsMain(id) != 0)
        }
    }

    /// 番号か名前の一部で選ぶ。
    static func find(_ key: String) throws -> DisplayInfo {
        let displays = all()
        if let number = UInt32(key), let hit = displays.first(where: { $0.id == number }) { return hit }
        let hits = displays.filter { $0.name.localizedCaseInsensitiveContains(key) }
        guard hits.count == 1, let hit = hits.first else {
            throw ProbeError.message("ディスプレイ \(key) を1つに決められません: " + displays.map { "\($0.id) \($0.name)" }.joined(separator: ", "))
        }
        return hit
    }
}

/// 設計案の「題の取り方」。前から後ろの順の一覧から、対象ディスプレイに重なる通常レイヤーの最初のウィンドウを採る。
struct FrontWindow {
    let owner: String
    let title: String?
    let pid: pid_t
    let bounds: CGRect
    /// ディスプレイに重なる面積の、ディスプレイに対する割合。
    let coverage: Double

    var label: String {
        guard let title, !title.isEmpty else { return owner }
        return "\(owner)「\(title)」"
    }

    static func candidates(display: CGDirectDisplayID, excludedPIDs: Set<pid_t>) -> [FrontWindow] {
        let screen = CGDisplayBounds(display)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, !excludedPIDs.contains(pid),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let raw = info[kCGWindowBounds as String], let bounds = CGRect(dictionaryRepresentation: raw as! CFDictionary) else { return nil }
            let overlap = bounds.intersection(screen)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return nil }
            return FrontWindow(owner: info[kCGWindowOwnerName as String] as? String ?? "?", title: info[kCGWindowName as String] as? String,
                               pid: pid, bounds: bounds, coverage: overlap.width * overlap.height / (screen.width * screen.height))
        }
    }
}

enum DisplaysCommand {
    static func main() async throws {
        print("画面収録の許可(この実行の帰属先): \(CGPreflightScreenCaptureAccess())")
        for display in DisplayInfo.all() {
            print("\(display.id)\t\(display.name)\t\(Int(display.points.width))x\(Int(display.points.height))pt @\(display.scale)x\tメニューバー \(display.menuBar)pt\(display.isMain ? "\tメイン" : "")")
        }
    }
}

/// 対象ディスプレイの最前面の題を1秒ごとに出す。実際の前後関係と合うかを人が見比べる。
enum WindowsCommand {
    static func main(_ args: inout Arguments) async throws {
        let display = try DisplayInfo.find(try args.required("--display"))
        let seconds = args.int("--seconds") ?? 30
        let excluded = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.tadashi-aikawa.kikigaki").map(\.processIdentifier))
        var previous = ""
        for second in 0..<seconds {
            let candidates = FrontWindow.candidates(display: display.id, excludedPIDs: excluded)
            let line = candidates.prefix(3).map { String(format: "%@ (%.0f%%)", $0.label, $0.coverage * 100) }.joined(separator: " > ")
            if line != previous { print(String(format: "%3d秒 %@ · %@", second, display.name, line.isEmpty ? "(該当なし)" : line)) }
            previous = line
            try await Task.sleep(for: .seconds(1))
        }
    }
}
