import CoreGraphics

/// An RGBA8 (premultiplied-last, sRGB) copy of a `CGImage` or a crop of it, filled by *drawing* the
/// image into a context we own. The source's byte layout, colour space and alpha info are never trusted.
/// Row 0 is the top row (top-left origin), matching finding coordinates.
struct PixelBuffer {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    /// `crop` is in image pixels, top-left origin; nil means the whole image.
    init?(image: CGImage, crop: CGRect? = nil) {
        let source: CGImage
        if let crop {
            let integral = crop.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !integral.isNull, integral.width >= 1, integral.height >= 1,
                  let cropped = image.cropping(to: integral) else { return nil }
            source = cropped
        } else {
            source = image
        }
        let w = source.width, h = source.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: Self.colorSpace, bitmapInfo: Self.bitmapInfo) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let count = ctx.bytesPerRow * h
        var copy = [UInt8](repeating: 0, count: w * h * 4)
        let raw = data.assumingMemoryBound(to: UInt8.self)
        if ctx.bytesPerRow == w * 4 {
            copy.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: raw, count: count) }
        } else {
            for y in 0..<h {
                for i in 0..<(w * 4) { copy[y * w * 4 + i] = raw[y * ctx.bytesPerRow + i] }
            }
        }
        width = w; height = h; bytes = copy
    }

    @inline(__always) func offset(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }

    func rgba(_ x: Int, _ y: Int) -> RGBA {
        let o = offset(x, y)
        return RGBA(r: Double(bytes[o]) / 255, g: Double(bytes[o + 1]) / 255,
                    b: Double(bytes[o + 2]) / 255, a: Double(bytes[o + 3]) / 255)
    }

    /// Per-channel 0…255 values, `[r, g, b, a]`.
    func channels(_ x: Int, _ y: Int) -> [UInt8] {
        let o = offset(x, y)
        return [bytes[o], bytes[o + 1], bytes[o + 2], bytes[o + 3]]
    }
}
