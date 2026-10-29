// Security scan 2026-10-28, F11: an image with an EXIF/TIFF orientation other than up was drawn whole into a new
// width × height × 4 bitmap before anything checked its size; the engine's 200 MP ceiling ran only after decode returned.
// Scaled here: a 783-byte JPEG whose header claims 2000 × 2000 pixels, against a 1 MP ceiling. Made up, no text.
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ObscuraRender

@Suite struct HostileRasterTests {
    /// A real 16 × 16 grey JPEG with orientation 6 (rotate 90° to display), whose SOF header then claims `width` ×
    /// `height`: ImageIO reports and decodes the claimed size.
    static func lyingJPEG(width: Int, height: Int) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(ctx.makeImage()),
                                   [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        var bytes = [UInt8](out as Data)
        var i = 2
        while i + 9 < bytes.count, bytes[i] == 0xFF {
            let marker = bytes[i + 1], length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            if marker == 0xC0 || marker == 0xC2 {
                bytes[i + 5] = UInt8(height >> 8); bytes[i + 6] = UInt8(height & 0xFF)
                bytes[i + 7] = UInt8(width >> 8); bytes[i + 8] = UInt8(width & 0xFF)
                return Data(bytes)
            }
            i += 2 + length
        }
        Issue.record("no SOF marker")
        return Data(bytes)
    }

    /// What the old decode did with no ceiling of its own: the 783-byte file is decoded and drawn at its claimed size.
    /// Then the same file against a ceiling below that size is refused before any of it is decoded.
    @Test func aClaimedSizePastTheCeilingIsRefusedBeforeDecoding() throws {
        let data = try Self.lyingJPEG(width: 2000, height: 2000)
        #expect(data.count < 1024)
        let unbounded = try ImageCodec.decode(data, maxPixels: .max)
        #expect(unbounded.originalOrientation == .right)
        #expect(unbounded.pixelSize == CGSize(width: 2000, height: 2000), "the old path: a 16 MB bitmap from 783 bytes")

        #expect(throws: ImageCodecError.tooLarge) { try ImageCodec.decode(data, maxPixels: 1_000_000) }
    }

    /// The header is read: an image at the ceiling decodes, one pixel row past it does not.
    @Test func theCeilingIsInclusive() throws {
        let data = try Self.lyingJPEG(width: 1000, height: 1000)
        #expect(try ImageCodec.decode(data, maxPixels: 1_000_000).pixelSize == CGSize(width: 1000, height: 1000))
        #expect(throws: ImageCodecError.tooLarge) { try ImageCodec.decode(data, maxPixels: 999_999) }
    }

    /// The check does not overflow on absurd sides (a header's numbers are anything).
    @Test func thePixelCheckNeverOverflows() {
        #expect(throws: ImageCodecError.tooLarge) { try ImageCodec.checkPixels(Int.max / 2, 3, maxPixels: .max) }
        #expect(throws: Never.self) { try ImageCodec.checkPixels(1 << 20, 1 << 20, maxPixels: .max) }
    }

    /// The default ceiling is the engine's render ceiling.
    @Test func theDefaultCeilingIsTheRenderCeiling() {
        #expect(ImageCodec.maxPixels == 200_000_000)
    }
}
