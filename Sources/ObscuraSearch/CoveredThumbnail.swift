// ObscuraSearch — the Spotlight thumbnail: a small PNG of the covered file on disk, never of an original.
public import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum CoveredThumbnail {
    /// A PNG at most `maxPixel` on its longest side, read from the covered file; nil when it does not decode.
    public static func data(of coveredFile: URL, maxPixel: Int = 320) -> Data? {
        guard let source = CGImageSourceCreateWithURL(coveredFile as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
