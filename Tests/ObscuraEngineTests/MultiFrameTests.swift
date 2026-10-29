// Fail-open #6: a picture with several frames used to be judged on frame 0 alone, so a secret on frame 2 of a GIF was
// called clean. Every frame is read now; a finding on any frame ends "not checked" (Obscura cannot cover frames yet),
// and only a picture clean on every frame is clean. The frames are made up: blank or dark, no real text.
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ObscuraCapture
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraSupport
@testable import ObscuraEngine

/// "Reads" the made-up Stripe-shaped key on a dark frame and nothing on a light one, and counts the frames it was shown.
final class FrameRecognizer: TextRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var seen = 0
    var calls: Int { lock.withLock { seen } }

    func recognize(_ image: CGImage, options: OCROptions) async throws -> [OCRLine] {
        lock.withLock { seen += 1 }
        return Self.isDark(image) ? [Fixture.keyLine] : []
    }

    static func isDark(_ image: CGImage) -> Bool {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2]) < 200
    }
}

enum Frames {
    static func dark() -> CGImage {
        let (w, h) = Fixture.imageSize
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    static func encode(_ frames: [CGImage], as type: UTType) throws -> Data {
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, type.identifier as CFString, frames.count, nil))
        for frame in frames { CGImageDestinationAddImage(destination, frame, nil) }
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }
}

@Suite(.serialized) struct MultiFrameTests {
    @Test func theFixtureHasTwoFramesAndOnlyTheSecondReadsAsTheKey() throws {
        let gif = try Frames.encode([Fixture.whiteImage(), Frames.dark()], as: .gif)
        let source = try #require(CGImageSourceCreateWithData(gif as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 2)
        #expect(!FrameRecognizer.isDark(try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))))
        #expect(FrameRecognizer.isDark(try #require(CGImageSourceCreateImageAtIndex(source, 1, nil))))
    }

    /// The finding's own case: frame 1 is blank, the secret is on frame 2.
    @Test func aGIFWhoseSecretIsOnItsSecondFrameIsNotCalledClean() async throws {
        let recognizer = FrameRecognizer()
        let h = try Harness(recognizer: recognizer)
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("gif")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Recording.gif")
        let gif = try Frames.encode([Fixture.whiteImage(), Frames.dark()], as: .gif)
        try gif.write(to: file)

        let stream = h.engine.outcomes
        await h.engine.submit(.file(file, origin: .downloads))
        let report = try #require(await collect(stream, count: 1, timeout: .seconds(5)).first)
        #expect(report.outcome.skipReason == .multiFrame, "never judged on frame 0")
        #expect(recognizer.calls >= 2, "both frames were read (the second may also be re-read by G-12)")
        #expect(try Data(contentsOf: file) == gif, "the file is left as it is, not flattened to one frame")
        #expect(try await h.journal.entries(matching: .all).isEmpty)
        let status = await h.engine.currentStatus()
        #expect(status.unchecked.first?.reason == "multiFrame")
        #expect(status.problems.first { $0.kind == .scanFailure }?.detail == "1")
    }

    @Test func aPictureCleanOnEveryFrameIsClean() async throws {
        let recognizer = FrameRecognizer()
        let h = try Harness(recognizer: recognizer)
        defer { h.tearDown() }
        let tiff = try Frames.encode([Fixture.whiteImage(), Fixture.whiteImage(), Fixture.whiteImage()], as: .tiff)
        #expect(await h.scan(tiff, name: "Pages.tiff").isClean)
        #expect(recognizer.calls == 3, "every page was read before the verdict")
    }

    @Test func aCopiedImageWithASecretOnALaterFrameCountsAsNotChecked() async throws {
        let h = try Harness(recognizer: FrameRecognizer())
        defer { h.tearDown() }
        let gif = try Frames.encode([Fixture.whiteImage(), Fixture.whiteImage(), Frames.dark()], as: .gif)
        let stream = h.engine.outcomes
        await h.engine.submit(.pasteboardImage(gif, uti: .gif, changeCount: 77, preservedText: nil))
        #expect(try #require(await collect(stream, count: 1, timeout: .seconds(5)).first).outcome.skipReason == .multiFrame)
        #expect(await h.engine.currentStatus().problems.first { $0.kind == .scanFailure }?.detail == "1")
    }
}
