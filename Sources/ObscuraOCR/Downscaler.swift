// Pixel-budget downscale (ARCHITECTURE.md §4 row 5) and the exact scale-back arithmetic.
public import Foundation
import CoreGraphics

/// How OCR input relates to the full-resolution image. `scaleX/scaleY` multiply OCR-space pixels back to full pixels.
public struct DownscalePlan: Sendable, Hashable {
    public let fullSize: CGSize
    public let workSize: CGSize
    public var isIdentity: Bool { fullSize == workSize }
    public var scaleX: CGFloat { fullSize.width / workSize.width }
    public var scaleY: CGFloat { fullSize.height / workSize.height }

    /// Decide whether `width × height` exceeds the budget and what size to shrink to.
    /// Shrinks so the longest side is `maxLongestSide`; if that still exceeds the budget (only possible for
    /// pathological option values) shrinks further by the area ratio. Each side is at least 1 px.
    public init(width: Int, height: Int, options: OCROptions) {
        fullSize = CGSize(width: width, height: height)
        let pixels = width * height
        guard pixels > options.pixelBudget, width > 0, height > 0 else {
            workSize = fullSize
            return
        }
        let longest = Double(max(width, height))
        var factor = Double(options.maxLongestSide) / longest
        let areaFactor = (Double(options.pixelBudget) / Double(pixels)).squareRoot()
        factor = min(factor, areaFactor, 1.0)
        workSize = CGSize(width: max(1, Int((Double(width) * factor).rounded())),
                          height: max(1, Int((Double(height) * factor).rounded())))
    }

    /// Full-resolution rect from an OCR-space rect.
    public func scaledBack(_ rect: CGRect) -> CGRect {
        if isIdentity { return rect }
        return CGRect(x: rect.origin.x * scaleX, y: rect.origin.y * scaleY,
                      width: rect.size.width * scaleX, height: rect.size.height * scaleY)
    }
}

enum Downscaler {
    /// Draws `image` into a bitmap of `plan.workSize` with high-quality interpolation. sRGB, 8-bit premultiplied RGBA.
    static func render(_ image: CGImage, to plan: DownscalePlan) throws(OCRError) -> CGImage {
        if plan.isIdentity { return image }
        let width = Int(plan.workSize.width), height = Int(plan.workSize.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw .badImage }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw .badImage }
        return result
    }
}
