import AppKit
import ScreenCaptureKit

/// 画面収録の許可の挙動を記録する。`.app` を `open` で起動して使う。標準出力は見えないので `permission.log` へ書く。
/// - 起動時の確認結果と、未許可なら要求した結果
/// - 許可されるまで1秒ごとに確認とSCShareableContentの取得を試し、同じプロセスのまま使えるようになるか
/// - 使えたら対象ディスプレイを1枚撮って `check.webp` に残す
enum PermissionCommand {
    static func main(_ args: inout Arguments) async throws {
        let out = URL(fileURLWithPath: try args.required("--out"))
        let wait = args.int("--wait") ?? 120
        let key = args.string("--display")
        guard !FileManager.default.fileExists(atPath: out.path) else { throw ProbeError.message("出力先が既にある: \(out.path)") }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var lines: [String] = []
        let started = Date()
        func log(_ text: String) {
            let line = String(format: "%6.1f秒 ", Date().timeIntervalSince(started)) + text
            lines.append(line)
            print(line)
            try? lines.joined(separator: "\n").appending("\n").write(to: out.appendingPathComponent("permission.log"), atomically: true, encoding: .utf8)
        }
        let bundle = Bundle.main
        log("bundle=\(bundle.bundleIdentifier ?? "(なし)") path=\(bundle.bundlePath)")
        log("NSScreenCaptureUsageDescription=\(bundle.object(forInfoDictionaryKey: "NSScreenCaptureUsageDescription") as? String ?? "(なし)")")
        let initial = CGPreflightScreenCaptureAccess()
        log("起動時のCGPreflightScreenCaptureAccess=\(initial)")
        if !initial { log("CGRequestScreenCaptureAccess=\(CGRequestScreenCaptureAccess())") }
        var content: SCShareableContent?
        for second in 0...wait {
            let preflight = CGPreflightScreenCaptureAccess()
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                log("\(second)秒目: preflight=\(preflight) SCShareableContent=成功 displays=\(content!.displays.count) windows=\(content!.windows.count)")
                break
            } catch {
                if second % 5 == 0 { log("\(second)秒目: preflight=\(preflight) SCShareableContent=失敗 \(error.localizedDescription)") }
            }
            try await Task.sleep(for: .seconds(1))
        }
        guard let content else { log("時間切れ。このプロセスでは撮れなかった"); return }
        let display = try key.map(DisplayInfo.find) ?? DisplayInfo.all().first(where: \.isMain)!
        guard let target = content.displays.first(where: { $0.displayID == display.id }) else { log("ディスプレイが無い"); return }
        let config = SCStreamConfiguration()
        config.width = Int(display.points.width); config.height = Int(display.points.height)
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: target, excludingWindows: []), configuration: config)
            try WebPEncoder.encode(image, quality: 80).write(to: out.appendingPathComponent("check.webp"))
            let windows = FrontWindow.candidates(display: display.id, excludedPIDs: [])
            log("撮影=成功 \(image.width)x\(image.height) 題の取得=\(windows.first.map { $0.title == nil ? "題なし(\($0.owner))" : "あり" } ?? "該当なし")")
        } catch {
            log("撮影=失敗 \(error.localizedDescription)")
        }
    }
}
