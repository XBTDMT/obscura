public import CoreGraphics
public import Foundation
public import ImageIO
public import UniformTypeIdentifiers
import ObscuraSupport

public enum ImageCodecError: Error, Sendable, Equatable {
    case notAnImage
    case unsupportedContainer
    /// The container stops before it says it ends (`ImageContainer.completeness`): a file still being written or cut
    /// short. Never decoded, so a part-written picture is never judged on its top part (fail-open #5).
    case incomplete
    /// An image (or a PDF page at `pdfScale`) with more pixels than the decode's ceiling (`ImageCodec.maxPixels` by
    /// default), refused before it is decoded.
    case tooLarge
    case encodeFailed
}

/// A decoded image with its orientation already applied (`image` is `.up`) and the metadata we re-attach on write.
public struct DecodedImage {
    public var image: CGImage
    public var uti: UTType
    public var dpi: CGSize?
    public var originalOrientation: CGImagePropertyOrientation
    /// Size after orientation, in pixels.
    public var pixelSize: CGSize
    /// How many images the container holds (GIF and APNG frames, TIFF pages, an HEIF sequence); `image` is one of them.
    public var frameCount: Int

    public init(image: CGImage, uti: UTType, dpi: CGSize?, originalOrientation: CGImagePropertyOrientation, pixelSize: CGSize,
                frameCount: Int = 1) {
        self.image = image
        self.uti = uti
        self.dpi = dpi
        self.originalOrientation = originalOrientation
        self.pixelSize = pixelSize
        self.frameCount = frameCount
    }
}

public enum ImageCodec {
    /// Containers we accept on the way in (matches the capture filter's extension list).
    public static let supportedInput: [UTType] = [.png, .jpeg, .heic, .heif, .tiff, .gif, .bmp, .webP]
    public static let defaultLossyQuality = 0.92

    /// Decodes one image of the container (`frame`, 0 for the first) with its orientation applied. `frameCount` says how
    /// many there are, so a caller never takes the first frame for the whole picture (fail-open #6). An image with more
    /// than `maxPixels` pixels is `tooLarge`, judged from its header before a pixel is decoded (security scan F11).
    public static func decode(_ data: Data, frame: Int = 0, maxPixels: Int = ImageCodec.maxPixels) throws -> DecodedImage {
        if data.starts(with: pdfSignature) { return try decodePDF(data, page: frame, maxPixels: maxPixels) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) >= 1,
              let typeID = CGImageSourceGetType(source),
              let uti = UTType(typeID as String) else { throw ImageCodecError.notAnImage }
        guard supportedInput.contains(where: { uti.conforms(to: $0) }) else { throw ImageCodecError.unsupportedContainer }
        // ImageIO's own status says "complete" for truncated data (it decodes what is there), so the container is walked.
        guard ImageContainer.completeness(of: data) != .truncated else { throw ImageCodecError.incomplete }
        let frames = CGImageSourceGetCount(source)
        guard frame >= 0, frame < frames else { throw ImageCodecError.notAnImage }
        // The size is the file's own claim: checked from the header first, so a small file declaring a huge picture is
        // never decoded (an oriented image is drawn whole into a new bitmap below), then from the image itself.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [CFString: Any] ?? [:]
        if let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
            try checkPixels(width, height, maxPixels: maxPixels)
        }
        guard let raw = CGImageSourceCreateImageAtIndex(source, frame, nil) else { throw ImageCodecError.notAnImage }
        try checkPixels(raw.width, raw.height, maxPixels: maxPixels)

