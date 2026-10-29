import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ObscuraRender

@Suite struct ImageCodecTests {
    @Test func pngRoundTripKeepsPixelsAndDPI() throws {
        let image = TestImages.page()
        let data = try ImageCodec.encode(image, as: .png, dpi: CGSize(width: 144, height: 144), quality: nil)
        let decoded = try ImageCodec.decode(data)
        #expect(decoded.uti == .png)
        #expect(decoded.dpi == CGSize(width: 144, height: 144))
        #expect(decoded.originalOrientation == .up)
        #expect(decoded.pixelSize == CGSize(width: 320, height: 160))
        #expect(TestImages.differingPixels(TestImages.pixels(image), TestImages.pixels(decoded.image)) == 0)
    }

    @Test func jpegHonoursQuality() throws {
        let image = TestImages.page()
        let hi = try ImageCodec.encode(image, as: .jpeg, dpi: nil, quality: 0.95)
        let lo = try ImageCodec.encode(image, as: .jpeg, dpi: nil, quality: 0.3)
        #expect(hi.count > lo.count)
        #expect(try ImageCodec.decode(hi).uti == .jpeg)
        let p = TestImages.pixels(try ImageCodec.decode(hi).image)
        #expect(TestImages.differingPixels(TestImages.pixels(image), p, tolerance: 24) < 320 * 160 / 20)
    }

    @Test func heicRoundTrip() throws {
        let image = TestImages.page()
        let data = try ImageCodec.encode(image, as: .heic, dpi: CGSize(width: 72, height: 72), quality: nil)
        let decoded = try ImageCodec.decode(data)
        #expect(decoded.uti == .heic)
        #expect(decoded.pixelSize == CGSize(width: 320, height: 160))
    }

    @Test func unknownContainersBecomePNG() throws {
        let data = try ImageCodec.encode(TestImages.flat(RGBA(r: 1, g: 0, b: 0)), as: .gif, dpi: nil, quality: nil)
        #expect(try ImageCodec.decode(data).uti == .png)
    }

    @Test func orientationSixIsAppliedAndOutputIsUp() throws {
        // 4×2 stored image, red at the stored top-left.
        let stored = TestImages.make(width: 4, height: 2) { ctx in
            ctx.setFillColor(RGBA(r: 1, g: 1, b: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
            ctx.setFillColor(RGBA(r: 1, g: 0, b: 0).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, stored, [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))

        let decoded = try ImageCodec.decode(out as Data)
        #expect(decoded.originalOrientation == .right)
        #expect(decoded.pixelSize == CGSize(width: 2, height: 4))
        let p = TestImages.pixels(decoded.image)
        #expect(p.channels(1, 0)[0] == 255 && p.channels(1, 0)[1] == 0) // red moved to the top-right
        #expect(p.channels(0, 0)[1] == 255)                              // top-left is white

        let reencoded = try ImageCodec.decode(try ImageCodec.encode(decoded.image, as: decoded.uti, dpi: decoded.dpi, quality: nil))
        #expect(reencoded.originalOrientation == .up)
        #expect(reencoded.pixelSize == CGSize(width: 2, height: 4))
    }

    @Test func errors() {
        #expect(throws: ImageCodecError.notAnImage) { try ImageCodec.decode(Data("not an image".utf8)) }
        #expect(throws: ImageCodecError.notAnImage) { try ImageCodec.decode(Data()) }
    }

    /// Fail-open #5: a file cut short (still being written) is refused, never decoded from its top part. ImageIO alone
    /// would decode both of these.
    @Test(arguments: [UTType.png, .jpeg])
    func aTruncatedFileIsRefusedAsIncomplete(_ type: UTType) throws {
        let ctx = CGContext(data: nil, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<90 {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(y % 5) / 5, green: 0.4, blue: CGFloat(y % 3) / 3, alpha: 1))
            ctx.fill(CGRect(x: 0, y: y, width: 160, height: 1))
        }
        let whole = try ImageCodec.encode(ctx.makeImage()!, as: type, dpi: nil, quality: nil)
        #expect(try ImageCodec.decode(whole).pixelSize == CGSize(width: 160, height: 90))
        for fraction in [0.25, 0.5, 0.9] {
            let cut = whole.prefix(Int(Double(whole.count) * fraction))
            #expect(throws: ImageCodecError.incomplete, "\(type.identifier) at \(fraction)") { try ImageCodec.decode(cut) }
        }
    }
}
