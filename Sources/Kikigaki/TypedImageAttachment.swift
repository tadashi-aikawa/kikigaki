import AppKit
import ImageIO
import KikigakiCore
import UniformTypeIdentifiers

/// 下書きはメモリに保持し、投稿が受理されるときだけ会議の隣へ保存する。
struct TypedImageDraft {
    static let maxBytes = 10 * 1024 * 1024
    let data: Data
    let fileExtension: String
    let preview: NSImage

    enum ImportError: LocalizedError {
        case tooLarge, unsupported, tooManyPixels
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "画像は1枚10MiBまでです"
            case .unsupported: return "読み込める画像を貼り付けてください"
            case .tooManyPixels: return "画像は4,000万画素までです"
            }
        }
    }

    init(data: Data) throws {
        guard data.count <= Self.maxBytes else { throw ImportError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              let format = UTType(type as String), format.conforms(to: .image),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ImportError.unsupported }
        // 圧縮後のバイト上限だけでは巨大TIFF等の展開メモリを制限できない。
        guard width <= 40_000_000 / height else { throw ImportError.tooManyPixels }
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw ImportError.unsupported }
        // クリップボードのTIFF等もAIが読めるPNGへ揃える。JPEG/PNGは原本を保つ。
        if format == .png || format == .jpeg {
            self.data = data
            fileExtension = format == .png ? "png" : "jpg"
        } else {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ImportError.unsupported }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
                throw ImportError.unsupported
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ImportError.unsupported }
            guard output.length <= Self.maxBytes else { throw ImportError.tooLarge }
            self.data = output as Data
            fileExtension = "png"
        }
        preview = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
    }

    /// nilは画像のない通常のテキスト貼り付け。画像があれば文字列の付随データは使わない。
    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.types?.contains { UTType($0.rawValue)?.conforms(to: .image) == true } == true
            || !imageFileURLs(from: pasteboard).isEmpty
    }

    private static func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter {
            (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) == true
        }
    }

    static func read(from pasteboard: NSPasteboard) throws -> [Self]? {
        let urls = imageFileURLs(from: pasteboard)
        if !urls.isEmpty {
            return try urls.map { url in
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, let size = values.fileSize else { throw ImportError.unsupported }
                guard size <= maxBytes else { throw ImportError.tooLarge }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                return try Self(data: file.read(upToCount: maxBytes + 1) ?? Data())
            }
        }
        var images: [Self] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let preferred: [NSPasteboard.PasteboardType] = [.png, .init(UTType.jpeg.identifier), .tiff]
            for type in preferred + item.types where UTType(type.rawValue)?.conforms(to: .image) == true {
                if let data = item.data(forType: type) {
                    images.append(try Self(data: data))
                    break
                }
            }
        }
        return images.isEmpty ? nil : images
    }

    static func save(_ images: [Self], beside markdownURL: URL) throws -> [String] {
        guard !images.isEmpty else { return [] }
        let directory = markdownURL.deletingPathExtension().appendingPathExtension("attachments")
        try PrivateFileIO.createDirectory(at: directory)
        var saved: [URL] = []
        do {
            for image in images {
                let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(image.fileExtension)
                try PrivateFileIO.write(image.data, to: url, replacing: false)
                saved.append(url)
            }
            return saved.map(\.path)
        } catch {
            // この投稿で作成できたファイルだけ戻し、下書きは呼び出し元に残す。
            // 会議ごとの共有ディレクトリは残す。空でも次回保存を妨げず、別投稿を巻き込まない。
            for url in saved { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    static func preview(at path: String) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

/// 下書きと投稿済みで同じ番号を表示する。多数の画像でも横スクロールで収める。
final class TypedImageStrip: NSScrollView {
    private let cards = NSView()
    private var actions: [() -> Void] = []
    var onRemove: ((Int) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        autohidesScrollers = true
        documentView = cards
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(previews: [NSImage?], paths: [String] = [], removable: Bool = false) {
        cards.subviews.forEach { $0.removeFromSuperview() }
        actions = []
        isHidden = previews.isEmpty
        cards.frame = NSRect(x: 0, y: 0, width: CGFloat(previews.count) * 100, height: 82)
        for (index, preview) in previews.enumerated() {
            let button = NSButton(frame: NSRect(x: CGFloat(index) * 100, y: 18, width: 90, height: 62))
            button.image = preview ?? NSImage(systemSymbolName: "photo", accessibilityDescription: "画像を読み込めません")
            button.imageScaling = .scaleProportionallyUpOrDown
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.tag = index
            button.target = self
            button.action = #selector(openImage(_:))
            button.isEnabled = paths.indices.contains(index) && preview != nil
            button.setAccessibilityLabel("画像\(index + 1)")
            button.toolTip = preview == nil ? "画像\(index + 1)を読み込めません"
                : paths.indices.contains(index) ? "画像\(index + 1)を開く" : "画像\(index + 1)"
            cards.addSubview(button)
            actions.append({ if paths.indices.contains(index) { NSWorkspace.shared.open(URL(fileURLWithPath: paths[index])) } })
            let label = NSTextField(labelWithString: "画像\(index + 1)")
            label.font = .systemFont(ofSize: 11)
            label.textColor = Washi.muted
            label.frame = NSRect(x: CGFloat(index) * 100 + 4, y: 0, width: 65, height: 16)
            cards.addSubview(label)
            if removable {
                let remove = NSButton(title: "×", target: self, action: #selector(removeImage(_:)))
                remove.tag = index
                remove.frame = NSRect(x: CGFloat(index) * 100 + 65, y: 0, width: 25, height: 18)
                remove.isBordered = false
                remove.setAccessibilityLabel("画像\(index + 1)を取り外す")
                cards.addSubview(remove)
            }
        }
    }
    @objc private func openImage(_ sender: NSButton) { actions[sender.tag]() }
    @objc private func removeImage(_ sender: NSButton) { onRemove?(sender.tag) }
}
