import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

extension NSImage {
    /// 直接从磁盘 URL 解码出降采样缩略图（最长边 <= maxPixel）。
    /// 用 ImageIO 的 CGImageSourceCreateThumbnailAtIndex 直接解到目标尺寸，
    /// 不把整张原图解码进内存再缩 —— 峰值内存与 CPU 都更低。
    /// 尤其 P1-A 之后磁盘上存的是全分辨率原图（为粘贴保真），load 回来时必须避免整图解码。
    static func pasteletThumbnail(contentsOf url: URL, maxPixel: CGFloat = 512) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// 生成用于卡片显示的降采样缩略图（最长边 <= maxPixel）。
    /// 卡片只有 ~232pt，没必要在内存里常驻全分辨率位图（4K 截图可达数十 MB）。
    /// 原图始终完整保存在磁盘，粘贴时再按需加载，保真度不受影响。
    func pasteletThumbnail(maxPixel: CGFloat = 512) -> NSImage {
        let width = size.width
        let height = size.height
        guard width > 0, height > 0 else { return self }

        let longest = max(width, height)
        guard longest > maxPixel else { return self } // 本来就小，直接用

        let scale = maxPixel / longest
        let target = NSSize(width: floor(width * scale), height: floor(height * scale))

        let thumbnail = NSImage(size: target)
        thumbnail.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        thumbnail.unlockFocus()
        return thumbnail
    }

    /// 后台线程用：从原始图片字节一次解出「缩略图 PNG 字节 + 原图像素尺寸」。
    /// 全程 ImageIO（线程安全、子采样解码，不整图解码），产物都是 Sendable 的值类型，
    /// 可安全送回主线程再构建 NSImage —— Swift 6 下 NSImage 本身不能跨 actor 传递。
    static func pasteletThumbnailPNGAndPixelSize(
        data: Data,
        maxPixel: CGFloat = 512
    ) -> (thumbnailPNG: Data, pixelWidth: Int, pixelHeight: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? cg.width
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? cg.height
        return (output as Data, width, height)
    }

    /// 只读图片头信息取像素尺寸，不解码位图
    static func pasteletPixelSize(contentsOf url: URL) -> (width: Int, height: Int)? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}

extension Data {
    /// 稳定的内容指纹（跨进程一致），用于图片去重与文件名生成。
    var pasteletContentHash: String {
        let digest = SHA256.hash(data: self)
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
