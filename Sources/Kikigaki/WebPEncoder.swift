import CoreGraphics
import Foundation
import libwebp

/// 画面の記録の非可逆WebP。UTSUSHIEの `WebPEncoder` を非可逆だけに絞って移植した。
/// WebPはICCを自動保存しないためsRGBへ変換する。CGContextはpremultiplied RGBAなので、libwebpへ渡す前にalphaを外す。
enum WebPEncoder {
    enum Failure: LocalizedError {
        case bitmap, encoding
        var errorDescription: String? {
            switch self {
            case .bitmap: return "画像のピクセル変換に失敗しました"
            case .encoding: return "WebPへの変換に失敗しました"
            }
        }
    }

    /// 品質80。文字が読めて1枚が数百KBに収まる値。根拠: docs/records/screen-capture-spike.md
    static let quality = 80.0

    static func encode(_ image: CGImage, quality: Double = quality) throws -> Data {
        let width = image.width, height = image.height, row = width * 4
        var pixels = [UInt8](repeating: 0, count: row * height)
        return try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: row,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw Failure.bitmap }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let rgba = buffer.bindMemory(to: UInt8.self)
            for index in stride(from: 0, to: rgba.count, by: 4) {
                let alpha = Int(rgba[index + 3])
                if alpha > 0 && alpha < 255 {
                    for component in 0..<3 { rgba[index + component] = UInt8(min(255, (Int(rgba[index + component]) * 255 + alpha / 2) / alpha)) }
                }
            }
            var output: UnsafeMutablePointer<UInt8>?
            let size = WebPEncodeRGBA(rgba.baseAddress, Int32(width), Int32(height), Int32(row), Float(quality), &output)
            guard size > 0, let output else { throw Failure.encoding }
            defer { WebPFree(output) }
            return Data(bytes: output, count: size)
        }
    }
}
