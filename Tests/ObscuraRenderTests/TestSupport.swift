import CoreGraphics
import Foundation
import Testing
@testable import ObscuraRender

/// Shared helpers. Images are drawn in TOP-LEFT coordinates (the helper flips the context) so test
/// rects read like finding rects.
enum TestImages {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    static func make(width: Int, height: Int, _ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setAllowsAntialiasing(false)
        draw(ctx)
        return ctx.makeImage()!
    }

    static func flat(_ color: RGBA, width: Int = 120, height: Int = 60) -> CGImage {
        make(width: width, height: height) { ctx in
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// A light page with dark text-like bars and a vertical gradient band on the right.
    static func page(width: Int = 320, height: Int = 160) -> CGImage {
        make(width: width, height: height) { ctx in
            ctx.setFillColor(RGBA(r: 0.96, g: 0.96, b: 0.97).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // gradient band, drawn row by row so it is exact
            for y in 0..<height {
                let t = Double(y) / Double(height - 1)
                ctx.setFillColor(RGBA(r: 0.15 + 0.6 * t, g: 0.25 + 0.4 * t, b: 0.7 - 0.5 * t).cgColor)
                ctx.fill(CGRect(x: 220, y: y, width: 100, height: 1))
            }
            ctx.setFillColor(RGBA(r: 0.1, g: 0.1, b: 0.12).cgColor)
            for (i, w) in [160, 120, 190, 90].enumerated() {
                let y = 20 + i * 30
                var x = 16
                while x < 16 + w { ctx.fill(CGRect(x: x, y: y + 3, width: 9, height: 8)); x += 12 }
            }
        }
    }

    static func pixels(_ image: CGImage) -> PixelBuffer { PixelBuffer(image: image)! }

    static func isMagentaish(_ c: [UInt8]) -> Bool { c[0] > 200 && c[1] < 50 && c[2] > 200 }

    /// Number of pixels whose rows/cols are outside `rect` and differ between the two images in any channel.
    static func differingPixels(_ a: PixelBuffer, _ b: PixelBuffer, outside rect: CGRect? = nil, inside: CGRect? = nil, tolerance: Int = 0) -> Int {
        precondition(a.width == b.width && a.height == b.height)
        var n = 0
        for y in 0..<a.height {
            for x in 0..<a.width {
                let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                if let rect, rect.contains(p) { continue }
                if let inside, !inside.contains(p) { continue }
                let ca = a.channels(x, y), cb = b.channels(x, y)
                if zip(ca, cb).contains(where: { abs(Int($0) - Int($1)) > tolerance }) { n += 1 }
            }
        }
        return n
    }

    static let env = RenderEnvironment(redactedWord: "REDACTED")
}