        var orientation = CGImagePropertyOrientation.up
        if let value = properties[kCGImagePropertyOrientation] as? UInt32, let o = CGImagePropertyOrientation(rawValue: value) {
            orientation = o
        }
        var dpi: CGSize? = nil
        if let w = properties[kCGImagePropertyDPIWidth] as? Double, let h = properties[kCGImagePropertyDPIHeight] as? Double, w > 0, h > 0 {
            dpi = CGSize(width: w, height: h)
        }
        let image = try oriented(raw, orientation)
        return DecodedImage(image: image, uti: uti, dpi: dpi, originalOrientation: orientation,
                            pixelSize: CGSize(width: image.width, height: image.height), frameCount: frames)
    }

    static let pdfSignature = Array("%PDF-".utf8)
    /// PDF pages are drawn at twice their point size (144 dpi): text at the size a Retina screen showed it, which is what
    /// the OCR budget is tuned for.
    public static let pdfScale: CGFloat = 2
    /// The default decode ceiling: an image, or a PDF page at `pdfScale`, with more pixels than this is refused as too
    /// large rather than decoded (or drawn smaller: text drawn too small to read would be judged clean). The engine's
    /// render ceiling (`InputLimits.maxPixels`).
    public static let maxPixels = InputLimits.maxPixels
    /// The longest side, in pixels, a PDF page is drawn at; past it a page is too large whatever its other side.
    static let pdfMaxSide = CGFloat(1 << 20)

    /// A PDF (ImageIO identifies PDF but returns no image for it): each page drawn on white at `pdfScale`, its rotation
    /// applied. `frameCount` is the page count, so a document's later pages are read too (fail-open #6, #9).
    static func decodePDF(_ data: Data, page index: Int, maxPixels: Int = ImageCodec.maxPixels) throws -> DecodedImage {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              document.numberOfPages >= 1 else { throw ImageCodecError.notAnImage }
        let pages = document.numberOfPages
        guard index >= 0, index < pages, let page = document.page(at: index + 1) else { throw ImageCodecError.notAnImage }
        let box = page.getBoxRect(.cropBox)
        let turned = page.rotationAngle % 180 != 0
        let size = turned ? CGSize(width: box.height, height: box.width) : box.size
        // The box is the document's own numbers (CoreGraphics does not clamp them: a MediaBox of 9e18 points comes back
        // as 9e18), and Int(Double) traps past Int.max or on a value that is not finite. So every side is range-checked
        // as a CGFloat first and only a side known to fit becomes an Int (security scan F10).
        let scaled = CGSize(width: (size.width * pdfScale).rounded(.up), height: (size.height * pdfScale).rounded(.up))
        guard !scaled.width.isNaN, !scaled.height.isNaN, scaled.width > 0, scaled.height > 0 else { throw ImageCodecError.notAnImage }
        guard scaled.width <= pdfMaxSide, scaled.height <= pdfMaxSide else { throw ImageCodecError.tooLarge }
        let width = Int(scaled.width), height = Int(scaled.height)
        guard width * height <= maxPixels else { throw ImageCodecError.tooLarge }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageCodecError.notAnImage }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: pdfScale, y: pdfScale)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage() else { throw ImageCodecError.notAnImage }
        return DecodedImage(image: image, uti: .pdf, dpi: CGSize(width: 72 * pdfScale, height: 72 * pdfScale), originalOrientation: .up,
                            pixelSize: CGSize(width: width, height: height), frameCount: pages)
    }

    /// `tooLarge` when `width` × `height` passes `maxPixels` (or overflows).
    static func checkPixels(_ width: Int, _ height: Int, maxPixels: Int) throws(ImageCodecError) {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maxPixels else { throw .tooLarge }
    }

    /// PNG, JPEG and HEIC keep their container; everything else is written as PNG. The result is
    /// orientation `.up` (pixels are already rotated) with the DPI re-attached.
    public static func encode(_ image: CGImage, as uti: UTType, dpi: CGSize?, quality: Double?) throws -> Data {
        let target: UTType
        if uti.conforms(to: .jpeg) { target = .jpeg } else if uti.conforms(to: .heic) { target = .heic } else { target = .png }

        var properties: [CFString: Any] = [kCGImagePropertyOrientation: CGImagePropertyOrientation.up.rawValue]
        if let dpi {
            properties[kCGImagePropertyDPIWidth] = dpi.width
            properties[kCGImagePropertyDPIHeight] = dpi.height
        }
        if target != .png {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(quality ?? defaultLossyQuality, 0), 1)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, target.identifier as CFString, 1, nil) else {
            throw ImageCodecError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { throw ImageCodecError.encodeFailed }
        return output as Data
    }

    /// Returns a copy of `image` rotated/mirrored so that it displays correctly with orientation `.up`.
    public static func oriented(_ image: CGImage, _ orientation: CGImagePropertyOrientation) throws -> CGImage {
        guard orientation != .up else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let swaps = [.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
        let outW = swaps ? image.height : image.width, outH = swaps ? image.width : image.height
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageCodecError.notAnImage
        }
        ctx.interpolationQuality = .none
        // Context is bottom-left origin. Rotations are expressed for that frame; mirrored variants
        // flip the stored image horizontally before the rotation (EXIF 2, 4, 5, 7).
        switch orientation {
        case .up: break
        case .upMirrored: ctx.translateBy(x: w, y: 0); ctx.scaleBy(x: -1, y: 1)
        case .down: ctx.translateBy(x: w, y: h); ctx.rotate(by: .pi)
        case .downMirrored: ctx.translateBy(x: 0, y: h); ctx.scaleBy(x: 1, y: -1)
        case .right: ctx.translateBy(x: 0, y: w); ctx.rotate(by: -.pi / 2)                   // 90° CW
        case .left: ctx.translateBy(x: h, y: 0); ctx.rotate(by: .pi / 2)                     // 90° CCW
        case .rightMirrored: ctx.translateBy(x: h, y: 0); ctx.rotate(by: .pi / 2); ctx.translateBy(x: w, y: 0); ctx.scaleBy(x: -1, y: 1)
        case .leftMirrored: ctx.translateBy(x: 0, y: w); ctx.rotate(by: -.pi / 2); ctx.translateBy(x: w, y: 0); ctx.scaleBy(x: -1, y: 1)
        @unknown default: break
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw ImageCodecError.notAnImage }
        return out
    }
}
