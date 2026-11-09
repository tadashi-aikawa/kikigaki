import CoreGraphics
import Foundation

enum Thumbnail {
    /// 記録に残す縮小画像の幅。スイープではここから小さい幅へ平均で縮める。
    static let recordWidth = 256

    static func height(forWidth width: Int, imageWidth: Int, imageHeight: Int) -> Int {
        max(1, Int((Double(width) * Double(imageHeight) / Double(imageWidth)).rounded()))
    }

    /// 画像を等倍の輝度へ描いてから、マスごとの単純平均で縮める。補間の癖に判定を左右させない。
    static func make(_ image: CGImage, width: Int) -> Thumb? {
        let w = image.width, h = image.height
        var gray = [UInt8](repeating: 0, count: w * h)
        let drawn: Bool = gray.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        return boxAverage(gray, width: w, height: h, to: width)
    }

    static func resized(_ thumb: Thumb, width: Int) -> Thumb {
        width == thumb.width ? thumb : boxAverage(thumb.luma, width: thumb.width, height: thumb.height, to: width)
    }

    static func boxAverage(_ source: [UInt8], width w: Int, height h: Int, to tw: Int) -> Thumb {
        let th = height(forWidth: tw, imageWidth: w, imageHeight: h)
        var sums = [Int](repeating: 0, count: tw * th)
        var counts = [Int](repeating: 0, count: tw * th)
        let xmap = (0..<w).map { $0 * tw / w }
        source.withUnsafeBufferPointer { pixels in
            for y in 0..<h {
                let rowBase = (y * th / h) * tw
                let offset = y * w
                for x in 0..<w {
                    sums[rowBase + xmap[x]] += Int(pixels[offset + x])
                    counts[rowBase + xmap[x]] += 1
                }
            }
        }
        var luma = [UInt8](repeating: 0, count: tw * th)
        for cell in luma.indices where counts[cell] > 0 {
            let total: Int = sums[cell] + counts[cell] / 2
            luma[cell] = UInt8(total / counts[cell])
        }
        return Thumb(width: tw, height: th, luma: luma)
    }
}
