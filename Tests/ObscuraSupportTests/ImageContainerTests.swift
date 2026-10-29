// Fail-open #5: ImageIO reports a cut-short file as complete and decodes its top part, so `ImageContainer` walks the
// container itself. Every image here is made up: stripes drawn in code, no text.
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ObscuraSupport

@Suite struct ImageContainerTests {
    static func stripes(_ width: Int, _ height: Int, shade: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(y % 7) / 7, green: shade, blue: CGFloat(y % 3) / 3, alpha: 1))
            ctx.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        return ctx.makeImage()!
    }

    static func encode(_ type: UTType, frames: Int = 1, width: Int = 48, height: Int = 24) throws -> Data {
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, type.identifier as CFString, frames, nil))
        for i in 0..<frames { CGImageDestinationAddImage(destination, stripes(width, height, shade: CGFloat(i + 1) / CGFloat(frames + 1)), nil) }
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }

    /// The defect itself, kept as evidence: ImageIO calls half a PNG complete and decodes it.
    @Test func imageIOCallsATruncatedPNGCompleteWhichIsWhyTheContainerIsWalked() throws {
        let png = try Self.encode(.png, width: 200, height: 120)
        let half = png.prefix(png.count / 2)
        let source = try #require(CGImageSourceCreateWithData(half as CFData, nil))
        #expect(CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete)
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
        #expect(ImageContainer.completeness(of: half) == .truncated)
    }

    /// Every container the capture filter accepts and ImageIO can write: whole is complete, and every shorter prefix
    /// (the file as it is while being written) is truncated.
    @Test(arguments: [UTType.png, .jpeg, .gif, .tiff, .heic, .bmp])
    func everyPrefixOfAWholeFileIsTruncated(_ type: UTType) throws {
        let whole = try Self.encode(type, frames: type == .gif || type == .tiff ? 2 : 1)
        #expect(ImageContainer.completeness(of: whole) == .complete, "\(type.identifier) whole")
        // The signature alone is not enough to tell; from there on every prefix must read as unfinished.
        for length in 12..<whole.count {
            let result = ImageContainer.completeness(of: whole.prefix(length))
            if result != .truncated {
                Issue.record("\(type.identifier) prefix \(length) of \(whole.count) read as \(result)")
                return
            }
        }
    }

    @Test func bytesAfterTheEndDoNotMakeAFileIncomplete() throws {
        for type in [UTType.png, .jpeg, .gif] {
            let whole = try Self.encode(type)
            #expect(ImageContainer.completeness(of: whole + Data(repeating: 0x5A, count: 40)) == .complete, "\(type.identifier)")
        }
    }

    @Test func aWebPIsCompleteOnlyWithAllTheBytesItsHeaderDeclares() {
        // A RIFF header declaring 20 bytes of payload: "WEBP" plus a 16-byte made-up chunk.
        var riff = Data("RIFF".utf8)
        riff.append(contentsOf: [20, 0, 0, 0])
        riff.append(contentsOf: Array("WEBP".utf8))
        riff.append(contentsOf: Array("VP8L".utf8) + [4, 0, 0, 0] + [0x2F, 0, 0, 0] + [0, 0, 0, 0])
        #expect(ImageContainer.completeness(of: riff) == .complete)
        #expect(ImageContainer.completeness(of: riff.prefix(riff.count - 1)) == .truncated)
    }

    @Test func somethingElseIsUnrecognizedNotRefused() {
        #expect(ImageContainer.completeness(of: Data("plain words, not an image".utf8)) == .unrecognized)
        #expect(ImageContainer.completeness(of: Data()) == .unrecognized)
    }

    /// A damaged file is not "unfinished": a PNG signature with garbage after it, or a chunk length one byte off (which
    /// ImageIO still decodes), is malformed, and whether it decodes is left to ImageIO.
    @Test func aDamagedFileIsMalformedNotTruncated() {
        let garbage = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0x41, count: 64)
        #expect(ImageContainer.completeness(of: garbage) == .malformed)
        var gif = Data("GIF89a".utf8) + Data([1, 0, 1, 0, 0, 0, 0])
        gif.append(0x99)                                       // no block starts with 0x99
        #expect(ImageContainer.completeness(of: gif) == .malformed)
    }
}
