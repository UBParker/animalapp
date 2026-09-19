import UIKit

/// Pure functions over image bytes. Orientation is baked in by UIGraphicsImageRenderer.
enum ImageProcessing {
    static func pixelSize(of data: Data) -> CGSize? {
        guard let image = UIImage(data: data) else { return nil }
        return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    static func downscaledJPEG(_ data: Data, maxSide: CGFloat = 2048, quality: CGFloat = 0.85) -> Data? {
        resizedJPEG(data, maxSide: maxSide, quality: quality)
    }

    static func thumbnailJPEG(_ data: Data, side: CGFloat = 300) -> Data? {
        resizedJPEG(data, maxSide: side, quality: 0.8)
    }

    private static func resizedJPEG(_ data: Data, maxSide: CGFloat, quality: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > 0 else { return nil }
        let scale = min(1, maxSide / longest)
        let target = CGSize(width: (pixelWidth * scale).rounded(), height: (pixelHeight * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: quality)
    }
}
